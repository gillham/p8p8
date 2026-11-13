; The importer: loads the main module and every module it imports, directly
; or indirectly, each one once.  A module is a .p8 file, found by name in
; the search order of the upstream compiler: the -srcdirs directories, the
; directory of the importing file, the current directory, then the library
; (its target subdirectory first, then its shared files).  syslib,
; prog8_math and prog8_lib are imported implicitly, as upstream does.

%import ast
%import parser
%import lexer
%import source
%import strtab
%import buf
%import diag
%import io_platform

importer {
    %option ignore_unused

    struct Module {
        ^^Module next
        ^^ast.Node tree         ; the MODULE node
        ^^ubyte name            ; module name: the file name without .p8
        ^^source.File file
        bool is_library         ; found in the library directory
    }

    ^^Module modules = 0
    ^^Module last_module = 0
    uword count = 0

    const ubyte MAX_SRCDIRS = 16
    ^^pointer srcdirs = 0           ; -srcdirs entries
    ubyte srcdir_count = 0
    ^^ubyte libdir = ".prog8-reference/compiler/res/prog8lib"
    ^^ubyte target = "llvm64"
    ^^ubyte triple = 0              ; -triple: a platform profile of an llvm target, or 0 for its default
    ^^ubyte common_library = 0      ; modules that come before those of libdir itself (a library in parts), or 0
    ^^ubyte target_library = 0      ; the target's library directory when its configuration names one (else libdir/target)
    ^^ubyte triple_library = 0      ; that profile's library subdirectory of the target's, searched first
    ^^buf.Buf path = 0
    ^^ubyte kw_import = 0

    sub add_srcdir(^^ubyte dir) {
        if srcdirs == 0
            srcdirs = mem.alloc(MAX_SRCDIRS * sizeof(pointer))
        if srcdir_count >= MAX_SRCDIRS
            return
        srcdirs[srcdir_count] = dir
        srcdir_count++
    }

    ; Splits "a:b:c" into search directories.
    sub set_srcdirs(^^ubyte spec) {
        long start = 0
        long i = 0
        repeat {
            ubyte c = spec[i]
            if c == ':' or c == 0 {
                if i > start
                    add_srcdir(strtab.intern(spec + start, (i - start) as uword))
                start = i + 1
            }
            if c == 0
                break
            i++
        }
    }

    ; Loads the main file and everything it imports; returns the main module or 0.
    sub load_program(^^ubyte mainpath) -> ^^Module {
        if path == 0
            path = buf.new(256)
        if kw_import == 0
            kw_import = strtab.intern_cstr("import")
        ^^Module main = load_module(strtab.intern_cstr(mainpath), module_name_of(mainpath), false)
        if main == 0 {
            diag.error_at(0, 0, 0, "can't read the main file")
            return 0
        }
        ; names are compared as interned pointers, so intern these literals
        void import_library(strtab.intern_cstr("syslib"), main)
        void import_library(strtab.intern_cstr("prog8_math"), main)
        void import_library(strtab.intern_cstr("prog8_lib"), main)
        process_imports(main)
        return main
    }

    ; the file name without directories and without .p8
    sub module_name_of(^^ubyte filepath) -> ^^ubyte {
        long start = 0
        long i = 0
        while filepath[i] != 0 {
            if filepath[i] == '/' or filepath[i] == '\\'
                start = i + 1
            i++
        }
        long end = i
        if end - start > 3 and filepath[end - 3] == '.' and filepath[end - 2] == 'p' and filepath[end - 1] == '8'
            end -= 3
        return strtab.intern(filepath + start, (end - start) as uword)
    }

    sub find_loaded(^^ubyte name) -> ^^Module {
        ^^Module m = modules
        while m != 0 {
            if m.name == name
                return m
            m = m.next
        }
        return 0
    }

    ; Parses the file as a module and adds it to the list; 0 when it can't be read.
    sub load_module(^^ubyte filepath, ^^ubyte name, bool is_library) -> ^^Module {
        ^^source.File f = source.load(filepath)
        if f == 0
            return 0
        ^^lexer.Tokens toks = lexer.tokenize(f)
        ^^Module m = mem.alloc(sizeof(Module))
        m.tree = parser.parse(toks)
        m.name = name
        m.file = f
        m.is_library = is_library
        if modules == 0
            modules = m
        else
            last_module.next = m
        last_module = m
        count++
        return m
    }

    ; Handles every %import at the top of the module, loading new modules and their imports in turn.
    sub process_imports(^^Module m) {
        ^^ast.Node d = m.tree.a
        while d != 0 {
            if d.kind == ast.N_DIRECTIVE and d.name == kw_import {
                if d.a == 0 or d.a.kind != ast.N_IDENT or d.a.next != 0
                    diag.error_at(m.file, d.line, d.col, "invalid import directive, expected a module name")
                else
                    void import_module(d.a.name, m, d)
            }
            d = d.next
        }
    }

    ; Imports a module by name on behalf of the importing module; returns it, or 0 when not found.
    sub import_module(^^ubyte name, ^^Module by, ^^ast.Node directive) -> ^^Module {
        if name == by.name {
            diag.error_at(by.file, directive.line, directive.col, "cannot import self")
            return 0
        }
        ^^Module existing = find_loaded(name)
        if existing != 0
            return existing
        ^^Module m = 0
        ; 1. the -srcdirs directories: also for an import by a library module, so that a
        ; program's own textio (say) is the one the library's diskio gets too, as upstream has it
        ubyte i = 0
        while i < srcdir_count and m == 0 {
            m = try_load(srcdirs[i], name, false)
            i++
        }
        ; 2. the directory of the importing file (not a library's: the shared directory
        ; must not shadow a target's own version of a module)
        if m == 0 and not by.is_library
            m = try_load_dir_of(by.file.name, name, false)
        ; 3. the current directory
        if m == 0
            m = try_load(".", name, false)
        ; 4. the library: target directory, then the shared files
        if m == 0
            m = import_library(name, by)
        if m == 0 {
            buf.clear(path)
            buf.add_str(path, "no module found with name ")
            buf.add_str(path, name)
            buf.add_str(path, " (imported by '")
            buf.add_str(path, by.name)
            buf.add_str(path, "')")
            diag.error_at(by.file, directive.line, directive.col, path.data)
            return 0
        }
        return m
    }

    sub import_library(^^ubyte name, ^^Module by) -> ^^Module {
        ^^Module m = find_loaded(name)
        if m != 0
            return m
        if triple_library != 0 and target_library != 0 {
            buf.clear(path)
            buf.add_str(path, target_library)
            buf.add_byte(path, '/')
            buf.add_str(path, triple_library)
            m = try_load(strtab.intern(path.data, path.len as uword), name, true)
            if m != 0
                return m
        }
        if triple_library != 0 {
            buf.clear(path)
            buf.add_str(path, libdir)
            buf.add_byte(path, '/')
            buf.add_str(path, target)
            buf.add_byte(path, '/')
            buf.add_str(path, triple_library)
            m = try_load(strtab.intern(path.data, path.len as uword), name, true)
            if m != 0
                return m
        }
        if target_library != 0
            m = try_load(target_library, name, true)
        if m == 0 {
            buf.clear(path)
            buf.add_str(path, libdir)
            buf.add_byte(path, '/')
            buf.add_str(path, target)
            m = try_load(strtab.intern(path.data, path.len as uword), name, true)
        }
        if m == 0 and common_library != 0
            m = try_load(common_library, name, true)
        if m == 0
            m = try_load(libdir, name, true)
        return m
    }

    ; Where a file of the library is ("library:name" in %asminclude and %asmbinary):
    ; in the target's own directory, with the modules that come first, or in libdir.
    sub library_file(^^ubyte name, ^^buf.Buf pb) {
        if target_library != 0 {
            buf.clear(pb)
            buf.add_str(pb, target_library)
            buf.add_byte(pb, '/')
            buf.add_str(pb, name)
            buf.add_byte(pb, 0)
            if io_platform.file_size(pb.data) >= 0 {
                pb.len--
                return
            }
        }
        if common_library != 0 {
            buf.clear(pb)
            buf.add_str(pb, common_library)
            buf.add_byte(pb, '/')
            buf.add_str(pb, name)
            buf.add_byte(pb, 0)
            if io_platform.file_size(pb.data) >= 0 {
                pb.len--
                return
            }
        }
        buf.clear(pb)
        buf.add_str(pb, libdir)
        buf.add_byte(pb, '/')
        buf.add_str(pb, name)
    }

    sub try_load_dir_of(^^ubyte filepath, ^^ubyte name, bool is_library) -> ^^Module {
        long dirlen = 0
        long i = 0
        while filepath[i] != 0 {
            if filepath[i] == '/' or filepath[i] == '\\'
                dirlen = i
            i++
        }
        if dirlen == 0
            return 0
        return try_load(strtab.intern(filepath, dirlen as uword), name, is_library)
    }

    ; Loads dir/name.p8 when it exists.
    sub try_load(^^ubyte dir, ^^ubyte name, bool is_library) -> ^^Module {
        buf.clear(path)
        buf.add_str(path, dir)
        buf.add_byte(path, '/')
        buf.add_str(path, name)
        buf.add_str(path, ".p8")
        if io_platform.file_size(path.data) < 0
            return 0
        ^^Module m = load_module(strtab.intern(path.data, path.len as uword), name, is_library)
        if m == 0
            return 0
        strip_module_directives(m)
        process_imports(m)
        return m
    }

    ; Directives that only apply to the main module are removed from imported ones.
    sub strip_module_directives(^^Module m) {
        ^^ast.Node prev = 0
        ^^ast.Node d = m.tree.a
        while d != 0 {
            bool remove = false
            if d.kind == ast.N_DIRECTIVE {
                ^^ubyte n = d.name
                if n == strtab.intern_cstr("zpreserved") or n == strtab.intern_cstr("zpallowed") {
                    diag.warning_at(m.file, d.line, d.col, "directive only applies in the main module; ignored here")
                    remove = true
                }
                else if n == strtab.intern_cstr("output") or n == strtab.intern_cstr("launcher") or n == strtab.intern_cstr("zeropage")
                    or n == strtab.intern_cstr("address") or n == strtab.intern_cstr("memtop") or n == strtab.intern_cstr("varsaddress")
                    remove = true
            }
            if remove {
                if prev == 0
                    m.tree.a = d.next
                else
                    prev.next = d.next
            }
            else
                prev = d
            d = d.next
        }
    }

    sub list_modules() {
        ^^Module m = modules
        while m != 0 {
            out.puts(m.name)
            out.puts(": ")
            out.puts(m.file.name)
            if m.is_library
                out.puts(" (library)")
            out.nl()
            m = m.next
        }
    }
}
