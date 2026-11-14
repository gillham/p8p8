; p8p8: a Prog8 compiler written in Prog8.
; Driver: command line, then the stages that exist so far.

%import out
%import mem
%import strtab
%import source
%import strings
%import lexer
%import parser
%import printer
%import importer
%import symtab
%import resolver
%import typer
%import encoding
%import checker
%import irgen
%import llvmgen
%import gen6502
%import irprune
%import target
%import peep6502
%import ir
%import io_platform
%import buf
%import types
%import ast
%import diag
%import version
%import crumb
%import warn
%zeropage basicsafe

main {
    bool opt_stats = false
    bool opt_tokens = false
    bool opt_ast = false
    bool opt_print = false
    bool opt_parse = false
    bool opt_modules = false
    bool opt_symbols = false
    bool opt_nolib = false
    bool opt_check = false
    bool opt_ir = false
    bool opt_llvm = false
    bool opt_build = false          ; -build: go on to the executable or program file
    bool opt_run = false            ; -run: and start it
    bool cross = false              ; -triple names the platform of an llvm64 program
    ^^ubyte opt_target = 0          ; -target: a name, or a .properties file
    bool opt_own = false            ; p8p8's 6502 code generator, not prog8c-llvm's back end
    ubyte opt_codegen = 0           ; -codegen: 0 not given, 1 own, 2 upstream
    ubyte opt_encoding = encoding.E_INVALID     ; -encoding: the default encoding, in place of the target's
    bool opt_asmlist = false        ; -asmlist: the assembler writes a listing
    bool explicit_mode = false      ; an option said what to do (-check, -ir, -build, a dump ...)
    bool opt_keepunused = false
    ^^ubyte outdir = 0

    ^^pointer files = 0             ; the source files of the command line, in order
    uword file_count = 0

    ; the options that are followed by a value
    sub takes_value(^^ubyte arg) -> bool {
        return strings.compare(arg, "-srcdirs") == 0 or strings.compare(arg, "-lib") == 0
            or strings.compare(arg, "-target") == 0 or strings.compare(arg, "-codegen") == 0
            or strings.compare(arg, "-triple") == 0 or strings.compare(arg, "-encoding") == 0
            or strings.compare(arg, "-varshigh") == 0 or strings.compare(arg, "-varsaddress") == 0
            or strings.compare(arg, "-out") == 0 or strings.compare(arg, "-o") == 0
            or strings.compare(arg, "-output") == 0 or strings.compare(arg, "-report") == 0
    }

    ; The compiler itself went wrong (a signal): say where, and how to report it.
    sub crashed() {
        out.err()
        out.puts("p8c: internal error: the compiler crashed")
        if crumb.stage != 0 {
            out.puts(" while ")
            out.puts(crumb.stage)
            if crumb.name != 0 {
                out.puts(" (")
                out.puts(crumb.name)
                out.puts(")")
            }
        }
        out.nl()
        out.puts("This is a bug in p8c.  To report it, run the same command with  -report <directory>")
        out.nl()
        out.puts("added (a directory that does not exist yet) and attach what it writes there.")
        out.nl()
        out.exit(70)
    }

    ^^ubyte opt_report = 0          ; -report: the directory a report of this run is written to
    bool opt_report_nosource = false
    bool opt_selfcrash = false
    ^^ubyte opt_modules_file = 0    ; (what -report asks of the compiler it starts: the list of loaded files)

    sub start() {
        out.init()
        io_platform.catch_crashes(&crashed)
        crumb.at("reading the command line")
        uword argc = sys.argc()
        uword files_done = 0
        uword i = 1
        while i < argc {
            ^^ubyte arg = sys.argv(i)
            ; (upstream takes its options with one dash or two: --target is -target)
            if arg[0] == '-' and arg[1] == '-' and arg[2] != 0
                arg = arg + 1
            ; -emu is upstream's name for building the program and running it
            if strings.compare(arg, "-emu") == 0
                arg = "-run"
            if strings.compare(arg, "-check") == 0 or strings.compare(arg, "-ir") == 0 or strings.compare(arg, "-llvm") == 0
                    or strings.compare(arg, "-build") == 0 or strings.compare(arg, "-run") == 0 or strings.compare(arg, "-modules") == 0
                    or strings.compare(arg, "-symbols") == 0 or strings.compare(arg, "-types") == 0 or strings.compare(arg, "-tokens") == 0
                    or strings.compare(arg, "-ast") == 0 or strings.compare(arg, "-parse") == 0 or strings.compare(arg, "-print") == 0
                    or strings.compare(arg, "-stats") == 0
                explicit_mode = true
            ^^ubyte value = 0
            if i + 1 < argc
                value = sys.argv(i + 1)
            if strings.compare(arg, "-stats") == 0
                opt_stats = true
            else if strings.compare(arg, "-modules") == 0
                opt_modules = true
            else if strings.compare(arg, "-symbols") == 0
                opt_symbols = true
            else if strings.compare(arg, "-types") == 0 {
                opt_ast = true
                ast.show_types = true
            }
            else if strings.compare(arg, "-srcdirs") == 0 and value != 0 {
                importer.set_srcdirs(value)
                i++
            }
            else if strings.compare(arg, "-lib") == 0 and value != 0 {
                lib_choice = value
                lib_ready = false
                i++
            }
            else if strings.compare(arg, "-libpath") == 0
                opt_libpath = true
            else if strings.compare(arg, "-report") == 0 and value != 0 {
                opt_report = value
                i++
            }
            else if strings.compare(arg, "-reportnosource") == 0
                opt_report_nosource = true
            else if strings.compare(arg, "-reportmodules") == 0 and value != 0 {
                opt_modules_file = value
                i++
            }
            else if strings.compare(arg, "-selfcrash") == 0 {
                ; (for the test of the message below: the compiler goes wrong on purpose)
                opt_selfcrash = true
            }
            else if strings.compare(arg, "-version") == 0
                opt_version = true
            else if strings.compare(arg, "-target") == 0 and value != 0 {
                opt_target = value
                i++
            }
            else if strings.compare(arg, "-codegen") == 0 and value != 0 {
                if strings.compare(value, "own") == 0
                    opt_codegen = 1
                else if strings.compare(value, "upstream") == 0
                    opt_codegen = 2
                else
                    usage()
                i++
            }
            else if strings.compare(arg, "-triple") == 0 and value != 0 {
                importer.triple = value
                i++
            }
            else if strings.compare(arg, "-tokens") == 0
                opt_tokens = true
            else if strings.compare(arg, "-ast") == 0
                opt_ast = true
            else if strings.compare(arg, "-nopos") == 0
                ast.show_positions = false
            else if strings.compare(arg, "-nolib") == 0
                opt_nolib = true
            else if strings.compare(arg, "-check") == 0
                opt_check = true
            else if strings.compare(arg, "-ir") == 0
                opt_ir = true
            else if strings.compare(arg, "-llvm") == 0
                opt_llvm = true
            else if strings.compare(arg, "-build") == 0
                opt_build = true
            else if strings.compare(arg, "-run") == 0 {
                opt_build = true
                opt_run = true
            }
            else if strings.compare(arg, "-plaintext") == 0 or strings.compare(arg, "-quiet") == 0
                    or strings.compare(arg, "-quietasm") == 0 or strings.compare(arg, "-nosourcelines") == 0
                    or strings.compare(arg, "-timings") == 0
                    or strings.compare(arg, "-warnimplicitcasts") == 0 or strings.compare(arg, "-ircomments") == 0 {
                ; options of upstream that only concern what it prints or notes in its
                ; output, and that have nothing to switch here: taken and ignored, so that
                ; a command line written for prog8c works as it is
            }
            else if strings.compare(arg, "-asmlist") == 0
                opt_asmlist = true
            else if strings.compare(arg, "-varsgolden") == 0
                gen6502.vars_golden = true
            else if strings.compare(arg, "-encoding") == 0 and value != 0 {
                opt_encoding = encoding.from_name(value)
                if opt_encoding == encoding.E_INVALID or opt_encoding == encoding.E_DEFAULT
                    usage()
                i++
            }
            else if strings.compare(arg, "-varshigh") == 0 and value != 0 {
                bool hok
                hok, gen6502.vars_high_bank = target.parse_number(value)
                if not hok
                    usage()
                i++
            }
            else if strings.compare(arg, "-varsaddress") == 0 and value != 0 {
                bool aok
                aok, gen6502.vars_address = target.parse_number(value)
                if not aok
                    usage()
                i++
            }
            else if strings.compare(arg, "-noopt") == 0
                peep6502.enabled = false
            else if strings.compare(arg, "-keepunused") == 0
                opt_keepunused = true
            else if strings.compare(arg, "-out") == 0 and value != 0 {
                outdir = value
                i++
            }
            else if (strings.compare(arg, "-o") == 0 or strings.compare(arg, "-output") == 0) and value != 0 {
                output_file(value)
                i++
            }
            else if strings.compare(arg, "-verbose") == 0
                opt_verbose = true
            else if strings.compare(arg, "-traceimports") == 0
                importer.trace = true
            else if strings.compare(arg, "-warnunused") == 0
                warn.unused = true
            else if strings.compare(arg, "-warnunreachable") == 0
                warn.unreachable = true
            else if strings.compare(arg, "-warnshadow") == 0
                opt_warnshadow = true
            else if strings.compare(arg, "-warnall") == 0 {
                warn.unused = true
                warn.unreachable = true
                opt_warnshadow = true
            }
            else if strings.compare(arg, "-print") == 0
                opt_print = true
            else if strings.compare(arg, "-parse") == 0
                opt_parse = true
            else if arg[0] == '-' {
                out.err()
                if takes_value(arg) {
                    out.puts(arg)
                    out.puts(" needs a value")
                }
                else {
                    out.puts("unknown option: ")
                    out.puts(arg)
                }
                out.nl()
                out.exit(1)
            }
            else {
                ; a source file: compiled when the whole command line has been read, so
                ; that an option counts wherever it stands, before the file or after it
                if files == 0
                    files = mem.alloc(argc as long * sizeof(pointer))
                files[file_count] = arg
                file_count++
            }
            i++
        }
        if opt_report != 0
            make_report()
        if opt_selfcrash {
            crumb.at("testing the crash message")
            crumb.name = "on purpose"
            ^^ubyte nowhere = 8 as ^^ubyte
            nowhere[argc] = 1
        }
        if opt_version {
            print_version()
            out.exit(0)
        }
        if opt_libpath {
            prepare_library()
            out.puts(lib_root)
            out.nl()
            out.exit(0)
        }
        for i in 0 to file_count - 1 {
            if i < file_count {
                compile_file(files[i])
                files_done++
            }
        }
        if files_done == 0
            usage()
        if opt_stats {
            source.stats()
            lexer.stats()
            ast.stats()
            symtab.stats()
            resolver.stats()
            types.stats()
            typer.stats()
            encoding.stats()
            checker.stats()
            if opt_ir or opt_llvm or opt_build {
                ir.stats()
                if not opt_keepunused
                    irprune.stats()
            }
            strtab.stats()
            mem.stats()
        }
        if diag.errors > 0
            out.exit(1)
        out.exit(0)
    }

    ; ---- where the library is ----
    ;
    ; -lib says it; else P8P8_LIB; else it is looked for from where the compiler itself
    ; is: ../lib/p8p8 (installed: bin/p8c and lib/p8p8 under one directory) and ../../lib
    ; (built in its repository: build/<host>/p8c); else the reference material in the
    ; current directory, as before.

    ^^ubyte lib_choice = 0          ; what -lib named
    bool lib_ready = false
    ^^ubyte lib_root = 0            ; the directory that was chosen
    bool layered = false            ; it is a library in parts: prog8lib/, common/, targets/
    bool opt_libpath = false        ; -libpath: print the library directory and stop
    bool opt_version = false        ; -version: print the compiler's version and the library's, and stop

    ; The compiler's version, and which library it would use with what that says of
    ; itself (its VERSION file): the two things a report of a problem needs.
    sub print_version() {
        out.puts("p8p8 ")
        out.puts(version.number)
        out.puts(", a Prog8 compiler written in Prog8")
        out.nl()
        out.puts("This software is licensed under the GNU GPL 3.0, see https://www.gnu.org/licenses/gpl.html")
        out.nl()
        prepare_library()
        out.puts("library: ")
        out.puts(lib_root)
        out.nl()
        ^^buf.Buf vb = buf.new(256)
        buf.add_str(vb, lib_root)
        buf.add_str(vb, "/VERSION")
        buf.add_byte(vb, 0)
        long size = io_platform.file_size(vb.data)
        if size <= 0 {
            out.puts("  (it has no VERSION file)")
            out.nl()
            return
        }
        ^^ubyte text = mem.alloc(size + 2)
        long got = io_platform.read_file(vb.data, text, size)
        long i = 0
        while i < got {
            ; each line of it, indented
            long start = i
            while i < got and text[i] != '\n' and text[i] != '\r'
                i++
            if i > start {
                out.puts("  ")
                out.put_bytes(text + start, i - start)
                out.nl()
            }
            while i < got and (text[i] == '\n' or text[i] == '\r')
                i++
        }
    }
    ^^ubyte program_found = 0

    sub prepare_library() {
        if lib_ready
            return
        lib_ready = true
        lib_root = lib_choice
        if lib_root == 0 {
            ^^ubyte fromenv = io_platform.env("P8P8_LIB")
            if fromenv != 0 and fromenv[0] != 0
                lib_root = fromenv
        }
        if lib_root == 0
            lib_root = library_beside("/../lib/p8p8")
        if lib_root == 0
            lib_root = library_beside("/../../lib")
        if lib_root == 0
            lib_root = ".prog8-reference/compiler/res/prog8lib"
        ; A library in parts: prog8lib/ with upstream's modules as they come, common/ and
        ; targets/ with what is added (docs/TARGETS.md).
        layered = false
        importer.libdir = lib_root
        importer.common_library = 0
        ^^buf.Buf lb = buf.new(256)
        buf.add_str(lb, lib_root)
        buf.add_str(lb, "/prog8lib/prog8_lib.p8")
        buf.add_byte(lb, 0)
        if io_platform.file_size(lb.data) >= 0 {
            layered = true
            lb.len -= 14             ; ("/prog8_lib.p8" and the zero)
            importer.libdir = strtab.intern(lb.data, lb.len as uword)
            buf.clear(lb)
            buf.add_str(lb, lib_root)
            buf.add_str(lb, "/common")
            importer.common_library = strtab.intern(lb.data, lb.len as uword)
        }
    }

    ; The directory of the support sources that some programs are built with
    ; (windows-console.c, mos-c64-support.c): P8P8_RUNTIME, "runtime" where the compiler
    ; runs, or beside the compiler: ../lib/p8p8/runtime (installed), ../../runtime (its
    ; repository).
    sub runtime_dir() -> ^^ubyte {
        ^^ubyte rt = io_platform.env("P8P8_RUNTIME")
        if rt != 0 and rt[0] != 0
            return rt
        if io_platform.file_size("runtime/windows-console.c") >= 0
            return "runtime"
        ^^ubyte prog = program_path()
        long cut = -1
        long i = 0
        while prog[i] != 0 {
            if prog[i] == '/' or prog[i] == '\\'
                cut = i
            i++
        }
        if cut >= 0 {
            ^^buf.Buf pb = buf.new(512)
            ubyte k
            for k in 0 to 1 {
                buf.clear(pb)
                buf.add_bytes(pb, prog, cut)
                if k == 0
                    buf.add_str(pb, "/../lib/p8p8/runtime")
                else
                    buf.add_str(pb, "/../../runtime")
                long keep = pb.len
                buf.add_str(pb, "/windows-console.c")
                buf.add_byte(pb, 0)
                if io_platform.file_size(pb.data) >= 0
                    return strtab.intern(pb.data, keep as uword)
            }
        }
        return "runtime"
    }

    ; the library directory at this place from the compiler's own directory, or 0
    sub library_beside(str place) -> ^^ubyte {
        ^^ubyte prog = program_path()
        long cut = -1
        long i = 0
        while prog[i] != 0 {
            if prog[i] == '/' or prog[i] == '\\'
                cut = i
            i++
        }
        if cut < 0
            return 0
        ^^buf.Buf pb = buf.new(512)
        buf.add_bytes(pb, prog, cut)
        buf.add_str(pb, place)
        long keep = pb.len
        buf.add_str(pb, "/prog8lib/prog8_lib.p8")
        buf.add_byte(pb, 0)
        if io_platform.file_size(pb.data) < 0
            return 0
        return io_platform.real_path(strtab.intern(pb.data, keep as uword))
    }

    ; Where the compiler's executable really is: found in PATH when it was started by its
    ; name alone, and with symbolic links followed (an installed p8c may be one).
    sub program_path() -> ^^ubyte {
        if program_found != 0
            return program_found
        ^^ubyte arg0 = sys.argv(0)
        bool has_dir = false
        long i = 0
        while arg0[i] != 0 {
            if arg0[i] == '/' or arg0[i] == '\\'
                has_dir = true
            i++
        }
        ^^buf.Buf pb = buf.new(1024)
        if not has_dir {
            ^^ubyte path = io_platform.env("PATH")
            ^^ubyte os = io_platform.env("OS")
            bool windows = os != 0 and os[0] == 'W' and os[1] == 'i' and os[2] == 'n'
            ubyte separator = ':'
            if windows
                separator = ';'
            i = 0
            while path != 0 and path[i] != 0 {
                long start = i
                while path[i] != 0 and path[i] != separator
                    i++
                if i > start {
                    buf.clear(pb)
                    buf.add_bytes(pb, path + start, i - start)
                    buf.add_byte(pb, '/')
                    buf.add_str(pb, arg0)
                    long plain = pb.len
                    buf.add_byte(pb, 0)
                    bool there = io_platform.file_size(pb.data) >= 0
                    if not there and windows {
                        pb.len = plain
                        buf.add_str(pb, ".exe")
                        buf.add_byte(pb, 0)
                        there = io_platform.file_size(pb.data) >= 0
                    }
                    if there {
                        arg0 = strtab.intern(pb.data, (pb.len - 1) as uword)
                        break
                    }
                }
                if path[i] != 0
                    i++
            }
        }
        program_found = io_platform.real_path(arg0)
        return program_found
    }

    sub usage() {
        out.puts("usage: p8c [options] file.p8 ...")
        out.nl()
        out.puts("  -version       print the version of the compiler and of the library it uses")
        out.nl()
        out.puts("  -report dir    run as without it, and write a report of the run into the new directory dir: versions,")
        out.nl()
        out.puts("                 the command, the output, the files written and the program's sources (-reportnosource: not those)")
        out.nl()
        out.puts("  -warnunused    warn about variables, parameters and subroutines that nothing uses")
        out.nl()
        out.puts("  -warnunreachable  warn about statements after a return, goto, break or continue")
        out.nl()
        out.puts("  -warnshadow    let the assembler warn about symbols that hide others;  -warnall: all of these")
        out.nl()
        out.puts("  (options may be written with two dashes; -emu is -run; -plaintext, -quiet, -quietasm, -nosourcelines,")
        out.nl()
        out.puts("   -timings, -warnimplicitcasts and -ircomments of prog8c are accepted and ignored)")
        out.nl()
        out.puts("  -srcdirs a:b   directories searched first for imported modules")
        out.nl()
        out.puts("  -lib dir       the library directory (default: P8P8_LIB, or lib/p8p8 beside the compiler's bin directory,")
        out.nl()
        out.puts("                 or .prog8-reference/compiler/res/prog8lib);  -libpath: print which one it is")
        out.nl()
        out.puts("  -target name   the compilation target, which selects the library subdirectory (default llvm64)")
        out.nl()
        out.puts("  -triple name   the platform of an llvm target: mos-c64 (Commodore 64) with llvm16; with llvm64 (default: this machine)")
        out.nl()
        out.puts("                 arm64-apple-macosx, x86_64-apple-macosx, x86_64-unknown-linux-gnu or aarch64-unknown-linux-gnu")
        out.nl()
        out.puts("  -modules       list the loaded modules")
        out.nl()
        out.puts("  -symbols       dump the symbol table")
        out.nl()
        out.puts("  -types         dump the AST of every module with the inferred types")
        out.nl()
        out.puts("  -tokens        dump the tokens of the main file")
        out.nl()
        out.puts("  -ast           dump the AST of every module (-nopos: without positions)")
        out.nl()
        out.puts("  -nolib         leave the library modules out of the AST dump")
        out.nl()
        out.puts("  -print         print the AST of the main file back as source")
        out.nl()
        out.puts("  -parse         parse the main file only: no imports, no symbol resolution")
        out.nl()
        out.puts("  -stats         print statistics at the end")
        out.nl()
        out.puts("  -check         only check the program, like prog8c -check (the default for now)")
        out.nl()
        out.puts("  -out dir       the directory for the output files (default: the current one)")
        out.nl()
        out.puts("  -o file        the program file: its directory is where the output goes, its name that of every output file")
        out.nl()
        out.puts("  -traceimports  print which file every imported module comes from")
        out.nl()
        out.puts("  -verbose       print the commands that are run, and let the assembler print its summary of the program")
        out.nl()
        out.puts("  -ir            generate the IR and write it as <module>.p8ir (-out dir: where, default .)")
        out.nl()
        out.puts("  -llvm          generate the IR and write it as LLVM IR text <module>.ll")
        out.nl()
        out.puts("  -build         also build the program: clang for the llvm targets, prog8c-llvm's back end for the others")
        out.nl()
        out.puts("  -run           build the program and run it (in wasmtime, mos-sim, x16emu or x64sc where that applies)")
        out.nl()
        out.puts("  -codegen own|upstream   for a 6502 machine: p8p8's own code generator and 64tass (the default), or prog8c-llvm's back end")
        out.nl()
        out.puts("  -asmlist       the assembler writes a listing (name.list)")
        out.nl()
        out.puts("  -keepunused    keep subroutines and variables that nothing refers to")
        out.nl()
        out.puts("  -encoding E    the encoding of strings and characters without a prefix (iso, petscii, sc, ...) in place of the target's")
        out.nl()
        out.puts("  -varsgolden    with -codegen own: the variables without an initial value in the target's golden ram")
        out.nl()
        out.puts("  -varshigh N    in its high ram, bank N;  -varsaddress A: at address A ($hex or decimal)")
        out.nl()
        out.puts("  -noopt         with -codegen own: every IR instruction translated by itself, no value tracking")
        out.nl()
        out.exit(1)
    }

    sub compile_file(str path) {
        if opt_tokens or opt_print or opt_parse {
            ; single-file modes: no imports
            ^^source.File f = source.load(path)
            if f == 0 {
                out.err()
                out.puts("can't read ")
                out.puts(path)
                out.nl()
                out.exit(1)
            }
            ^^lexer.Tokens toks = lexer.tokenize(f)
            if opt_tokens
                lexer.dump(toks)
            ^^ast.Node module = parser.parse(toks)
            if opt_ast
                ast.dump(module, 0)
            if opt_print
                printer.print_module(module)
            return
        }
        prepare_library()
        ; the target: a machine with a configuration file (see target.p8), or one p8p8 knows by itself
        if opt_target != 0 {
            ^^ubyte tname = target.resolve(opt_target, lib_root)
            if tname == 0 {
                out.puts("error: ")
                out.puts(target.error_text)
                out.puts(": ")
                out.puts(opt_target)
                out.nl()
                out.exit(1)
            }
            importer.target = tname
            importer.target_library = 0
            ; A machine with a configuration is compiled like prog8c does it: to a program,
            ; unless an option asks for something else; and by p8p8's own code generator,
            ; unless -codegen upstream asks for prog8c-llvm's back end.
            if target.loaded and not explicit_mode
                opt_build = true
            opt_own = opt_codegen == 1 or (opt_codegen == 0 and target.loaded and opt_build)
            if not target.loaded and (opt_ir or opt_build or not explicit_mode) and not buf.bytes_equal(tname, "llvm", 4)
                    and strings.compare(tname, "virtual") != 0 and not buf.bytes_equal(tname, "amiga", 5)
                    and strings.compare(tname, "qemu68k") != 0 {
                out.puts("error: no configuration for target ")
                out.puts(tname)
                out.puts(": no ")
                out.puts(tname)
                out.puts("/target.properties or targets/")
                out.puts(tname)
                out.puts("/target.properties in the library ")
                out.puts(lib_root)
                out.nl()
                out.exit(1)
            }
            ^^ubyte tlib = target.text("library")
            if tlib != 0 {
                if tlib[0] == '~' and tlib[1] == '/' {
                    ; (the home directory, as upstream expands it)
                    ^^buf.Buf hb = buf.new(256)
                    ^^ubyte home = io_platform.env("HOME")
                    if home != 0
                        buf.add_str(hb, home)
                    buf.add_str(hb, tlib + 1)
                    tlib = strtab.intern(hb.data, hb.len as uword)
                }
                else if target.dir != 0 and tlib[0] == '.' and tlib[1] == '.' and tlib[2] == '/' {
                    ; ("../vic20": the library of another machine, beside this one's directory;
                    ; any other path is from where the compiler runs, as upstream has it)
                    ^^buf.Buf rb = buf.new(256)
                    buf.add_str(rb, target.dir)
                    buf.add_byte(rb, '/')
                    buf.add_str(rb, tlib)
                    tlib = strtab.intern(rb.data, rb.len as uword)
                }
                importer.target_library = tlib
            }
            else if layered and target.loaded and target.dir != 0
                importer.target_library = target.dir    ; the machine's own modules come first
        }
        if layered and importer.target_library == 0 {
            ; (a target without a configuration file has its directory there too)
            ^^buf.Buf ob = buf.new(256)
            buf.add_str(ob, lib_root)
            buf.add_str(ob, "/targets/")
            buf.add_str(ob, importer.target)
            importer.target_library = strtab.intern(ob.data, ob.len as uword)
        }
        ; the platform profile of an llvm target: its own library files come first
        bool hosted = strings.compare(importer.target, "llvm64") == 0
        cross = false
        if importer.triple != 0 {
            if strings.compare(importer.triple, "mos-c64") == 0 and strings.compare(importer.target, "llvm16") == 0
                importer.triple_library = "c64"
            else if hosted and (strings.compare(importer.triple, "arm64-apple-macosx") == 0
                    or strings.compare(importer.triple, "x86_64-apple-macosx") == 0
                    or strings.compare(importer.triple, "x86_64-unknown-linux-gnu") == 0
                    or strings.compare(importer.triple, "x86_64-pc-windows-msvc") == 0
                    or strings.compare(importer.triple, "aarch64-unknown-linux-gnu") == 0)
                cross = true        ; (clang is told the platform, in case it is not this machine)
            else {
                out.puts("error: unknown -triple for this target: ")
                out.puts(importer.triple)
                out.puts(" (p8p8 knows mos-c64 with -target llvm16, and with llvm64: arm64-apple-macosx, x86_64-apple-macosx, x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu, x86_64-pc-windows-msvc)")
                out.nl()
                out.exit(1)
            }
        }
        else if hosted {
            ; llvm64 is for the machine p8p8 runs on
            importer.triple = io_platform.host_triple()
            if importer.triple == 0
                importer.triple = "arm64-apple-macosx"
        }
        crumb.at("reading the program")
        ^^importer.Module mainmod = importer.load_program(path)
        if opt_modules_file != 0
            write_module_list()
        if mainmod == 0
            out.exit(1)
        if opt_modules
            importer.list_modules()
        if diag.errors > 0
            out.exit(1)
        crumb.at("building the symbol table")
        symtab.build()
        if opt_symbols
            symtab.dump()
        if diag.errors > 0
            out.exit(1)
        crumb.at("resolving names")
        resolver.resolve_program()
        if diag.errors > 0
            out.exit(1)
        types.set_target(importer.target)
        encoding.set_target(importer.target)
        if opt_encoding != encoding.E_INVALID
            encoding.target_default = opt_encoding
        crumb.at("typing the program")
        typer.run()
        crumb.at("checking the program")
        checker.run()
        if diag.errors == 0
            warn.run()
        if (opt_ir or opt_llvm or opt_build) and diag.errors == 0
            generate_ir()
        if opt_ast {
            ^^importer.Module m = importer.modules
            while m != 0 {
                if not (opt_nolib and m.is_library) {
                    out.puts("; module ")
                    out.puts(m.name)
                    out.puts(" from ")
                    out.puts(m.file.name)
                    out.nl()
                    ast.dump(m.tree, 0)
                }
                m = m.next
            }
        }
    }

    ; -o file: the program file, as upstream has it.  Its directory is where all the
    ; output goes, and its name without the extension is the name of every output file
    ; in place of the main module's (build/game-c64.prg: also build/game-c64.asm).  An
    ; extension that is not the one the program gets by itself is given to it afterwards.
    ^^ubyte out_name = 0
    ^^ubyte out_ext = 0
    ^^ubyte built_ext = 0           ; the extension build() gave the program
    bool opt_warnshadow = false     ; -warnshadow: the assembler's warnings about symbols that hide others
    bool opt_verbose = false        ; -verbose: say what is run, and let the assembler print its summary

    sub output_file(^^ubyte path) {
        long slash = -1
        long dot = -1
        long i = 0
        while path[i] != 0 {
            if path[i] == '/' or path[i] == '\\' {
                slash = i
                dot = -1
            }
            else if path[i] == '.'
                dot = i
            i++
        }
        if slash > 0
            outdir = strtab.intern(path, slash as uword)
        long start = slash + 1
        if dot > start {
            out_name = strtab.intern(path + start, (dot - start) as uword)
            out_ext = strtab.intern(path + dot, (i - dot) as uword)
        }
        else if i > start
            out_name = strtab.intern(path + start, (i - start) as uword)
    }

    sub generate_ir() {
        ^^importer.Module mainmod = importer.modules
        crumb.at("generating the IR")
        ^^ir.Program p = irgen.generate(mainmod.name)
        ^^ubyte oname = mainmod.name
        if out_name != 0
            oname = out_name
        if diag.errors > 0
            return
        bool is_llvm = buf.bytes_equal(importer.target, "llvm", 4)
        irprune.asmsubs_kept = not opt_own or is_llvm
        crumb.at("removing unused code")
        if not opt_keepunused
            irprune.run(p)
        ^^buf.Buf b = buf.new(65536)
        if opt_build {
            ; what the build step starts from
            if is_llvm
                opt_llvm = true
            else if not opt_own
                opt_ir = true           ; (prog8c-llvm's back end starts from the IR file)
        }
        if opt_ir {
            ir.write(p, b)
            write_output(oname, ".p8ir", b)
        }
        if opt_llvm {
            buf.clear(b)
            crumb.at("generating LLVM IR")
            llvmgen.generate(p, b)
            if llvmgen.errors > 0
                out.exit(1)
            write_output(oname, ".ll", b)
        }
        if opt_own and not is_llvm {
            ; p8p8's own 6502 code generator: assembly for 64tass
            buf.clear(b)
            crumb.at("generating 6502 code")
            gen6502.generate(p, b)
            if gen6502.errors > 0
                out.exit(1)
            write_output(oname, ".asm", b)
        }
        if opt_build {
            crumb.at("building the program")
            build(oname, is_llvm)
            if out_ext != 0 and built_ext != 0 and strings.compare(out_ext, built_ext) != 0 {
                ; the program under the name that was asked for
                ^^buf.Buf fromb = buf.new(256)
                ^^buf.Buf tob = buf.new(256)
                if outdir != 0 {
                    buf.add_str(fromb, outdir)
                    buf.add_byte(fromb, '/')
                    buf.add_str(tob, outdir)
                    buf.add_byte(tob, '/')
                }
                buf.add_str(fromb, oname)
                buf.add_str(fromb, built_ext)
                buf.add_byte(fromb, 0)
                buf.add_str(tob, oname)
                buf.add_str(tob, out_ext)
                buf.add_byte(tob, 0)
                if not io_platform.move_file(fromb.data, tob.data) {
                    out.err()
                    out.puts("can't name the program ")
                    out.puts(tob.data)
                    out.nl()
                    out.exit(1)
                }
            }
        }
    }

    ; ---- -report: everything about one run of the compiler, in a directory ----
    ;
    ; The compiler starts itself with the same command line, has that run write its
    ; output and its files into the directory, and adds what a report of a problem
    ; needs: versions, the command, which files were loaded, and the program's own
    ; source files.  A second process, so that a run that crashes is reported too.

    ^^buf.Buf rep = 0               ; report.txt
    ^^buf.Buf rpath = 0

    sub report_path(str name) -> ^^ubyte {
        buf.clear(rpath)
        buf.add_str(rpath, opt_report)
        buf.add_byte(rpath, '/')
        buf.add_str(rpath, name)
        buf.add_byte(rpath, 0)
        return rpath.data
    }

    sub quoted(^^buf.Buf b, ^^ubyte text) {
        buf.add_byte(b, '"')
        buf.add_str(b, text)
        buf.add_byte(b, '"')
    }

    ; the whole file in memory, zero terminated; 0 when it can't be read
    sub file_bytes(^^ubyte path) -> ^^ubyte, long {
        long size = io_platform.file_size(path)
        if size < 0
            return 0, 0
        ^^ubyte data = mem.alloc(size + 1)
        long got = io_platform.read_file(path, data, size)
        if got != size
            return 0, 0
        data[size] = 0
        return data, size
    }

    ; the name of a file without its directories
    sub base_name(^^ubyte path) -> ^^ubyte {
        ^^ubyte base = path
        long k = 0
        while path[k] != 0 {
            if path[k] == '/' or path[k] == '\\'
                base = path + k + 1
            k++
        }
        return base
    }

    uword sources_copied = 0

    sub copy_source(^^ubyte path) {
        buf.add_str(rep, "  ")
        buf.add_str(rep, path)
        if opt_report_nosource {
            buf.add_byte(rep, '\n')
            return
        }
        ^^ubyte data
        long size
        data, size = file_bytes(path)
        buf.clear(rpath)
        buf.add_str(rpath, opt_report)
        buf.add_str(rpath, "/src/")
        buf.add_str(rpath, base_name(path))
        buf.add_byte(rpath, 0)
        if data != 0 and io_platform.write_file(rpath.data, data, size) {
            buf.add_str(rep, "  (copied to src/")
            buf.add_str(rep, base_name(path))
            buf.add_str(rep, ")\n")
            sources_copied++
        }
        else
            buf.add_str(rep, "  (could not be copied)\n")
    }

    ; (in the compiler that -report starts) the files that were loaded, one on a line,
    ; with L before those of the library and U before the program's own
    sub write_module_list() {
        ^^buf.Buf lb = buf.new(4096)
        ^^importer.Module m = importer.modules
        while m != 0 {
            if m.is_library
                buf.add_byte(lb, 'L')
            else
                buf.add_byte(lb, 'U')
            buf.add_byte(lb, ' ')
            buf.add_str(lb, m.file.name)
            buf.add_byte(lb, '\n')
            m = m.next
        }
        void io_platform.write_file(opt_modules_file, lb.data, lb.len)
    }

    sub make_report() {
        rep = buf.new(8192)
        rpath = buf.new(1024)
        ^^buf.Buf cb = buf.new(2048)
        bool windows = io_platform.is_windows()
        uword argc = sys.argc()
        uword i

        ; the directory, with out/ for what the run writes and src/ for the sources
        buf.add_str(cb, "mkdir ")
        quoted(cb, opt_report)
        buf.add_byte(cb, 0)
        if io_platform.run_command(cb.data) != 0 {
            out.err()
            out.puts("-report: can't make the directory (it must not exist yet): ")
            out.puts(opt_report)
            out.nl()
            out.exit(1)
        }
        buf.clear(cb)
        buf.add_str(cb, "mkdir ")
        quoted(cb, report_path("out"))
        buf.add_byte(cb, 0)
        void io_platform.run_command(cb.data)
        if not opt_report_nosource {
            buf.clear(cb)
            buf.add_str(cb, "mkdir ")
            quoted(cb, report_path("src"))
            buf.add_byte(cb, 0)
            void io_platform.run_command(cb.data)
        }

        ; versions
        ^^buf.Buf saved = out.current
        out.flush()
        out.current = rep
        print_version()
        out.current = saved
        buf.add_str(rep, "host: ")
        ^^ubyte host = io_platform.host_triple()
        if host == 0
            host = "unknown"
        buf.add_str(rep, host)
        buf.add_str(rep, "\ncommand: p8c")
        for i in 1 to argc - 1 {
            if i < argc {
                buf.add_byte(rep, ' ')
                buf.add_str(rep, sys.argv(i))
            }
        }
        buf.add_byte(rep, '\n')

        ; the same command again, without -report, its files and its output in the directory
        buf.clear(cb)
        if windows
            buf.add_byte(cb, '"')       ; (cmd takes the outermost quotes away)
        quoted(cb, program_path())
        i = 1
        while i < argc {
            ^^ubyte arg = sys.argv(i)
            ^^ubyte plain_arg = arg
            if arg[0] == '-' and arg[1] == '-' and arg[2] != 0
                plain_arg = arg + 1
            if strings.compare(plain_arg, "-report") == 0
                i++
            else if strings.compare(plain_arg, "-reportnosource") != 0 {
                buf.add_byte(cb, ' ')
                quoted(cb, arg)
            }
            i++
        }
        buf.add_str(cb, " -verbose -traceimports -out ")
        quoted(cb, report_path("out"))
        buf.add_str(cb, " -reportmodules ")
        quoted(cb, report_path("modules.txt"))
        buf.add_str(cb, " > ")
        quoted(cb, report_path("output.txt"))
        buf.add_str(cb, " 2>&1")
        if windows
            buf.add_byte(cb, '"')
        buf.add_byte(cb, 0)
        ubyte status = io_platform.run_command(cb.data)
        buf.add_str(rep, "exit status: ")
        buf.add_long(rep, status)
        if status == 70
            buf.add_str(rep, " (the compiler crashed: see output.txt)")
        else if status == 255
            buf.add_str(rep, " (the compiler could not be started, or was stopped)")
        buf.add_str(rep, "\nwhat it printed is in output.txt, the files it wrote are in out/\n")

        ; the files of the program
        buf.add_str(rep, "\nsource files of the program:\n")
        ^^ubyte list
        long list_size
        list, list_size = file_bytes(report_path("modules.txt"))
        ^^buf.Buf libs = buf.new(4096)
        if list != 0 and list_size > 0 {
            long at = 0
            while at < list_size {
                long eol = at
                while list[eol] != 0 and list[eol] != '\n'
                    eol++
                list[eol] = 0
                if list[at] == 'U'
                    copy_source(list + at + 2)
                else if list[at] == 'L' {
                    buf.add_str(libs, "  ")
                    buf.add_str(libs, list + at + 2)
                    buf.add_byte(libs, '\n')
                }
                at = eol + 1
            }
        }
        else {
            ; the run did not get as far as loading the program: what the command names
            for i in 0 to file_count - 1 {
                if i < file_count
                    copy_source(files[i])
            }
        }
        if opt_report_nosource
            buf.add_str(rep, "(not copied: -reportnosource)\n")
        if libs.len > 0 {
            buf.add_str(rep, "\nlibrary modules that were loaded:\n")
            buf.add_bytes(rep, libs.data, libs.len)
        }
        buf.add_str(rep, "\nthe tools (what they say of themselves is in tools.txt)\n")
        if not io_platform.write_file(report_path("report.txt"), rep.data, rep.len) {
            out.err()
            out.puts("-report: can't write into ")
            out.puts(opt_report)
            out.nl()
            out.exit(1)
        }
        void io_platform.remove(report_path("modules.txt"))
        buf.clear(cb)
        buf.add_str(cb, "64tass --version > ")
        quoted(cb, report_path("tools.txt"))
        buf.add_str(cb, " 2>&1")
        buf.add_byte(cb, 0)
        void io_platform.run_command(cb.data)
        buf.clear(cb)
        buf.add_str(cb, "clang --version >> ")
        quoted(cb, report_path("tools.txt"))
        buf.add_str(cb, " 2>&1")
        buf.add_byte(cb, 0)
        void io_platform.run_command(cb.data)

        out.puts("report written to ")
        out.puts(opt_report)
        out.puts(": the run ended with status ")
        out.putl(status)
        out.puts(", what it printed is in output.txt")
        out.nl()
        if sources_copied > 0 {
            out.puts("it contains the program's source files (")
            out.putl(sources_copied)
            out.puts(", in src/); -reportnosource leaves them out")
            out.nl()
        }
        out.exit(status)
    }

    ; ---- building and running ----
    ;
    ; The compilers and emulators are other programs, started through the shell, which
    ; also fills in the directories: LLVM_MOS (default ~/.local/llvm-mos) for llvm16,
    ; WASI_SYSROOT and P8P8_WASM_CLANG (default Homebrew's wasi-libc and llvm) for llvm32,
    ; P8P8_RUNTIME (default runtime) for the Commodore 64 support source.

    ^^buf.Buf cmd = 0

    ; "dir/name" of the output files, quoted for the shell, into cmd
    sub add_output(^^ubyte name, ^^ubyte extension) {
        buf.add_byte(cmd, '"')
        if outdir != 0 {
            buf.add_str(cmd, outdir)
            buf.add_byte(cmd, '/')
        }
        buf.add_str(cmd, name)
        buf.add_str(cmd, extension)
        buf.add_byte(cmd, '"')
    }

    sub run_cmd(str what) {
        buf.add_byte(cmd, 0)
        if opt_verbose {
            out.puts(cmd.data)
            out.nl()
        }
        out.flush()
        ubyte status = io_platform.run_command(cmd.data)
        if status != 0 {
            out.err()
            out.puts(what)
            out.puts(" failed: ")
            out.puts(cmd.data)
            out.nl()
            out.exit(1)
        }
    }

    sub build(^^ubyte name, bool is_llvm) {
        if cmd == 0
            cmd = buf.new(512)
        buf.clear(cmd)
        bool wasm = strings.compare(importer.target, "llvm32") == 0
        bool mos = strings.compare(importer.target, "llvm16") == 0
        bool mos_c64 = mos and importer.triple_library != 0
        bool windows = is_llvm and not wasm and not mos and importer.triple != 0 and strings.compare(importer.triple, "x86_64-pc-windows-msvc") == 0
        ^^ubyte extension = ""
        if not is_llvm and opt_own {
            ; the assembly that p8p8 wrote: 64tass makes the program
            ; (the options upstream gives 64tass for each output type)
            extension = ".prg"
            buf.add_str(cmd, "64tass")
            if strings.compare(gen6502.output_type, "XEX") == 0 {
                buf.add_str(cmd, " --atari-xex")
                extension = ".xex"
            }
            else if strings.compare(gen6502.output_type, "RAW") == 0 {
                buf.add_str(cmd, " --nostart")
                extension = ".bin"
            }
            else if strings.compare(gen6502.output_type, "LIBRARY") == 0 {
                buf.add_str(cmd, " --ascii")
                extension = ".bin"
            }
            else
                buf.add_str(cmd, " --cbm-prg --ascii")
            buf.add_str(cmd, " --case-sensitive --long-branch -Wall -Wno-implied-reg --no-monitor")
            if not opt_warnshadow
                buf.add_str(cmd, " -Wno-shadow")
            if not opt_verbose
                buf.add_str(cmd, " --quiet")
            buf.add_str(cmd, " --vice-labels --labels=")
            add_output(name, ".vice-mon-list")
            if opt_asmlist {
                buf.add_str(cmd, " --list=")
                add_output(name, ".list")
            }
            ; (files that the machine's startup code includes are beside its configuration)
            if target.dir != 0 {
                buf.add_str(cmd, " -I \"")
                buf.add_str(cmd, target.dir)
                buf.add_byte(cmd, '"')
            }
            ; the target's own options come before --output: they may hold one themselves
            if target.text("assembler_options") != 0 {
                buf.add_byte(cmd, ' ')
                buf.add_str(cmd, target.text("assembler_options"))
            }
            buf.add_str(cmd, " --output ")
            add_output(name, extension)
            buf.add_byte(cmd, ' ')
            add_output(name, ".asm")
            if strings.compare(gen6502.output_type, "LIBRARY") == 0 {
                if strings.compare(importer.target, "c64") == 0 or strings.compare(importer.target, "c128") == 0 or strings.compare(importer.target, "pet32") == 0
                    buf.add_str(cmd, " --cbm-prg")
                else
                    buf.add_str(cmd, " --nostart")
            }
        }
        else if not is_llvm {
            ; the 6502 targets: upstream's code generator and the assembler finish the IR
            buf.add_str(cmd, "prog8c-llvm -target ")
            buf.add_str(cmd, importer.target)
            buf.add_str(cmd, " -quiet -out \"")
            if outdir != 0
                buf.add_str(cmd, outdir)
            else
                buf.add_byte(cmd, '.')
            buf.add_str(cmd, "\" ")
            add_output(name, ".p8ir")
            extension = ".prg"
        }
        else {
            if wasm {
                buf.add_str(cmd, "\"${P8P8_WASM_CLANG:-/opt/homebrew/opt/llvm/bin/clang}\" --target=wasm32-wasip1 \"--sysroot=${WASI_SYSROOT:-/opt/homebrew/opt/wasi-libc/share/wasi-sysroot}\" -Wl,--fatal-warnings -O2")
                extension = ".wasm"
            }
            else if mos_c64 {
                buf.add_str(cmd, "\"${LLVM_MOS:-$HOME/.local/llvm-mos}/bin/mos-c64-clang\" -Os \"")
                buf.add_str(cmd, runtime_dir())
                buf.add_str(cmd, "/mos-c64-support.c\"")
                extension = ".prg"
            }
            else if mos {
                buf.add_str(cmd, "\"${LLVM_MOS:-$HOME/.local/llvm-mos}/bin/mos-sim-clang\" -Oz")
                extension = ".sim"
            }
            else {
                buf.add_str(cmd, "clang -O2")
                if cross {
                    buf.add_str(cmd, " --target=")
                    buf.add_str(cmd, importer.triple)
                }
                if windows {
                    ; the console support source: binary streams, usleep, the directory routines
                    ; (its directory comes from the environment here: cmd has no ${...:-...})
                    buf.add_str(cmd, " \"")
                    buf.add_str(cmd, runtime_dir())
                    buf.add_str(cmd, "/windows-console.c\"")
                    extension = ".exe"
                }
            }
            buf.add_str(cmd, " -Wno-override-module ")
            add_output(name, ".ll")
            buf.add_str(cmd, " -o ")
            add_output(name, extension)
            ; (the math library is apart on Linux)
            if not wasm and not mos and importer.triple != 0 and buf.cstr_len(importer.triple) > 10 and buf.bytes_equal(importer.triple + buf.cstr_len(importer.triple) - 9, "linux-gnu", 9)
                buf.add_str(cmd, " -lm")
        }
        run_cmd("building the program")
        built_ext = extension
        if not opt_run
            return
        buf.clear(cmd)
        if wasm
            buf.add_str(cmd, "wasmtime --dir=. ")
        else if mos_c64 or strings.compare(importer.target, "c64") == 0
            buf.add_str(cmd, "x64sc -autostart ")
        else if mos
            buf.add_str(cmd, "\"${LLVM_MOS:-$HOME/.local/llvm-mos}/bin/mos-sim\" ")
        else if strings.compare(importer.target, "cx16") == 0
            buf.add_str(cmd, "x16emu -run -prg ")
        else if not is_llvm {
            out.err()
            out.puts("-run: no emulator known for target ")
            out.puts(importer.target)
            out.nl()
            out.exit(1)
        }
        if windows {
            ; (cmd takes a / in a command for an option: the path with backslashes)
            if outdir != 0 {
                long k = 0
                while outdir[k] != 0 {
                    if outdir[k] == '/'
                        buf.add_byte(cmd, 92)
                    else
                        buf.add_byte(cmd, outdir[k])
                    k++
                }
                buf.add_byte(cmd, 92)
            }
            buf.add_str(cmd, name)
            buf.add_str(cmd, extension)
            run_cmd("running the program")
            return
        }
        if is_llvm and not wasm and not mos and outdir == 0
            buf.add_str(cmd, "./")
        add_output(name, extension)
        run_cmd("running the program")
    }

    sub write_output(^^ubyte name, str extension, ^^buf.Buf b) {
        buf.clear(parser.scratch)
        if outdir != 0 {
            buf.add_str(parser.scratch, outdir)
            buf.add_byte(parser.scratch, '/')
        }
        buf.add_str(parser.scratch, name)
        buf.add_str(parser.scratch, extension)
        buf.add_byte(parser.scratch, 0)
        if not io_platform.write_file(parser.scratch.data, b.data, b.len) {
            out.err()
            out.puts("can't write ")
            out.puts(parser.scratch.data)
            out.nl()
            out.exit(1)
        }
    }
}
