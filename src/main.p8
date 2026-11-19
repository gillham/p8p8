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
%import gen68k
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
%import triple
%import irread
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
    ^^buf.Buf xcompile = 0          ; -Xcompile: more arguments for clang
    ^^buf.Buf run_args = 0          ; after "--": the arguments of the program that -run starts
    ^^buf.Buf xlink = 0             ; -Xlink: more arguments for the link step
    ^^buf.Buf asm_defines = 0       ; -D NAME=VALUE: symbols for the assembler
    ^^ubyte opt_clang = 0           ; -clang: the clang that builds programs of the llvm targets
    ^^ubyte opt_level = 0           ; -O: 0, 1, 2, 3, s or z
    ^^ubyte opt_target = 0          ; -target: a name, or a .properties file
    bool opt_own = false            ; p8p8's 6502 code generator, not prog8c-llvm's back end
    bool is_m68k = false            ; the target is a 68000 machine
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
            or strings.compare(arg, "-target") == 0 or strings.compare(arg, "-codegen") == 0 or strings.compare(arg, "-cpu") == 0
            or strings.compare(arg, "-triple") == 0 or strings.compare(arg, "-Xcompile") == 0 or strings.compare(arg, "-encoding") == 0
            or strings.compare(arg, "-Xlink") == 0 or strings.compare(arg, "-D") == 0 or strings.compare(arg, "-clang") == 0
            or strings.compare(arg, "-O") == 0 or strings.compare(arg, "-address") == 0 or strings.compare(arg, "-breakinstr") == 0
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
        ; what follows "--" is for the program that -run starts
        uword dd = 1
        while dd < argc {
            ^^ubyte darg = sys.argv(dd)
            if darg[0] == '-' and darg[1] == '-' and darg[2] == 0 {
                uword ra = dd + 1
                run_args = buf.new(256)
                while ra < argc {
                    buf.add_str(run_args, " \"")
                    buf.add_str(run_args, sys.argv(ra))
                    buf.add_byte(run_args, '"')
                    ra++
                }
                argc = dd
                break
            }
            dd++
        }
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
            ; and -noasm (no assembly is made) and -dumpsymbols are its names for these
            if strings.compare(arg, "-noasm") == 0
                arg = "-check"
            if strings.compare(arg, "-dumpsymbols") == 0
                arg = "-symbols"
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
                if strings.compare(value, "llvm") == 0
                    opt_target = "llvm64"       ; (upstream's other name for it)
                i++
            }
            else if strings.compare(arg, "-h") == 0 or strings.compare(arg, "-help") == 0 or strings.compare(arg, "--help") == 0 {
                usage_status = 0        ; (asked for: not a mistake)
                usage()
            }
            else if strings.compare(arg, "-cpu") == 0 and value != 0 {
                ; the CPU to write 6502 code for, whatever the target's file says: 6502, 65c02, 65816, 45gs02
                long ck = 0
                while value[ck] != 0 {
                    if value[ck] >= 'A' and value[ck] <= 'Z'
                        value[ck] += 32
                    ck++
                }
                gen6502.cpu_option = value
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
            else if strings.compare(arg, "-Xcompile") == 0 and value != 0 {
                ; one more argument for clang (a sysroot, for another machine)
                if xcompile == 0
                    xcompile = buf.new(256)
                buf.add_str(xcompile, " \"")
                buf.add_str(xcompile, value)
                buf.add_byte(xcompile, '"')
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
            else if strings.compare(arg, "-ignorefootguns") == 0 {
                ; (upstream's: p8p8 has no such warnings to leave out)
            }
            else if strings.compare(arg, "-breakinstr") == 0 and value != 0 {
                if strings.compare(value, "brk") != 0 and strings.compare(value, "stp") != 0
                    usage()
                gen6502.break_instruction = value
                i++
            }
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
            else if strings.compare(arg, "-Xlink") == 0 and value != 0 {
                if xlink == 0
                    xlink = buf.new(256)
                buf.add_str(xlink, " \"")
                buf.add_str(xlink, value)
                buf.add_byte(xlink, '"')
                i++
            }
            else if strings.compare(arg, "-D") == 0 and value != 0 {
                if asm_defines == 0
                    asm_defines = buf.new(256)
                buf.add_str(asm_defines, " -D \"")
                buf.add_str(asm_defines, value)
                buf.add_byte(asm_defines, '"')
                i++
            }
            else if strings.compare(arg, "-clang") == 0 and value != 0 {
                opt_clang = value
                i++
            }
            else if strings.compare(arg, "-O") == 0 and value != 0 {
                if value[1] != 0 or not (value[0] == '0' or value[0] == '1' or value[0] == '2' or value[0] == '3' or value[0] == 's' or value[0] == 'z')
                    usage()
                opt_level = value
                i++
            }
            else if strings.compare(arg, "-address") == 0 and value != 0 {
                bool adok
                adok, irgen.option_address = target.parse_number(value)
                if not adok
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
                ; (it names the program file, so the program is built)
                output_file(value)
                opt_build = true
                i++
            }
            else if strings.compare(arg, "-verbose") == 0
                opt_verbose = true
            else if strings.compare(arg, "-meminfo") == 0
                opt_meminfo = true
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
    ; (windows-console.c, hosted-keys.c, mos-c64-support.c): P8P8_RUNTIME, "runtime" where the compiler
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

    ubyte usage_status = 1

    ; " -O" and the level of the command line, or the one given
    sub add_level(^^ubyte usual) {
        buf.add_str(cmd, " -O")
        if opt_level != 0
            buf.add_str(cmd, opt_level)
        else
            buf.add_str(cmd, usual)
    }

    sub usage() {
        out.puts("usage: p8c [options] file.p8 ...")
        out.nl()
        out.puts("  file.p8ir      in place of a source file: an IR file (as -ir writes it) is built for the target it names")
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
        out.puts("  -Xcompile arg  one more argument for clang (llvm32); can be repeated")
        out.nl()
        out.puts("  -srcdirs a:b   directories searched first for imported modules (a;b as well)")
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
        out.puts("  -check         only check the program, like prog8c -check")
        out.nl()
        out.puts("  -out dir       the directory for the output files (default: the current one)")
        out.nl()
        out.puts("  -o file        the program file: its directory is where the output goes, its name that of every output file")
        out.nl()
        out.puts("  -traceimports  print which file every imported module comes from")
        out.nl()
        out.puts("  -verbose       print the commands that are run, and let the assembler print its summary of the program")
        out.nl()
        out.puts("  -meminfo       for a 6502 machine: print what the program takes of main memory and of each overlay, and what is left")
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
        out.puts("                          (the same choice for the 68000 machines, with vasm and vlink)")
        out.nl()
        out.puts("  -cpu 6502|65c02|65816   for a 6502 machine: the CPU to write code for, in place of the one in the target's file")
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
        out.puts("  -Xlink arg     one more argument for the link step of the llvm targets, such as -lfoo; can be repeated")
        out.nl()
        out.puts("  -O level       how clang optimizes programs of the llvm targets: 0, 1, 2 (the default), 3, s or z")
        out.nl()
        out.puts("  -clang path    the clang that builds programs of the llvm targets")
        out.nl()
        out.puts("  -address A     load the program at address A ($hex or decimal), in place of %address")
        out.nl()
        out.puts("  -D NAME=VALUE  a symbol for the assembler; can be repeated")
        out.nl()
        out.puts("  -breakinstr brk|stp   that instruction at every %breakpoint as well")
        out.nl()
        out.puts("  -noasm         as -check;  -dumpsymbols: as -symbols")
        out.nl()
        out.puts("  -h, -help      this text")
        out.nl()
        out.exit(usage_status)
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
        ^^ubyte irtext = 0
        long irsize = 0
        if is_ir_file(path) {
            ; an IR file says what it is for: that is the target, unless -target names one
            irtext, irsize = file_bytes(path)
            if irtext == 0 {
                out.err()
                out.puts("can't read ")
                out.puts(path)
                out.nl()
                out.exit(1)
            }
            if opt_target == 0
                opt_target = ir_file_target(irtext, irsize)
        }
        ; the target: a machine with a configuration file (see target.p8), or one p8p8 knows by itself
        ; (without -target the program is for the machine p8c runs on)
        if opt_target == 0 and not explicit_mode
            opt_llvm = true         ; (the machine p8c runs on is an llvm target)
        if opt_target == 0 and sizeof(pointer) == 4
            importer.target = "llvm32"
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
            is_m68k = strings.compare(tname, "qemu68k") == 0 or buf.bytes_equal(tname, "amiga", 5)
            if not explicit_mode {
                ; no option says what to do: what prog8c does for the target.  A program for
                ; a machine, the LLVM IR for an llvm target, the IR for the virtual machine.
                if target.loaded or is_m68k
                    opt_build = true
                else if buf.bytes_equal(tname, "llvm", 4)
                    opt_llvm = true
                else if strings.compare(tname, "virtual") == 0
                    opt_ir = true
            }
            opt_own = opt_codegen == 1 or (opt_codegen == 0 and target.loaded and opt_build)
            ; a 68000 machine: p8p8's own code generator when a program is asked for
            ; (there is no other way to build one from here yet)
            if is_m68k
                opt_own = opt_codegen == 1 or (opt_codegen == 0 and opt_build)
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
        if strings.compare(importer.target, "llvm32") == 0 {
            ; llvm32: the platform is a triple profile, a file of the library; on a
            ; 32-bit machine, that machine's when nothing else is asked for
            if importer.triple == 0 and sizeof(pointer) == 4
                importer.triple = io_platform.host_triple()
            if not triple.load(importer.triple, lib_root) {
                out.err()
                out.puts("error: -triple ")
                if importer.triple != 0
                    out.puts(importer.triple)
                out.puts(": ")
                out.puts(triple.error_text)
                if triple.bad_key != 0 {
                    out.puts(": ")
                    out.puts(triple.bad_key)
                }
                out.nl()
                out.exit(1)
            }
        }
        else if importer.triple != 0 {
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
        if irtext != 0 {
            ; the IR is there already: no front end
            types.set_target(importer.target)
            encoding.set_target(importer.target)
            if parser.scratch == 0
                parser.scratch = buf.new(64)        ; (the driver's own scratch buffer is the parser's)
            crumb.at("reading the IR file")
            ^^ir.Program irprog = irread.read(irtext, irsize, path)
            if irprog == 0
                out.exit(1)
            if strings.compare(irprog.target, importer.target) != 0 {
                out.err()
                out.puts(path)
                out.puts(": error: the IR is for target ")
                out.puts(irprog.target)
                out.puts(", not ")
                out.puts(importer.target)
                out.nl()
                out.exit(1)
            }
            if not target.loaded
                irprog.options = 0          ; (the options are a target file's; without one, the defaults)
            ; the virtual registers that were moved into the zero page (irgen.zeropage_registers)
            ^^ir.Var rv = irprog.vars
            while rv != 0 {
                if rv.kind == ir.V_MEMVAR and strings.compare(rv.name, "cx16.r0") == 0 and target.number("virtual_registers", -1) >= 256 {
                    bool rok
                    long raddress
                    rok, raddress = target.parse_number(rv.init)
                    if rok and raddress < 256
                        irgen.vregs_moved_to = raddress
                }
                rv = rv.next
            }
            if opt_ir or opt_llvm or opt_build
                code_from_ir(irprog, irprog.name)
            return
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
        types.far_bits = 0
        if target.loaded and target.number("far_address_bits", 0) != 0 {
            ; (only for the CPU that has the instructions: the one of -cpu, or the target's)
            ^^ubyte cpuname = gen6502.cpu_option
            if cpuname == 0
                cpuname = target.text("cpu")
            if cpuname != 0 and (strings.compare(cpuname, "65816") == 0 or strings.compare(cpuname, "45gs02") == 0
                    or strings.compare(cpuname, "65c816") == 0 or strings.compare(cpuname, "w65c816") == 0)
                types.far_bits = target.number("far_address_bits", 0) as ubyte
        }
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
    bool opt_meminfo = false        ; -meminfo: after a 6502 program is built, how much memory it takes and leaves
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

    ; does the name end in .p8ir?
    sub is_ir_file(^^ubyte path) -> bool {
        long n = buf.cstr_len(path)
        return n > 5 and buf.bytes_equal(path + n - 5, ".p8ir", 5)
    }

    ; the compTarget of an IR file's options; 0 when it has none
    sub ir_file_target(^^ubyte data, long size) -> ^^ubyte {
        long k = 0
        while k + 11 < size {
            if data[k] == '<' and data[k + 1] == 'V'
                break               ; (<VARS>: the options are behind us)
            if data[k] == 'c' and buf.bytes_equal(data + k, "compTarget=", 11) {
                long from = k + 11
                long upto = from
                while upto < size and data[upto] != '\n' and data[upto] != '\r'
                    upto++
                return strtab.intern(data + from, (upto - from) as uword)
            }
            k++
        }
        return 0
    }

    sub generate_ir() {
        ^^importer.Module mainmod = importer.modules
        crumb.at("generating the IR")
        ^^ir.Program p = irgen.generate(mainmod.name)
        if diag.errors > 0
            return
        code_from_ir(p, mainmod.name)
    }

    ; What is asked for from the IR: the IR file, the LLVM IR, the assembly, the program.
    sub code_from_ir(^^ir.Program p, ^^ubyte oname) {
        if out_name != 0
            oname = out_name
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
        if opt_own and is_m68k {
            ; p8p8's own 68000 code generator: assembly for vasm
            buf.clear(b)
            crumb.at("generating 68000 code")
            gen68k.generate(p, b)
            if gen68k.errors > 0
                out.exit(1)
            write_output(oname, ".asm", b)
        }
        else if opt_own and not is_llvm {
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
    ; %breakpoint: after the labels in the file for VICE's monitor come the commands that
    ; set a breakpoint at each p8_breakpoint_N, as upstream writes them
    ; <name>.bankedcalls: the call-site IDs of the extsubs with a bank selector subroutine
    sub banked_calls_file(^^ubyte name) {
        ^^buf.Buf text = irgen.banked_calls()
        if text == 0
            return
        ^^buf.Buf path = buf.new(256)
        if outdir != 0 {
            buf.add_str(path, outdir)
            buf.add_byte(path, '/')
        }
        buf.add_str(path, name)
        buf.add_str(path, ".bankedcalls")
        buf.add_byte(path, 0)
        void io_platform.write_file(path.data, text.data, text.len)
    }

    sub breakpoint_list(^^ubyte name) {
        ^^buf.Buf path = buf.new(256)
        if outdir != 0 {
            buf.add_str(path, outdir)
            buf.add_byte(path, '/')
        }
        buf.add_str(path, name)
        buf.add_str(path, ".vice-mon-list")
        buf.add_byte(path, 0)
        long capacity = 4 * 1024 * 1024
        ^^ubyte text = mem.alloc(capacity)
        long length = io_platform.read_file(path.data, text, capacity - 4096)
        if length <= 0
            return
        ^^buf.Buf list = buf.new(1024)
        buf.add_str(list, "; breakpoint list now follows\n; ")
        buf.add_long(list, gen6502.breakpoints)
        buf.add_str(list, " breakpoints have been defined\ndel\n")
        ; a label's line is "al <address> .<name>"
        long at = 0
        while at < length {
            long stop = at
            while stop < length and text[stop] != '\n'
                stop++
            long k = at
            bool found = false
            while k + 14 <= stop {
                if buf.bytes_equal(text + k, "p8_breakpoint_", 14) {
                    found = true
                    break
                }
                k++
            }
            if found and stop - at > 4 and text[at] == 'a' and text[at + 1] == 'l' and text[at + 2] == ' ' {
                buf.add_str(list, "break $")
                k = at + 3
                while k < stop and text[k] != ' ' {
                    buf.add_byte(list, text[k])
                    k++
                }
                buf.add_byte(list, '\n')
            }
            at = stop + 1
        }
        if length + list.len < capacity {
            long n
            for n in 0 to list.len - 1
                text[length + n] = list.data[n]
            void io_platform.write_file(path.data, text, length + list.len)
        }
    }

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

    ; ---- a program with overlays (gen6502, "overlays") ----
    ; cmd holds the assembler's command up to its output.  The assembly is assembled once
    ; for every overlay and last for the main program (prog8_overlay = n: that part is
    ; there, the others are virtual).  The run for overlay n writes the main program too,
    ; with the overlay behind it at the window's address; its bytes are cut out of that.
    ; Then name.non is written, the main program and the overlays as records of 64tass's
    ; nonlinear format (length, address, bytes), each overlay after a record of one byte
    ; that chooses it (the target's "overlay_select": on the X16 the RAM bank's
    ; register), and the target's loader is assembled as name.prg.
    ^^buf.Buf ov_front = 0
    ^^buf.Buf ov_path = 0
    ^^buf.Buf ov_file = 0
    ^^buf.Buf ov_ext = 0
    long[256] ov_sizes              ; the bytes of each overlay's code
    long ov_loader_size = 0
    long ov_file_size = 0

    ; the value of a label in the assembler's list ("al C:0817 .name"), or -1
    sub label_value(^^ubyte data, long size, str name) -> long {
        long length = strings.length(name)
        long k = 0
        while k < size - length - 1 {
            if data[k] == '.' and buf.bytes_equal(data + k + 1, name, length) and (data[k + 1 + length] == '\n' or data[k + 1 + length] == '\r') {
                long e = k - 1
                while e > 0 and data[e] == ' '
                    e--
                long first = e
                while first > 0 and hex_value(data[first - 1]) >= 0
                    first--
                long value = 0
                while first <= e {
                    value = value * 16 + hex_value(data[first])
                    first++
                }
                return value
            }
            k++
        }
        return -1
    }

    sub report_number(long value, ubyte width) {
        buf.clear(ov_ext)
        buf.add_long(ov_ext, value)
        long pad = width as long - ov_ext.len
        while pad > 0 {
            out.putc(' ')
            pad--
        }
        buf.add_byte(ov_ext, 0)
        out.puts(ov_ext.data)
    }

    sub report_hex(long value) {
        out.putc('$')
        byte shift = 12
        while shift >= 0 {
            out.putc(buf.hex_digit(((value >> shift) & 15) as ubyte))
            shift -= 4
        }
    }

    ; -meminfo (and -verbose): what the program that was just built takes and leaves
    sub memory_report(^^ubyte name) {
        if ov_front == 0 {
            ov_front = buf.new(4096)
            ov_path = buf.new(1024)
            ov_ext = buf.new(64)
            ov_file = buf.new(65536)
        }
        ^^ubyte data
        long size
        if io_platform.file_size(ov_output(name, ".vice-mon-list")) <= 0
            return
        data, size = ov_read(ov_path.data)
        long first = label_value(data, size, "prog8_program_start")
        long last = label_value(data, size, "prog8_program_end")
        if first < 0 or last < 0
            return
        out.puts("memory of ")
        out.puts(name)
        out.puts(" (")
        out.puts(importer.target)
        out.puts("):")
        out.nl()
        out.puts("  main program  ")
        report_hex(first)
        out.putc('-')
        report_hex(last - 1)
        report_number(last - first, 7)
        out.puts(" bytes")
        if gen6502.memtop > 0 {
            out.puts(", ")
            report_number(gen6502.memtop - last, 1)
            out.puts(" free below ")
            report_hex(gen6502.memtop)
        }
        out.nl()
        if gen6502.overlay_max == 0
            return
        long window = gen6502.overlay_end - gen6502.overlay_start
        ubyte n
        for n in 1 to gen6502.overlay_max {
            if ov_sizes[n] != 0 {
                out.puts("  overlay ")
                report_number(n, 3)
                out.puts("   ")
                report_hex(gen6502.overlay_start)
                out.putc('-')
                report_hex(gen6502.overlay_start + ov_sizes[n] - 1)
                report_number(ov_sizes[n], 7)
                out.puts(" bytes, ")
                report_number(window - ov_sizes[n], 1)
                out.puts(" free of ")
                report_number(window, 1)
                out.nl()
            }
        }
        out.puts("  files: ")
        out.puts(name)
        if target.text("overlay_loader") != 0
            out.puts(".prg (the loader) ")
        else
            out.puts(".prg ")
        report_number(ov_loader_size, 1)
        out.puts(" bytes, ")
        out.puts(name)
        out.puts(".non ")
        report_number(ov_file_size, 1)
        out.puts(" bytes")
        out.nl()
    }

    sub ov_extension(str text, ubyte n) -> ^^ubyte {
        buf.clear(ov_ext)
        buf.add_str(ov_ext, text)
        if n != 255
            buf.add_long(ov_ext, n)
        buf.add_byte(ov_ext, 0)
        return ov_ext.data
    }

    ; the path of an output file, in ov_path
    sub ov_output(^^ubyte name, ^^ubyte extension) -> ^^ubyte {
        buf.clear(ov_path)
        if outdir != 0 {
            buf.add_str(ov_path, outdir)
            buf.add_byte(ov_path, '/')
        }
        buf.add_str(ov_path, name)
        buf.add_str(ov_path, extension)
        buf.add_byte(ov_path, 0)
        return ov_path.data
    }

    ; a file's bytes, in memory that is the program's from now on
    sub ov_read(^^ubyte path) -> ^^ubyte, long {
        long size = io_platform.file_size(path)
        if size <= 0 {
            out.err()
            out.puts("cannot read ")
            out.puts(path)
            out.nl()
            out.exit(1)
        }
        ^^ubyte data = mem.alloc(size + 1)
        void io_platform.read_file(path, data, size)
        return data, size
    }

    sub ov_word(long value) {
        buf.add_byte(ov_file, (value & 255) as ubyte)
        buf.add_byte(ov_file, ((value >> 8) & 255) as ubyte)
    }

    sub overlay_build(^^ubyte name) {
        if ov_front == 0 {
            ov_front = buf.new(4096)
            ov_path = buf.new(1024)
            ov_ext = buf.new(64)
            ov_file = buf.new(65536)
        }
        buf.clear(ov_front)
        buf.add_bytes(ov_front, cmd.data, cmd.len)
        ubyte n = gen6502.overlay_max
        repeat {
            buf.clear(cmd)
            buf.add_bytes(cmd, ov_front.data, ov_front.len)
            buf.add_str(cmd, " -D prog8_overlay=")
            buf.add_long(cmd, n)
            buf.add_str(cmd, " --output ")
            add_output(name, ov_extension(".ov", n))
            buf.add_byte(cmd, ' ')
            add_output(name, ".asm")
            run_cmd("building the program")
            if n == 0
                break
            n--
        }
        ; the file with everything in it
        buf.clear(ov_file)
        ^^ubyte data
        long size
        data, size = ov_read(ov_output(name, ov_extension(".ov", 0)))
        long load = data[0] + (data[1] as long << 8)
        ^^ubyte loader = target.text("overlay_loader")
        if loader != 0 {
            ov_word(size - 2)
            ov_word(load)
            buf.add_bytes(ov_file, data + 2, size - 2)
        }
        else {
            ; no loader: the main program is the .prg itself, and brings its overlays in
            if not io_platform.write_file(ov_output(name, ".prg"), data, size) {
                out.err()
                out.puts("cannot write ")
                out.puts(ov_path.data)
                out.nl()
                out.exit(1)
            }
            ov_loader_size = size
        }
        long select = target.number("overlay_select", 0)
        long window = gen6502.overlay_start
        for n in 1 to gen6502.overlay_max {
            data, size = ov_read(ov_output(name, ov_extension(".ov", n)))
            long skip = window - load + 2
            ov_sizes[n] = 0
            if size > skip {
                ov_sizes[n] = size - skip
                ov_word(1)
                ov_word(select)
                buf.add_byte(ov_file, n)
                ov_word(size - skip)
                ov_word(window)
                buf.add_bytes(ov_file, data + skip, size - skip)
            }
        }
        if loader != 0 {
            ; (and the bank that a program finds when it is started)
            ov_word(1)
            ov_word(select)
            buf.add_byte(ov_file, 1)
        }
        ov_word(0)
        ov_file_size = ov_file.len
        if not io_platform.write_file(ov_output(name, ".non"), ov_file.data, ov_file.len) {
            out.err()
            out.puts("cannot write ")
            out.puts(ov_path.data)
            out.nl()
            out.exit(1)
        }
        ; (what the assembler wrote for each part has been used)
        for n in 0 to gen6502.overlay_max
            io_platform.delete_file(ov_output(name, ov_extension(".ov", n)))
        if loader == 0
            return
        ; where the program begins: the assembler's list of labels says
        data, size = ov_read(ov_output(name, ".vice-mon-list"))
        long entry = label_value(data, size, "prog8_entrypoint")
        if entry < 0 {
            out.err()
            out.puts("a program with overlays needs a launcher: no prog8_entrypoint in ")
            out.puts(ov_path.data)
            out.nl()
            out.exit(1)
        }
        ; the loader: a few lines that name the file and the entry, and the target's code
        buf.clear(ov_file)
        buf.add_str(ov_file, "; the loader of ")
        buf.add_str(ov_file, name)
        buf.add_str(ov_file, ": written by p8c\np8_entry = ")
        buf.add_long(ov_file, entry)
        buf.add_str(ov_file, "\np8_file  .macro\n    .byte  ")
        gen6502.petscii_name(ov_file, name)
        buf.add_str(ov_file, "\n    .endm\n    .include \"")
        buf.add_str(ov_file, loader)
        buf.add_str(ov_file, "\"\n")
        if not io_platform.write_file(ov_output(name, ".loader.asm"), ov_file.data, ov_file.len) {
            out.err()
            out.puts("cannot write ")
            out.puts(ov_path.data)
            out.nl()
            out.exit(1)
        }
        buf.clear(cmd)
        buf.add_str(cmd, "64tass")
        if gen6502.c816
            buf.add_str(cmd, " --m65816")
        else if gen6502.c02
            buf.add_str(cmd, " --m65c02")
        buf.add_str(cmd, " --cbm-prg --ascii --case-sensitive --no-monitor")
        if not opt_verbose
            buf.add_str(cmd, " --quiet")
        if target.dir != 0 {
            buf.add_str(cmd, " -I \"")
            buf.add_str(cmd, target.dir)
            buf.add_byte(cmd, '"')
        }
        buf.add_str(cmd, " --output ")
        add_output(name, ".prg")
        buf.add_byte(cmd, ' ')
        add_output(name, ".loader.asm")
        run_cmd("building the program's loader")
        ov_loader_size = io_platform.file_size(ov_output(name, ".prg"))
    }

    sub hex_value(ubyte c) -> byte {
        if c >= '0' and c <= '9'
            return (c - '0') as byte
        if c >= 'a' and c <= 'f'
            return (c - 'a' + 10) as byte
        if c >= 'A' and c <= 'F'
            return (c - 'A' + 10) as byte
        return -1
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

    ; runs a 68000 program: qemu68k in QEMU, an Amiga program in vamos (which runs
    ; programs that only use the console; P8P8_VAMOS names it)
    sub run_68k(^^ubyte name) {
        buf.clear(cmd)
        if buf.bytes_equal(importer.target, "amiga", 5) {
            if strings.compare(importer.target, "amiga500") == 0
                buf.add_str(cmd, "\"${P8P8_VAMOS:-vamos}\" -C 68000 ")
            else
                buf.add_str(cmd, "\"${P8P8_VAMOS:-vamos}\" -C 68020 ")
            add_output(name, "")
        }
        else {
            buf.add_str(cmd, "qemu-system-m68k -M virt -cpu m68020 -m 1M -nographic -kernel ")
            add_output(name, ".elf")
        }
        run_cmd("running the program")
    }

    sub build(^^ubyte name, bool is_llvm) {
        if cmd == 0
            cmd = buf.new(512)
        buf.clear(cmd)
        bool llvm32 = strings.compare(importer.target, "llvm32") == 0
        bool mos = strings.compare(importer.target, "llvm16") == 0
        bool mos_c64 = mos and importer.triple_library != 0
        bool windows = is_llvm and not llvm32 and not mos and importer.triple != 0 and strings.compare(importer.triple, "x86_64-pc-windows-msvc") == 0
        ^^ubyte extension = ""
        if is_m68k and opt_own {
            ; the assembly that p8p8 wrote: vasm makes an object file, vlink the program,
            ; laid out by the target's link.ld in the library
            if buf.bytes_equal(importer.target, "amiga", 5) {
                ; AmigaOS: vasm writes the program file itself, a hunk file without an extension
                if strings.compare(importer.target, "amiga500") == 0 {
                    ; a 68000 and Kickstart 1.3's hunks.  A program with floats needs an FPU and,
                    ; for the floats library's own assembly, a 68020, as upstream has it.
                    if gen68k.uses_fpu
                        buf.add_str(cmd, "vasmm68k_mot -m68020 -m68881")
                    else
                        buf.add_str(cmd, "vasmm68k_mot -m68000")
                    buf.add_str(cmd, " -Fhunkexe -kick1hunks -opt-speed -ldots -spaces -nosym -quiet -o ")
                }
                else
                    buf.add_str(cmd, "vasmm68k_mot -m68020 -m68881 -Fhunkexe -opt-speed -ldots -spaces -nosym -quiet -o ")
                add_output(name, "")
                buf.add_byte(cmd, ' ')
                add_output(name, ".asm")
                run_cmd("assembling the program")
                built_ext = ""
                if opt_run
                    run_68k(name)
                return
            }
            buf.add_str(cmd, "vasmm68k_mot -m68020 -m68881 -Felf -opt-speed -ldots -spaces -quiet -o ")
            add_output(name, ".o")
            buf.add_byte(cmd, ' ')
            add_output(name, ".asm")
            run_cmd("assembling the program")
            buf.clear(cmd)
            buf.add_str(cmd, "vlink -b elf32m68k -n -T \"")
            buf.add_str(cmd, lib_root)
            buf.add_str(cmd, "/prog8lib/")
            buf.add_str(cmd, importer.target)
            buf.add_str(cmd, "/link.ld\" -o ")
            add_output(name, ".elf")
            buf.add_byte(cmd, ' ')
            add_output(name, ".o")
            run_cmd("linking the program")
            built_ext = ".elf"
            if opt_run
                run_68k(name)
            return
        }
        if not is_llvm and opt_own {
            ; the assembly that p8p8 wrote: 64tass makes the program
            ; (the options upstream gives 64tass for each output type)
            extension = ".prg"
            buf.add_str(cmd, "64tass")
            ; (the CPU on the command line too: it is what ".cpu 'default'" goes back to after
            ; assembly text that switched to another for a few lines)
            if gen6502.c45
                buf.add_str(cmd, " --m45gs02")
            else if gen6502.c816
                buf.add_str(cmd, " --m65816")
            else if gen6502.c02
                buf.add_str(cmd, " --m65c02")
            if asm_defines != 0
                buf.add_bytes(cmd, asm_defines.data, asm_defines.len)
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
            if gen6502.overlay_max != 0 {
                ; a program with overlays: the assembler once for each part, then the
                ; file that holds them all and the loader that reads it
                overlay_build(name)
                built_ext = ".prg"
                if opt_meminfo or opt_verbose
                    memory_report(name)
                if gen6502.breakpoints != 0
                    breakpoint_list(name)
                banked_calls_file(name)
                return
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
            if is_m68k {
                ; (a 68000 machine: prog8c-llvm's back end writes the program as p8p8's own does)
                run_cmd("building the program")
                built_ext = ".elf"
                if buf.bytes_equal(importer.target, "amiga", 5)
                    built_ext = ""
                if opt_run
                    run_68k(name)
                return
            }
        }
        else {
            if llvm32 {
                ; the triple profile's clang arguments.  Apple's clang has no WebAssembly:
                ; there it is Homebrew's unless P8P8_WASM_CLANG names another.
                if buf.bytes_equal(triple.name, "wasm", 4)
                    buf.add_str(cmd, "\"${P8P8_WASM_CLANG:-/opt/homebrew/opt/llvm/bin/clang}\" ")
                else if opt_clang != 0 {
                    buf.add_byte(cmd, '"')
                    buf.add_str(cmd, opt_clang)
                    buf.add_str(cmd, "\" ")
                }
                else
                    buf.add_str(cmd, "\"${P8P8_CLANG:-clang}\" ")
                buf.add_str(cmd, triple.clang_args)
                add_level("2")
                if xcompile != 0
                    buf.add_bytes(cmd, xcompile.data, xcompile.len)
                if triple.getkey_source != 0 and (llvmgen.console_keys or llvmgen.console_size) {
                    buf.add_str(cmd, " \"")
                    buf.add_str(cmd, runtime_dir())
                    buf.add_byte(cmd, '/')
                    buf.add_str(cmd, triple.getkey_source)
                    buf.add_byte(cmd, '"')
                }
                extension = triple.output_extension
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
                if opt_clang != 0 {
                    buf.add_byte(cmd, '"')
                    buf.add_str(cmd, opt_clang)
                    buf.add_byte(cmd, '"')
                }
                else
                    buf.add_str(cmd, "clang")
                add_level("2")
                if cross {
                    buf.add_str(cmd, " --target=")
                    buf.add_str(cmd, importer.triple)
                }
                if llvmgen.console_keys or llvmgen.console_size {
                    ; the console runtime: keys in raw mode, the terminal's size
                    buf.add_str(cmd, " \"")
                    buf.add_str(cmd, runtime_dir())
                    buf.add_str(cmd, "/hosted-keys.c\"")
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
            if llvm32 and triple.link_args != 0 {
                buf.add_byte(cmd, ' ')
                buf.add_str(cmd, triple.link_args)
            }
            if not llvm32 and not mos and importer.triple != 0 and buf.cstr_len(importer.triple) > 10 and buf.bytes_equal(importer.triple + buf.cstr_len(importer.triple) - 9, "linux-gnu", 9)
                buf.add_str(cmd, " -lm")
            if xlink != 0
                buf.add_bytes(cmd, xlink.data, xlink.len)
        }
        run_cmd("building the program")
        built_ext = extension
        if opt_own and not is_llvm and (opt_meminfo or opt_verbose)
            memory_report(name)
        if opt_own and not is_llvm and gen6502.breakpoints != 0
            breakpoint_list(name)
        banked_calls_file(name)
        if not opt_run
            return
        buf.clear(cmd)
        if llvm32 {
            ; the profile's run command with the program for {file}, or the program itself
            if triple.run_command == 0 {
                if outdir == 0
                    buf.add_str(cmd, "./")
                add_output(name, extension)
            }
            else {
                long rk = 0
                while triple.run_command[rk] != 0 {
                    if buf.bytes_equal(triple.run_command + rk, "{file}", 6) {
                        add_output(name, extension)
                        rk += 6
                    }
                    else {
                        buf.add_byte(cmd, triple.run_command[rk])
                        rk++
                    }
                }
            }
            run_cmd("running the program")
            return
        }
        if mos_c64 or strings.compare(importer.target, "c64") == 0
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
        if is_llvm and not mos and outdir == 0
            buf.add_str(cmd, "./")
        add_output(name, extension)
        if is_llvm and run_args != 0
            buf.add_bytes(cmd, run_args.data, run_args.len)
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
