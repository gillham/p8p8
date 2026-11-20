; The checker: the rules of upstream's AstChecker that are not about types
; (the typer does those).  It runs after the typer over the whole program
; and checks the program structure, where directives may occur, what may
; appear in a block, variable declarations, subroutines ending in a return,
; loops and break/continue, when choices, constant index bounds, and
; assignments to constants and strings.  Messages follow upstream's wording
; so that the two compilers can be compared.

%import ast
%import token
%import types
%import symtab
%import importer
%import source
%import strtab
%import diag
%import typer
%import buf
%import parser
%import strings
%import resolver
%import out

checker {
    %option ignore_unused

    const ubyte L_MODULE = 0
    const ubyte L_BLOCK = 1
    const ubyte L_SUB = 2

    long checks = 0
    uword loop_depth = 0
    ^^symtab.Sym current_sub = 0

    ; the target's limits, set by run()
    long array_limit = 65535
    quad max_address = $ffff

    ; the highest address data can have: on a machine with far memory (types.far_bits) more
    ; than a pointer names
    sub max_data_address() -> quad {
        if types.far_bits > 16 and types.POINTER_SIZE == 2 {
            quad top = 1
            top <<= types.far_bits
            return top - 1
        }
        return max_address
    }

    ; the name of a memory mapped variable at an address of more than 16 bits
    sub far_variable(^^ast.Node e) -> bool {
        if e == 0 or e.kind != ast.N_IDENT or e.extra == 0 or types.far_bits == 0
            return false
        ^^symtab.Sym s = e.extra
        if s.kind != symtab.K_MEMVAR or s.decl == 0 or s.decl.kind != ast.N_VARDECL or s.decl.b == 0
            return false
        bool ok
        quad v
        ok, v = typer.const_eval(s.decl.b)
        return ok and v > 65535
    }

    ; a constant that is an address in far memory
    sub far_constant(^^ast.Node e) -> bool {
        if e == 0 or types.far_bits == 0
            return false
        bool ok
        quad v
        ok, v = typer.const_eval(e)
        return ok and v >= 0 and v <= max_data_address()
    }

    ; interned names
    ^^ubyte main_name = 0
    ^^ubyte start_name = 0
    ^^ubyte dirty_name = 0

    ; directives that may only occur at module level, and only once
    str[] module_only = ["output", "launcher", "zeropage", "zpreserved", "zpallowed", "address", "varsaddress", "memtop", "import", "encoding"]
    str[] once_only = ["output", "launcher", "zeropage", "address", "memtop", "varsaddress", "encoding"]
    str[] not_in_module = ["align", "breakpoint", "asminclude", "asmbinary"]
    str[] known_directives = ["address", "align", "asm", "asmbinary", "asminclude", "assert", "breakpoint", "bssaddress", "encoding",
        "import", "ir", "jmptable", "launcher", "link", "memtop", "option", "output", "overlay", "slabsaddress", "varsaddress",
        "zeropage", "zpallowed", "zpreserved"]
    str[] option_names = ["enable_floats", "force_output", "no_sysinit", "merge", "verafxmuls", "no_symbol_prefixing", "ignore_unused", "romable", "amiga_chipram", "private_symbols", "noframe", "overlay_data"]
    str[] block_options = ["force_output", "merge", "verafxmuls", "no_symbol_prefixing", "ignore_unused", "amiga_chipram", "private_symbols", "overlay_data"]
    str[] module_options = ["enable_floats", "no_sysinit", "no_symbol_prefixing", "ignore_unused", "romable", "private_symbols"]
    str[] zeropage_kinds = ["basicsafe", "floatsafe", "kernalsafe", "dontuse", "full"]
    str[] output_kinds = ["raw", "prg", "xex", "library"]
    str[] launcher_kinds = ["basic", "none"]

    sub init() {
        main_name = strtab.intern("main", 4)
        start_name = strtab.intern("start", 5)
        dirty_name = strtab.intern("dirty", 5)
    }

    sub run() {
        if main_name == 0
            init()
        set_target(importer.target)
        ^^ast.Node wide = typer.wide_integer()
        if no_quads and wide != 0 {
            ; (a number of more than 32 bits, even where it was folded away)
            begin_message("64-bit integer types (quad/uquad) are not supported on target ")
            buf.add_str(parser.scratch, target_name)
            error_scratch(wide)
        }
        program_structure()
        ^^importer.Module m = importer.modules
        while m != 0 {
            module_directives(m.tree)
            ^^ast.Node e = m.tree.a
            while e != 0 {
                if e.kind == ast.N_DIRECTIVE
                    directive(e, L_MODULE)
                else if e.kind == ast.N_BLOCK
                    block(e)
                e = e.next
            }
            m = m.next
        }
    }

    bool no_floats = false          ; the target has no floating point
    bool llvm_target = false        ; no native assembly there
    bool no_quads = false           ; the 6502 targets have no 64 bit integers
    ^^ubyte target_name = 0

    sub set_target(^^ubyte name) {
        no_floats = strings.compare(name, "llvm16") == 0
        llvm_target = buf.bytes_equal(name, "llvm", 4)
        target_name = name
        no_quads = types.POINTER_SIZE == 2 and not llvm_target
        array_limit = 256
        max_address = $ffff
        if strings.compare(name, "llvm64") == 0 or strings.compare(name, "llvm32") == 0
            or strings.compare(name, "llvm16") == 0 or strings.compare(name, "virtual") == 0
            array_limit = 65535
        else if strings.compare(name, "amiga500") == 0 or strings.compare(name, "amiga1200") == 0
            or strings.compare(name, "qemu68k") == 0
            array_limit = 32768
        if types.POINTER_SIZE == 4
            max_address = $ffffffff
        else if types.POINTER_SIZE == 8
            max_address = $7fffffffffffffff
        ; (llvm16's library maps the virtual registers at $ff0000, where the virtual machine has
        ;  them: the LLVM backend gives memory-mapped variables storage of their own)
        if strings.compare(name, "llvm16") == 0
            max_address = $ffffffff
    }

    ; ---- errors ----

    sub error(^^ast.Node at, str message) {
        diag.error_at(source.get(at.file), at.line, at.col, message)
    }

    sub warning(^^ast.Node at, str message) {
        diag.warning_at(source.get(at.file), at.line, at.col, message)
    }

    ; an error whose message is in parser.scratch
    sub error_scratch(^^ast.Node at) {
        buf.add_byte(parser.scratch, 0)
        diag.error_at(source.get(at.file), at.line, at.col, parser.scratch.data)
    }

    sub begin_message(str text) {
        buf.clear(parser.scratch)
        buf.add_str(parser.scratch, text)
    }

    ; ---- the program ----

    ; A block that is declared more than once has one declaration without %option merge,
    ; which the others add to.
    sub merged_blocks() {
        ^^importer.Module m = importer.modules
        while m != 0 {
            ^^ast.Node e = m.tree.a
            while e != 0 {
                if e.kind == ast.N_BLOCK and symtab.has_option(e.a, symtab.kw_merge) and first_of_name(e) {
                    uword count = 0
                    uword plain = 0
                    ^^importer.Module m2 = importer.modules
                    while m2 != 0 {
                        ^^ast.Node e2 = m2.tree.a
                        while e2 != 0 {
                            if e2.kind == ast.N_BLOCK and e2.name == e.name {
                                count++
                                if not symtab.has_option(e2.a, symtab.kw_merge)
                                    plain++
                            }
                            e2 = e2.next
                        }
                        m2 = m2.next
                    }
                    if count > 1 and plain == 0 {
                        begin_message("all declarations of block '")
                        buf.add_str(parser.scratch, e.name)
                        buf.add_str(parser.scratch, "' have %option merge")
                        error_scratch(e)
                    }
                }
                e = e.next
            }
            m = m.next
        }
    }

    ; is this the first block of its name in the program?
    sub first_of_name(^^ast.Node b) -> bool {
        ^^importer.Module m = importer.modules
        while m != 0 {
            ^^ast.Node e = m.tree.a
            while e != 0 {
                if e.kind == ast.N_BLOCK and e.name == b.name
                    return e == b
                e = e.next
            }
            m = m.next
        }
        return true
    }

    sub program_structure() {
        ^^ast.Node first_main = 0
        uword mains = 0
        ^^importer.Module m = importer.modules
        while m != 0 {
            ^^ast.Node e = m.tree.a
            while e != 0 {
                if e.kind == ast.N_BLOCK and e.name == main_name and not symtab.has_option(e.a, symtab.kw_merge) {
                    ; (a main block with %option merge adds to the one that has none)
                    mains++
                    if first_main == 0
                        first_main = e
                }
                e = e.next
            }
            m = m.next
        }
        merged_blocks()
        if mains > 1
            error(first_main, "more than one 'main' block")
        if mains == 0 {
            error(importer.modules.tree, "there is no 'main' block")
            return
        }
        ^^symtab.Sym bs = first_main.extra
        ^^symtab.Sym st = 0
        if bs != 0 and bs.inner != 0
            st = symtab.find_in(bs.inner, start_name)
        if st == 0 or st.kind != symtab.K_SUB {
            error(first_main, "missing program entrypoint ('start' subroutine in 'main' block)")
            return
        }
        ^^ast.Node d = st.decl
        if d.a != 0 or d.b != 0
            error(d, "program entrypoint subroutine can't have parameters and/or return values")
        if (d.flags & ast.F_PRIVATE) != 0
            error(d, "program entrypoint subroutine 'start' cannot be private")
        checks++
    }

    ; ---- directives ----

    sub name_in(^^ubyte name, ^^pointer table, ubyte count) -> bool {
        ubyte i
        for i in 0 to count - 1 {
            if strings.compare(name, table[i]) == 0
                return true
        }
        return false
    }

    ; the directives that may occur only once in a module
    sub module_directives(^^ast.Node tree) {
        ^^ast.Node d = tree.a
        while d != 0 {
            if d.kind == ast.N_DIRECTIVE and name_in(d.name, &once_only, len(once_only)) {
                ; every occurrence of a repeated directive is reported
                ^^ast.Node other = tree.a
                while other != 0 {
                    if other != d and other.kind == ast.N_DIRECTIVE and other.name == d.name {
                        error(d, "directive can just occur once")
                        break
                    }
                    other = other.next
                }
            }
            d = d.next
        }
    }

    sub directive(^^ast.Node d, ubyte level) {
        ^^ast.Node arg = d.a
        long nargs = ast.list_length(arg)
        ^^ubyte nm = d.name
        checks++
        if not name_in(nm, &known_directives, len(known_directives)) {
            begin_message("invalid directive %")
            buf.add_str(parser.scratch, nm)
            error_scratch(d)
            return
        }
        if strings.compare(nm, "link") == 0 and not llvm_target
            error(d, "%link is only available on the llvm targets")
        if level == L_SUB and strings.compare(nm, "jmptable") == 0
            error(d, "this directive may only occur in a block")
        if name_in(nm, &module_only, len(module_only)) {
            if level != L_MODULE
                error(d, "this directive may only occur at module level")
        }
        else if name_in(nm, &not_in_module, len(not_in_module)) {
            if level == L_MODULE
                error(d, "this directive can't be used here")
        }
        if strings.compare(nm, "option") == 0 {
            if arg == 0 {
                error(d, "missing option directive argument(s)")
                return
            }
            while arg != 0 {
                if arg.kind != ast.N_IDENT or not name_in(arg.name, &option_names, len(option_names))
                    error(d, "invalid option directive argument(s)")
                else if level == L_BLOCK and not name_in(arg.name, &block_options, len(block_options))
                    error(d, "using an option that is not valid for blocks")
                else if strings.compare(arg.name, "amiga_chipram") == 0 and not buf.bytes_equal(target_name, "amiga", 5)
                    error(d, "amiga_chipram option is only valid on amiga targets")
                else if level == L_SUB and strings.compare(arg.name, "noframe") != 0
                    error(d, "using an option that is not valid for subroutines")
                else if level == L_MODULE and not name_in(arg.name, &module_options, len(module_options))
                    error(d, "using an option that is not valid for modules")
                arg = arg.next
            }
        }
        else if strings.compare(nm, "zeropage") == 0 {
            if nargs != 1 or arg.kind != ast.N_IDENT or not name_in(arg.name, &zeropage_kinds, len(zeropage_kinds))
                error(d, "invalid zp type, expected basicsafe, floatsafe, kernalsafe, dontuse, or full")
        }
        else if strings.compare(nm, "output") == 0 {
            if nargs != 1 or arg.kind != ast.N_IDENT or not name_in(arg.name, &output_kinds, len(output_kinds))
                error(d, "invalid output directive type")
        }
        else if strings.compare(nm, "launcher") == 0 {
            if nargs != 1 or arg.kind != ast.N_IDENT or not name_in(arg.name, &launcher_kinds, len(launcher_kinds))
                error(d, "invalid launcher directive type")
        }
        else if strings.compare(nm, "address") == 0 or strings.compare(nm, "varsaddress") == 0 {
            if nargs != 1 or arg.kind != ast.N_INT
                error(d, "invalid address directive, expected numeric address argument")
        }
        else if strings.compare(nm, "memtop") == 0 {
            if nargs != 1 or arg.kind != ast.N_INT
                error(d, "invalid memtop directive, expected numeric address argument")
        }
        else if strings.compare(nm, "zpreserved") == 0 or strings.compare(nm, "zpallowed") == 0 {
            if nargs != 2 or arg.kind != ast.N_INT or arg.next.kind != ast.N_INT
                error(d, "requires two addresses (start, end)")
            else if arg.value > 255 or arg.next.value > 255
                error(d, "start and end addresss must be in Zeropage so 0..255")
        }
        else if strings.compare(nm, "overlay") == 0 {
            ; (p8p8's own: the code of the block, or of the one subroutine, goes into that
            ; overlay on a machine that has them)
            ; In a module it is a list: the number, then the blocks and subroutines that
            ; are in that overlay ("%overlay 2, view, main.execute").
            if nargs < 1 or arg.kind != ast.N_INT or arg.value < 1 or arg.value > 255
                error(d, "invalid overlay directive, expected a number from 1 to 255")
            else if level == L_MODULE {
                if nargs == 1
                    error(d, "%overlay in a module needs the blocks and subroutines that are in the overlay after its number")
                ^^ast.Node oa = arg.next
                while oa != 0 {
                    if oa.kind != ast.N_IDENT
                        error(oa, "expected the name of a block or of a subroutine (block.name)")
                    oa = oa.next
                }
            }
            else if nargs != 1
                error(d, "%overlay in a block or a subroutine takes the overlay's number and nothing else")
        }
        else if strings.compare(nm, "breakpoint") == 0 {
            if nargs != 0
                error(d, "invalid breakpoint directive, expected no arguments")
        }
        else if llvm_target and (strings.compare(nm, "asminclude") == 0 or strings.compare(nm, "asmbinary") == 0) {
            begin_message("%")
            buf.add_str(parser.scratch, nm)
            buf.add_str(parser.scratch, " with native code can't be used on the llvm targets, use %ir instead")
            error_scratch(d)
        }
        else if strings.compare(nm, "asminclude") == 0 {
            if nargs != 1 or arg.kind != ast.N_STR
                error(d, "invalid asminclude directive, expected argument: \"filename\"")
        }
        else if strings.compare(nm, "asmbinary") == 0 {
            if nargs == 0 or nargs > 3 or arg.kind != ast.N_STR
                error(d, "invalid asmbinary directive, expected arguments: \"filename\" [, offset [, length ]]")
            else if nargs >= 2 and arg.next.kind != ast.N_INT
                error(d, "invalid asmbinary directive, expected arguments: \"filename\" [, offset [, length ]]")
            else if nargs == 3 and arg.next.next.kind != ast.N_INT
                error(d, "invalid asmbinary directive, expected arguments: \"filename\" [, offset [, length ]]")
        }
        else if strings.compare(nm, "align") == 0 {
            if nargs != 1 or arg.kind != ast.N_INT
                error(d, "missing correct alignment size")
            else if arg.value < 2 or arg.value > 65536
                error(d, "invalid alignment size")
        }
        else if strings.compare(nm, "assert") == 0 {
            if nargs == 0 or nargs > 2 {
                error(d, "invalid assert directive, expected a constant expression and an optional message string")
                return
            }
            bool ok
            quad v
            if sizeof_of_str(arg) {
                error(arg, "Syntax error: sizeof argument should be an identifier, number, or type name")
                return
            }
            ok, v = typer.const_eval(arg)
            if not ok and arg.kind == ast.N_BINARY and arg.a != 0 and arg.b != 0 and typer.float_eval(arg.a) {
                ; a comparison of floating point constants
                float left = typer.float_value
                if typer.float_eval(arg.b) {
                    float right = typer.float_value
                    ok = true
                    when arg.op {
                        token.T_EQ -> v = (left == right) as ubyte
                        token.T_NE -> v = (left != right) as ubyte
                        token.T_LT -> v = (left < right) as ubyte
                        token.T_GT -> v = (left > right) as ubyte
                        token.T_LE -> v = (left <= right) as ubyte
                        token.T_GE -> v = (left >= right) as ubyte
                        else -> ok = false
                    }
                }
            }
            if not ok
                error(arg, "assert expression is not a compile-time constant")
            else if v == 0 {
                if nargs == 2 and arg.next.kind == ast.N_STR {
                    begin_message("assertion failed: ")
                    buf.add_str(parser.scratch, arg.next.name)
                    error_scratch(d)
                }
                else
                    error(d, "assertion failed")
            }
            if nargs == 2 and arg.next.kind != ast.N_STR
                error(d, "invalid assert directive, second argument should be a message string")
        }
    }

    ; ---- blocks and statements ----

    sub block(^^ast.Node b) {
        check_name(b, b.name)
        keyword_name(b, b.name, "block name cannot be a keyword")
        if symtab.builtins != 0 and symtab.find_in(symtab.builtins, b.name) != 0
            error(b, "builtin function cannot be redefined")
        if b.b != 0 and llvm_target {
            begin_message("specific block addresses are not available on the hosted ")
            buf.add_str(parser.scratch, target_name)
            buf.add_str(parser.scratch, " target")
            error_scratch(b)
        }
        bool bad = false
        ^^ast.Node prev = 0
        ^^ast.Node s = b.a
        while s != 0 {
            bool ok = true
            when s.kind {
                ast.N_ALIAS, ast.N_DIRECTIVE, ast.N_LABEL, ast.N_VARDECL, ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB,
                ast.N_STRUCT, ast.N_UNION, ast.N_ENUM, ast.N_ASM, ast.N_REMOVED -> ok = true
                else -> ok = false
            }
            if not ok and not bad {
                error(s, "non-declarative statement occurs in block scope, where it will never be executed. Move it to a subroutine instead.")
                bad = true
            }
            statement(s, L_BLOCK)
            prev = s
            s = s.next
        }
    }

    uword nesting = 0           ; statement lists entered inside the current subroutine

    sub statements(^^ast.Node s) {
        nesting++
        while s != 0 {
            statement(s, L_SUB)
            s = s.next
        }
        nesting--
    }

    sub loop_body(^^ast.Node s) {
        loop_depth++
        statements(s)
        loop_depth--
    }

    ; the words of the language (upstream: every lower case word of its grammar)
    str[] reserved_words = ["alias", "and", "as", "asmsub", "bool", "break", "byte", "call", "clobbers", "const", "continue",
        "defer", "do", "downto", "else", "enum", "extsub", "false", "float", "for", "goto", "if", "if_cc", "if_cs", "if_eq",
        "if_mi", "if_ne", "if_neg", "if_nz", "if_pl", "if_pos", "if_vc", "if_vs", "if_z", "in", "inline", "long", "not", "on",
        "or", "pointer", "private", "public", "quad", "repeat", "return", "sizeof", "step", "str", "struct", "sub", "swap",
        "then", "to", "true", "ubyte", "union", "unroll", "until", "uquad", "uword", "via", "void", "when", "while", "word", "xor"]

    ; (the grammar lets a few of them be names; upstream then takes those as the name of an
    ; alias, an enum or a field, and not as the name of a struct or a block)
    str[] name_words = ["on", "call", "inline", "private", "step"]

    sub keyword_name(^^ast.Node at, ^^ubyte name, str message) {
        if name != 0 and name_in(name, &reserved_words, len(reserved_words)) {
            bool strict = message[0] == 'b' or (message[0] == 's' and message[7] == 'n')    ; "block name", "struct name"
            if strict or not name_in(name, &name_words, len(name_words))
                error(at, message)
        }
    }

    sub statement(^^ast.Node n, ubyte level) {
        when n.kind {
            ast.N_ALIAS -> keyword_name(n, n.name, "alias name cannot be a keyword")
            ast.N_ENUM -> {
                keyword_name(n, n.name, "enum name cannot be a keyword")
                if n.a == 0
                    error(n, "enumeration must contain at least one member")
                enum_members(n)
            }
            ast.N_DIRECTIVE -> directive(n, level)
            ast.N_VARDECL -> vardecl(n)
            ast.N_SUB -> {
                if level == L_SUB and nesting > 1
                    error(n, "subroutines can only be defined in the scope of a block or within another subroutine")
                ^^symtab.Sym fsub = n.extra
                if for_6502() and fsub != 0 and (fsub.marks & 1) != 0 and not floats_enabled() {
                    ; (a subroutine that is used)
                    ^^ast.Node fq = n.a
                    while fq != 0 {
                        if fq.a != 0 and fq.a.type == types.T_FLOAT {
                            error(fq, "floating point used, but that is not enabled via options")
                            break
                        }
                        fq = fq.next
                    }
                }
                ; a virtual register for two parameters
                ^^ast.Node rp = n.a
                bool rtwice = false
                while rp != 0 {
                    if rp.b != 0 and rp.b.name != 0 {
                        ^^ast.Node ro = n.a
                        while ro != rp {
                            if ro.b != 0 and ro.b.name != 0 and strings.compare_nocase(ro.b.name, rp.b.name) == 0
                                rtwice = true
                            ro = ro.next
                        }
                    }
                    rp = rp.next
                }
                if rtwice
                    error(n, "a register is used multiple times in the parameters")
                sub_decl(n)
            }
            ast.N_ASMSUB, ast.N_EXTSUB -> {
                check_name(n, n.name)
                params(n.a)
                return_types(n.b)
                register_params(n.a)
                register_returns(n)
                if n.kind == ast.N_ASMSUB {
                    asm_members(n)
                    if (n.flags & ast.F_INLINE) == 0 and not asm_returns(n)
                        error(n, "asmsub seems to never return as it doesn't end with rts/jmp/branch. If this is intended, add a '; !notreached!' comment at the end")
                }
                else {
                    if (n.flags & ast.F_INLINE) != 0
                        error(n, "extsub can never be inline")
                    bank_selector(n)
                    if n.c != 0 and n.c.kind == ast.N_IDENT and n.c.extra != 0 {
                        ^^symtab.Sym xa = n.c.extra
                        if xa.kind == symtab.K_VAR or xa.kind == symtab.K_MEMVAR
                            error(n, "address must be a constant")
                    }
                    if n.c == 0 and not llvm_target {
                        begin_message("address-free extsub (external C routine) is not supported on target ")
                        buf.add_str(parser.scratch, target_name)
                        error_scratch(n)
                    }
                }
            }
            ast.N_STRUCT, ast.N_UNION -> struct_decl(n)
            ast.N_LABEL -> check_name(n, n.name)
            ast.N_ASSIGN -> assignment(n)
            ast.N_AUGASSIGN -> {
                target(n.a, true)
                expression(n.b)
                uword at = n.a.type
                uword vt = n.b.type
                if at == types.T_BOOL and vt != 0 and vt != types.T_BOOL {
                    begin_message("left and right operands aren't the same type: bool vs ")
                    types.name_into(parser.scratch, vt)
                    error_scratch(n)
                }
                else if at != 0 and types.is_pointer(at) and n.op != token.T_PLUSEQ and n.op != token.T_MINUSEQ
                    error(n, "pointer arithmetic only supported for + and - operators, maybe cast to uword?")
                else if at == types.T_FLOAT and (n.op == token.T_SHLEQ or n.op == token.T_SHREQ)
                    error(n, "right operand of bit shift must be an integer")
            }
            ast.N_INCDEC -> target(n.a, true)
            ast.N_CALLSTMT -> {
                expression(n.a)
                inline_shape(n.a)
            }
            ast.N_IF -> {
                expression(n.a)
                statements(n.b)
                statements(n.c)
            }
            ast.N_BRANCH -> {
                statements(n.b)
                statements(n.c)
            }
            ast.N_RETURN -> expressions(n.a)
            ast.N_FOR -> forloop(n)
            ast.N_WHILE -> {
                expression(n.a)
                loop_body(n.b)
            }
            ast.N_UNTIL -> {
                loop_body(n.a)
                expression(n.b)
            }
            ast.N_REPEAT -> {
                expression(n.a)
                loop_body(n.b)
            }
            ast.N_UNROLL -> unroll_check(n)
            ast.N_WHEN -> whenstmt(n)
            ast.N_BREAK -> {
                if loop_depth == 0
                    error(n, "break in wrong scope")
            }
            ast.N_CONTINUE -> {
                if loop_depth == 0
                    error(n, "continue in wrong scope")
            }
            ast.N_GOTO -> goto_check(n)
            ast.N_DEFER -> {
                if leaves(n.a)
                    error(n, "defer cannot contain jumps or returns")
                statements(n.a)
            }
            ast.N_ASM -> native_asm(n)
            ast.N_SWAP -> {
                target(n.a, false)
                target(n.b, false)
            }
            ast.N_ONGOTO -> {
                expression(n.a)
                if n.a != 0 and n.a.type != 0 and n.a.type != types.T_UBYTE
                    error(n.a, "on..goto index must be an unsigned byte")
                ^^ast.Node og = n.b
                while og != 0 {
                    if og.kind == ast.N_IDENT and og.extra != 0 {
                        ^^symtab.Sym ogs = og.extra
                        if ogs.kind == symtab.K_SUB and ogs.decl != 0 and ogs.decl.kind == ast.N_SUB and ogs.decl.a != 0 {
                            begin_message("can't dispatch to a subroutine that takes parameters: ")
                            buf.add_str(parser.scratch, ogs.name)
                            error_scratch(n)
                            break
                        }
                    }
                    og = og.next
                }
                statements(n.c)
            }
        }
    }

    ; ---- names ----

    ; identifiers cannot start with an underscore, in any part of a dotted name
    ; %asm on a target without an assembler
    sub native_asm(^^ast.Node n) {
        if llvm_target and n.name != 0 and strings.compare(n.name, "asm") == 0
            error(n, "%asm with native assembly code can't be used on the llvm targets, use %ir instead")
        else if target_name != 0 and strings.compare(target_name, "virtual") == 0 and n.name != 0 and strings.compare(n.name, "asm") == 0
            error(n, "%asm blocks with native assembly code cannot be executed by the virtual machine, use %ir {{ ... }} instead")
        else if for_6502() and n.name != 0 and strings.compare(n.name, "ir") == 0
            error(n, "%asm containing IR code cannot be translated to 6502 assembly")
    }

    ; is there a return or a jump in these statements (not in nested subroutines)
    sub leaves(^^ast.Node n) -> bool {
        while n != 0 {
            when n.kind {
                ast.N_RETURN, ast.N_GOTO, ast.N_ONGOTO -> return true
                ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB -> {
                }
                ast.N_IF, ast.N_BRANCH, ast.N_FOR -> {
                    if leaves(n.b) or leaves(n.c)
                        return true
                }
                ast.N_WHILE, ast.N_REPEAT, ast.N_UNROLL -> {
                    if leaves(n.b)
                        return true
                }
                ast.N_UNTIL, ast.N_DEFER -> {
                    if leaves(n.a)
                        return true
                }
                ast.N_WHEN -> {
                    ^^ast.Node c = n.b
                    while c != 0 {
                        if leaves(c.b)
                            return true
                        c = c.next
                    }
                }
            }
            n = n.next
        }
        return false
    }

    sub check_name(^^ast.Node at, ^^ubyte name) {
        if name == 0
            return
        if name[0] == '_' {
            error(at, "identifiers cannot start with an underscore")
            return
        }
        long i = 1
        while name[i] != 0 {
            if name[i] == '_' and name[i - 1] == '.' {
                error(at, "identifiers cannot start with an underscore")
                return
            }
            i++
        }
    }

    ; ---- declarations ----

    sub vardecl(^^ast.Node n) {
        ^^symtab.Sym s = n.c.extra
        if s == 0
            return
        uword t = s.type
        ^^ast.Node init = n.b
        bool ok
        quad v
        bool is_tuple = false
        if init != 0 and init.kind == ast.N_TUPLE
            is_tuple = true
        checks++
        if for_6502() and t != 0 and not floats_enabled() and n.op != token.T_KW_CONST
                and types.is_array(t) and types.elem_of(t) == types.T_FLOAT
            error(n, "floating point used, but that is not enabled via options")
        if init != 0 and not is_tuple {
            float_results(init)
            value_shape(n, init, t)
            if init.kind == ast.N_CALL and init.a != 0 and init.a.extra != 0 {
                ; as many names as the call has values
                ^^symtab.Sym callee = init.a.extra
                if callee.kind == symtab.K_SUB {
                    long given = ast.list_length(typer.returns_of(callee))
                    long wanted = ast.list_length(n.c)
                    if given > wanted and given > 1 {
                        begin_message("call returns too many values: expected ")
                        buf.add_long(parser.scratch, wanted)
                        buf.add_str(parser.scratch, " got ")
                        buf.add_long(parser.scratch, given)
                        buf.add_str(parser.scratch, ", missing assignments for: ")
                        ^^ast.Node rt = typer.returns_of(callee)
                        long rn = 0
                        while rt != 0 {
                            if rn >= wanted {
                                if rn > wanted
                                    buf.add_str(parser.scratch, ", ")
                                types.name_into(parser.scratch, typer.return_type(rt))
                            }
                            rn++
                            rt = rt.next
                        }
                        error_scratch(init)
                    }
                    else if given < wanted and wanted > 1 and given > 0 {
                        begin_message("call returns too few values: expected ")
                        buf.add_long(parser.scratch, wanted)
                        buf.add_str(parser.scratch, " got ")
                        buf.add_long(parser.scratch, given)
                        error_scratch(init)
                    }
                }
            }
        }
        if init != 0 and init.kind == ast.N_ARRAYLIT and t != 0 and types.is_array(t) {
            uword aelem = types.elem_of(t)
            ^^ast.Node ae = init.a
            while ae != 0 {
                if ae.kind == ast.N_STRUCTINIT {
                    if types.is_struct(aelem) and (ae.flags & ast.F_POINTER) != 0
                        error(ae, "struct instance array must be initialized with struct values, not pointer initializers: use 'Type : [...]' without '^^' or inferred '[...]' instead of '^^Type : [...]'")
                    else if types.is_pointer(aelem) and types.is_struct(types.elem_of(aelem)) and ae.type != 0 and types.is_pointer(ae.type) and ae.type != aelem {
                        error(init, "initialization value for pointer array must be a word array")
                        break
                    }
                }
                ae = ae.next
            }
        }
        ^^ast.Node bn = n.c
        while bn != 0 {
            if bn.name != 0 and strings.compare(bn.name, "pointer") == 0 {
                error(n, "variable name cannot be a keyword")
                break
            }
            if bn.name != 0 and symtab.builtins != 0 and symtab.find_in(symtab.builtins, bn.name) != 0 {
                error(n, "builtin function cannot be redefined")
                break
            }
            bn = bn.next
        }
        if (has_tag(n, strtab.intern_cstr("alignword")) or has_tag(n, strtab.intern_cstr("align64")) or has_tag(n, strtab.intern_cstr("alignpage")))
                and (has_tag(n, strtab.intern_cstr("zp")) or has_tag(n, strtab.intern_cstr("requirezp")))
            error(n, "zeropage variables can't have alignment")
        declaration_tags(n, t)
        if init != 0 and not is_tuple
            struct_values(n, t, init)
        if no_quads and t != 0 {
            uword qt = t
            if types.is_array(qt) or types.is_pointer(qt)
                qt = types.elem_of(qt)
            if qt == types.T_QUAD or qt == types.T_UQUAD {
                begin_message("64-bit integer types (quad/uquad) are not supported on target ")
                buf.add_str(parser.scratch, target_name)
                error_scratch(n)
                return
            }
        }
        if no_floats and t != 0 {
            uword ft = t
            if types.is_array(ft) or types.is_pointer(ft)
                ft = types.elem_of(ft)
            if ft == types.T_FLOAT {
                error(n, "floats are not supported yet on the llvm16 target")
                return
            }
        }
        if types.is_pointer(t) and types.elem_of(t) == types.T_STR
            error(n, "^^str is not a valid pointer type, use ^^ubyte?")
        if init != 0 and references(init, s)
            error(n, "recursive var declaration")
        if n.op == token.T_KW_CONST {
            if t == types.T_STR
                error(n, "strings cannot be made const they are always potentially mutable")
            else if t != 0 and not types.is_numeric_or_bool(t) and not types.is_pointer(t)
                error(n, "const can only be used on numbers, booleans and pointers")
            else if t != 0 and types.is_pointer(t) and types.size_of(types.elem_of(t)) > 1
                error(n, "due to internal compiler complexity, currently pointer variables with data type size > 1 cannot be const")
            else if init != 0 and not is_tuple and t != types.T_FLOAT {
                ok, v = typer.constlike_eval(init)
                ; (an address that the assembler knows is constant as well: a block of
                ; memory() or a string; not &variable, which upstream does not take either)
                bool address = init.kind == ast.N_STR
                    or (init.kind == ast.N_CALL and init.a != 0 and init.a.kind == ast.N_IDENT and init.a.name != 0 and strings.compare(init.a.name, "memory") == 0)
                if not ok and not address
                    error(init, "const declaration needs a compile-time constant initializer value")
            }
        }
        else if n.op == token.T_AMP {
            if t == types.T_STR
                error(n, "strings cannot be memory-mapped")
            else if types.is_struct(t)
                error(n, "struct instances cannot be declared as memory-mapped currently, use a pointer and memory allocation call or direct address assignment instead")
            else if types.is_array(t) and types.is_pointer(types.elem_of(t))
                error(n, "pointer arrays cannot be memory-mapped (codegen limitation)")
            if init != 0 and not is_tuple {
                ok, v = typer.const_eval(init)
                if not ok
                    error(init, "value of memory mapped variable can only be a constant number, maybe use an address pointer type instead?")
                else if v < 0 or v > max_data_address()
                    error(init, "memory address must be valid integer for the target")
            }
            ^^types.Type mt = types.get(t)
            if types.is_array(t) and mt.length == 0
                error(n, "memory mapped array must have a size specification")
        }
        else {
            if t == types.T_STR {
                if init == 0
                    error(n, "string var must be initialized with a string literal")
                else if not is_tuple and not literal_string(init)
                    error(n, "string var must be initialized with a string literal")
            }
            else if types.is_array(t)
                array_decl(n, t)
            else if types.is_struct(t)
                error(n, "struct instances cannot be declared directly, use a pointer and memory allocation call or direct address assignment instead")
            if has_tag(n, dirty_name) {
                if t == types.T_STR
                    error(n, "string variables cannot be @dirty")
                if init != 0
                    error(n, "dirty variable can't have initialization value")
            }
        }
        if init != 0
            expression(init)
    }

    ; The tags upstream knows, and what each may stand on; several names in one
    ; declaration are for numbers, booleans, pointers and structs.
    sub declaration_tags(^^ast.Node n, uword t) {
        bool aligned = false
        bool nosplit = false
        ^^ast.Node tag = n.d
        while tag != 0 {
            if tag.kind == ast.N_TAG and tag.name != 0 {
                if strings.compare(tag.name, "alignword") == 0 or strings.compare(tag.name, "align64") == 0 or strings.compare(tag.name, "alignpage") == 0
                    aligned = true
                else if strings.compare(tag.name, "nosplit") == 0
                    nosplit = true
                else if strings.compare(tag.name, "zp") != 0 and strings.compare(tag.name, "requirezp") != 0 and strings.compare(tag.name, "nozp") != 0
                        and strings.compare(tag.name, "shared") != 0 and strings.compare(tag.name, "dirty") != 0 {
                    begin_message("Syntax error: invalid variable tag '@")
                    buf.add_str(parser.scratch, tag.name)
                    buf.add_byte(parser.scratch, 39)
                    error_scratch(n)
                }
            }
            tag = tag.next
        }
        if t == 0
            return
        if aligned and not types.is_array(t) and t != types.T_STR
            error(n, "only string and array variables can have an alignment option")
        if nosplit {
            uword ne = 0
            if types.is_array(t)
                ne = types.elem_of(t)
            ; (words and pointers; where a pointer is a long, an array of longs)
            if ne == 0 or not (ne == types.T_UWORD or ne == types.T_WORD or ne == types.T_STR or types.is_pointer(ne) or types.is_address(ne)
                    or (ne == types.T_LONG and types.POINTER_SIZE != 2))
                error(n, "@nosplit is for word or pointer arrays only")
        }
        if n.c != 0 and n.c.next != 0 and (types.is_array(t) or t == types.T_STR)
            error(n, "cannot multi declare variables of this type")
        if n.op == token.T_AMP and for_6502() and types.is_array(t) and not nosplit {
            uword me = types.elem_of(t)
            if me == types.T_UWORD or me == types.T_WORD or types.is_pointer(me) or types.is_address(me)
                error(n, "memory mapped word arrays cannot be split, should have @nosplit")
        }
        if types.is_array(t) and n.b != 0 and n.b.kind == ast.N_RANGE and n.a != 0 and n.a.a != 0 {
            ; a range fills an array of its own size
            long rl = typer.range_length(n.b)
            ^^types.Type rat = types.get(t)
            if rl > 0 and rat.length > 0 and rl != rat.length {
                begin_message("range expression size (")
                buf.add_long(parser.scratch, rl)
                buf.add_str(parser.scratch, ") doesn't match declared array size (")
                buf.add_long(parser.scratch, rat.length)
                buf.add_byte(parser.scratch, ')')
                error_scratch(n.b)
            }
        }
    }

    ; a call of a subroutine with several values
    sub several_values(^^ast.Node e) -> bool {
        if e == 0 or e.kind != ast.N_CALL or e.a == 0 or e.a.kind != ast.N_IDENT or e.a.extra == 0
            return false
        ^^symtab.Sym cs = e.a.extra
        return cs.kind == symtab.K_SUB and ast.list_length(typer.returns_of(cs)) > 1
    }

    ; What cannot be the value that goes into a variable of this type: an operator on a
    ; call with several values; the bare name of an array (its address is &name).
    sub value_shape(^^ast.Node at, ^^ast.Node value, uword tt) {
        if value.kind == ast.N_BINARY and (several_values(value.a) or several_values(value.b)) {
            error(value, "invalid assignment value")
            return
        }
        if value.kind == ast.N_IDENT and value.type != 0 and types.is_array(value.type) and tt != 0 and not types.is_array(tt) and tt != types.T_STR {
            if tt == types.T_UWORD or tt == types.ADDRESS_TYPE
                error(value, "invalid assignment value")
            else if types.is_pointer(tt) or tt == types.T_LONG
                error(value, "cannot assign array")
        }
    }

    ; is there a sizeof(str) in the expression (of an %assert, which nothing else looks at)
    sub sizeof_of_str(^^ast.Node e) -> bool {
        if e == 0
            return false
        if e.kind == ast.N_SIZEOF
            return e.op != 1 and e.a != 0 and e.a.kind == ast.N_TYPE and e.a.op == token.T_KW_STR and (e.a.flags & ast.F_POINTER) == 0 and e.a.a == 0
        if e.kind == ast.N_BINARY
            return sizeof_of_str(e.a) or sizeof_of_str(e.b)
        if e.kind == ast.N_UNARY
            return sizeof_of_str(e.a)
        return false
    }

    sub has_tag(^^ast.Node n, ^^ubyte tagname) -> bool {
        ^^ast.Node tag = n.d
        while tag != 0 {
            if tag.name == tagname
                return true
            tag = tag.next
        }
        return false
    }

    ; a string literal, or literals joined with + or repeated with *
    sub literal_string(^^ast.Node e) -> bool {
        if e.kind == ast.N_STR
            return true
        if e.kind != ast.N_BINARY
            return false
        if e.op == token.T_PLUS
            return literal_string(e.a) and literal_string(e.b)
        if e.op == token.T_STAR {
            bool ok
            quad v
            ok, v = typer.const_eval(e.b)
            return literal_string(e.a) and ok
        }
        return false
    }

    ; [a, b, c] for a struct: a value for every field or for none
    sub struct_values(^^ast.Node at, uword target_type, ^^ast.Node value) {
        if value == 0 or (value.kind != ast.N_ARRAYLIT and value.kind != ast.N_STRUCTINIT)
            return
        if not types.is_pointer(target_type) or not types.is_struct(types.elem_of(target_type))
            return
        ^^types.Type st = types.get(types.elem_of(target_type))
        ^^symtab.Sym ss = st.strct
        if ss == 0 or ss.inner == 0
            return
        long fields = 0
        ^^symtab.Sym f = ss.inner.syms
        ^^ast.Node v = value.a
        bool mismatch = false
        if ss.decl != 0 and ss.decl.kind == ast.N_UNION and v != 0 {
            ; a union's members share their bytes: no list of values for them
            if v.kind == ast.N_NAMEDFIELD
                error(at, "named-field initialization is not supported for unions")
            else
                error(at, "union cannot be statically initialized with values, use [] for zero initialization")
            return
        }
        if v != 0 and v.kind == ast.N_NAMEDFIELD {
            ; by name: every name is a field, and is there once
            ^^ast.Node nf = v
            while nf != 0 {
                if nf.kind == ast.N_NAMEDFIELD and nf.name != 0 {
                    ^^symtab.Sym known = ss.inner.syms
                    while known != 0 and not (known.kind == symtab.K_FIELD and strings.compare(known.name, nf.name) == 0)
                        known = known.next
                    if known == 0 {
                        begin_message("unknown field name '")
                        buf.add_str(parser.scratch, nf.name)
                        buf.add_str(parser.scratch, "' in struct initializer")
                        error_scratch(at)
                        return
                    }
                    ^^ast.Node before = v
                    while before != nf {
                        if before.name != 0 and strings.compare(before.name, nf.name) == 0 {
                            begin_message("duplicate field name '")
                            buf.add_str(parser.scratch, nf.name)
                            buf.add_str(parser.scratch, "' in struct initializer")
                            error_scratch(at)
                            return
                        }
                        before = before.next
                    }
                }
                nf = nf.next
            }
        }
        while f != 0 {
            if f.kind == symtab.K_FIELD {
                fields++
                if v != 0 {
                    ; a string for a number field
                    ; (a field that holds an address takes a string: a str, a pointer, a word)
                    if v.kind == ast.N_STR and (f.type == types.T_UBYTE or f.type == types.T_BYTE or f.type == types.T_BOOL or f.type == types.T_FLOAT)
                        mismatch = true
                    v = v.next
                }
            }
            f = f.next
        }
        long given = ast.list_length(value.a)
        ; (by name, any of the fields may be given: the others are 0)
        bool named = value.a != 0 and value.a.kind == ast.N_NAMEDFIELD
        if named
            mismatch = false
        if given != 0 and given != fields and not (named and given < fields) {
            begin_message("invalid number of arguments: expected ")
            buf.add_long(parser.scratch, fields)
            buf.add_str(parser.scratch, " or 0 but got ")
            buf.add_long(parser.scratch, given)
            error_scratch(at)
        }
        else if mismatch
            error(at, "initialization value contains non-constant elements")
    }

    ; the number of arguments of the builtin functions that take a fixed number
    str[] fixed_builtins = ["abs", "sgn", "sqrt", "len", "lsb", "msb", "lsw", "msw", "mkword", "mklong2", "min", "max", "clamp",
        "peek", "peekw", "peekl", "peekf", "peekbool", "poke", "pokew", "pokel", "pokef", "pokebool", "setlsb", "setmsb",
        "callfar", "callfar2"]
    ubyte[] fixed_counts = [1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3,
        1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2,
        3, 6]

    sub builtin_call(^^ast.Node e, ^^symtab.Sym called) {
        ubyte i
        for i in 0 to len(fixed_builtins) - 1 {
            if strings.compare(called.name, fixed_builtins[i]) == 0 {
                long given = ast.list_length(e.b)
                if given != fixed_counts[i] {
                    begin_message("invalid number of arguments: expected ")
                    buf.add_long(parser.scratch, fixed_counts[i])
                    buf.add_str(parser.scratch, " but got ")
                    buf.add_long(parser.scratch, given)
                    error_scratch(e)
                    return
                }
                if e.b != 0 and e.b.type != 0 {
                    uword at = e.b.type
                    if i <= 2 or (i >= 10 and i <= 12) {
                        ; the arithmetic ones
                        if at == types.T_STR or types.is_array(at) or at == types.T_BOOL
                            error(e, "expected numeric argument")
                        else if i >= 10 {
                            ; min, max and clamp have no float form: the library has
                            ^^ast.Node arg = e.b
                            while arg != 0 {
                                if arg.type == types.T_FLOAT {
                                    if i == 12
                                        error(e, "clamp builtin not supported for floats, use floats.clamp")
                                    else
                                        error(e, "min/max not supported for floats, use floats.minf/maxf instead")
                                    break
                                }
                                arg = arg.next
                            }
                        }
                    }
                    else if i >= 13 and i <= 22 {
                        ; (a long is no address where addresses are words: it would be cut to 16 bits)
                        if at == types.T_FLOAT or at == types.T_BOOL or (types.POINTER_SIZE == 2 and at == types.T_LONG and types.far_bits == 0)
                            error(e, "invalid address type for memory access")
                    }
                }
                return
            }
        }
    }

    ; the size rules of an array variable (not memory mapped)
    sub array_decl(^^ast.Node n, uword t) {
        ; a plain variable as an element is not a constant
        if n.b != 0 and n.b.kind == ast.N_ARRAYLIT {
            ^^ast.Node el = n.b.a
            while el != 0 {
                if el.kind == ast.N_IDENT and el.extra != 0 {
                    ^^symtab.Sym es = el.extra
                    bool eok
                    quad ev
                    eok, ev = typer.constlike_eval(el)
                    if not eok and (es.kind == symtab.K_VAR or es.kind == symtab.K_PARAM) and es.type != 0 and not types.is_array(es.type) and es.type != types.T_STR {
                        error(n.b, "initialization value contains non-constant elements")
                        break
                    }
                }
                el = el.next
            }
        }
        ^^ast.Node init = n.b
        ^^types.Type at = types.get(t)
        long length = at.length
        bool ok
        quad v
        long literal_length = -1
        if init != 0 {
            if init.kind == ast.N_RANGE {
                long rl = typer.range_length(init)
                if rl > 0 and length == 0
                    length = rl
            }
            else if init.kind == ast.N_ARRAYLIT
                literal_length = ast.list_length(init.a)
            else if init.kind == ast.N_BINARY and init.op == token.T_STAR and init.a.kind == ast.N_ARRAYLIT {
                ; [value] * count
                if init.type != 0 and types.is_array(init.type) {
                    ^^types.Type lt = types.get(init.type)
                    literal_length = lt.length
                }
            }
            else if init.kind != ast.N_STR {
                error(init, "array initialization value must be a range value or an array literal")
                return
            }
            if literal_length >= 0 and n.a.a != 0 {
                ; a declared size and a literal: they must agree
                ok, v = typer.const_eval(n.a.a)
                if ok and n.a.a.next != 0 {
                    ; two dimensions: the literal lists all elements, row by row
                    bool ok2
                    quad columns
                    ok2, columns = typer.const_eval(n.a.a.next)
                    ok = ok2
                    v *= columns
                }
                if ok and v != literal_length {
                    begin_message("array size mismatch (expecting ")
                    buf.add_quad(parser.scratch, v)
                    buf.add_str(parser.scratch, ", got ")
                    buf.add_long(parser.scratch, literal_length)
                    buf.add_str(parser.scratch, ")")
                    error_scratch(init)
                }
            }
        }
        else if n.a.a == 0 {
            error(n, "array variable is missing a size specification")
            return
        }
        if length == 0 {
            if n.a.a != 0 {
                ok, v = typer.const_eval(n.a.a)
                if not ok {
                    error(n, "array size specifier must be constant integer value")
                    return
                }
                length = v as long
            }
            else {
                error(n, "array length must be known at compile-time")
                return
            }
        }
        uword elem = at.elem
        long elemsize = types.size_of(elem)
        long limit = array_limit
        if elemsize == 1 {
            if length < 1 or length > limit {
                begin_message("string and byte array length must be 1-")
                buf.add_long(parser.scratch, limit)
                error_scratch(n)
            }
        }
        else if elemsize == 2 and not types.is_struct(elem) {
            if for_6502() and has_tag(n, strtab.intern_cstr("nosplit")) {
                if length < 1 or length > limit / 2 {
                    begin_message("regular word array length must be 1-")
                    buf.add_long(parser.scratch, limit / 2)
                    buf.add_str(parser.scratch, ", use split array to get to ")
                    buf.add_long(parser.scratch, limit)
                    error_scratch(n)
                }
            }
            else if length < 1 or length > limit {
                begin_message("split word array length must be 1-")
                buf.add_long(parser.scratch, limit)
                error_scratch(n)
            }
        }
        else if elem == types.T_FLOAT {
            limit = array_limit / types.FLOAT_SIZE
            if length < 1 or length > limit {
                begin_message("float array length must be 1-")
                buf.add_long(parser.scratch, limit)
                error_scratch(n)
            }
        }
        else if elemsize == 4 and types.POINTER_SIZE == 2 {
            limit = array_limit / 4
            if length < 1 or length > limit {
                begin_message("long array length must be 1-")
                buf.add_long(parser.scratch, limit)
                error_scratch(n)
            }
        }
        else if elemsize != 0 {
            if length < 1 or length * elemsize > limit {
                begin_message("array size ")
                buf.add_long(parser.scratch, length * elemsize)
                buf.add_str(parser.scratch, " exceeds target limit ")
                buf.add_long(parser.scratch, limit)
                buf.add_str(parser.scratch, " bytes")
                error_scratch(n)
            }
        }
    }

    ; The number of values of a range with constant bounds, or 0.
    ; Does the expression refer to the symbol?
    sub references(^^ast.Node e, ^^symtab.Sym s) -> bool {
        if e == 0
            return false
        if e.kind == ast.N_IDENT and e.extra == s
            return true
        if e.kind == ast.N_TYPE
            return false
        if references(e.a, s) or references(e.b, s)
            return true
        if references(e.c, s)
            return true
        ; the next elements of a list
        return references(e.next, s)
    }

    ; An inline subroutine that is called as a statement is one statement, or one and an
    ; empty return: upstream copies that statement to where the call is.
    ^^ast.Node inline_reported = 0

    sub inline_shape(^^ast.Node cnode) {
        if cnode == 0 or cnode.kind != ast.N_CALL or cnode.a == 0 or cnode.a.kind != ast.N_IDENT or cnode.a.extra == 0
            return
        ^^symtab.Sym cs = cnode.a.extra
        if cs.kind != symtab.K_SUB or cs.decl == 0 or cs.decl.kind != ast.N_SUB or (cs.decl.flags & ast.F_INLINE) == 0
            return
        long count = 0
        ^^ast.Node last = 0
        ^^ast.Node st = cs.decl.c
        while st != 0 {
            if st.kind != ast.N_REMOVED {
                count++
                last = st
            }
            st = st.next
        }
        if count == 1 or (count == 2 and last.kind == ast.N_RETURN and last.a == 0)
            return
        if inline_reported == cs.decl
            return
        inline_reported = cs.decl
        begin_message("inline subroutine '")
        buf.add_str(parser.scratch, cs.name)
        buf.add_str(parser.scratch, "' must contain only one body statement, optionally followed by an empty return, otherwise it cannot be inlined")
        error_scratch(cs.decl)
    }

    ; is the program for a 6502 machine?  (Not the virtual machine, not a hosted or 68000 target.)
    sub for_6502() -> bool {
        return types.POINTER_SIZE == 2 and target_name != 0 and strings.compare(target_name, "virtual") != 0
    }

    ; Does an asmsub's assembly end by leaving it?  Upstream's rule: the last line of its
    ; last %asm that is not blank or a comment has rts, rti, rte, jmp or bra in it as a
    ; word (return, returnr, returni, jump, jumpi in %ir), or is a comment with
    ; !notreached! in it.  An included file is taken on trust.
    sub asm_returns(^^ast.Node n) -> bool {
        ^^ubyte text = 0
        long stop = 0
        bool is_ir = false
        ^^ast.Node b = n.c
        while b != 0 {
            if b.kind == ast.N_DIRECTIVE and b.name != 0 and strings.compare(b.name, "asmbinary") == 0
                return true
            if b.kind == ast.N_DIRECTIVE and b.name != 0 and strings.compare(b.name, "asminclude") == 0 and b.a != 0 and b.a.kind == ast.N_STR and b.a.name != 0 {
                ; the included text counts like assembly written here (a library's file is
                ; taken on trust); one that cannot be read is no return
                if buf.bytes_equal(b.a.name, "library:", 8)
                    return true
                ^^source.File from = source.get(b.file)
                ^^buf.Buf ipath = buf.new(256)
                long slash = buf.cstr_len(from.name)
                while slash > 0 and from.name[slash - 1] != '/'
                    slash--
                buf.add_bytes(ipath, from.name, slash)
                buf.add_str(ipath, b.a.name)
                buf.add_byte(ipath, 0)
                ^^source.File inc = source.load(ipath.data)
                if inc == 0
                    inc = source.load(b.a.name)
                text = 0
                is_ir = false
                if inc != 0 {
                    text = inc.text
                    stop = inc.len
                }
            }
            if b.kind == ast.N_ASM {
                text = b.extra
                stop = b.value as long
                is_ir = b.name != 0 and strings.compare(b.name, "ir") == 0
            }
            b = b.next
        }
        if text == 0
            return false
        ; the lines from the end
        while stop > 0 {
            long start = stop
            while start > 0 and text[start - 1] != '\n'
                start--
            long first = start
            while first < stop and (text[first] == ' ' or text[first] == '\t' or text[first] == '\r')
                first++
            if first < stop {
                bool comment = text[first] == ';'
                if has_word(text, first, stop, "!notreached!")
                    return true
                if not comment {
                    if is_ir
                        return has_word(text, first, stop, "return") or has_word(text, first, stop, "returnr") or has_word(text, first, stop, "returni")
                            or has_word(text, first, stop, "jump") or has_word(text, first, stop, "jumpi")
                    return has_word(text, first, stop, "rts") or has_word(text, first, stop, "jmp") or has_word(text, first, stop, "bra")
                        or has_word(text, first, stop, "rti") or has_word(text, first, stop, "rte")
                }
            }
            if start == 0
                break
            stop = start - 1
        }
        return false
    }

    ; is the word in text[first..stop), at the start or after a blank, and not followed by a
    ; letter, digit or underscore?  (Letters compare without case; "!notreached!" anywhere.)
    sub has_word(^^ubyte text, long first, long stop, ^^ubyte wanted) -> bool {
        long wl = buf.cstr_len(wanted)
        long i = first
        while i + wl <= stop {
            if i == first or text[i - 1] == ' ' or text[i - 1] == '\t' or wanted[0] == '!' {
                long k = 0
                while k < wl and (text[i + k] | $20) == (wanted[k] | $20)
                    k++
                if k == wl {
                    if wanted[0] == '!' or i + wl == stop
                        return true
                    ubyte after = text[i + wl]
                    if not ((after >= 'a' and after <= 'z') or (after >= 'A' and after <= 'Z') or (after >= '0' and after <= '9') or after == '_')
                        return true
                }
            }
            i++
        }
        return false
    }

    ; An array of words is two arrays of bytes on the 6502 unless it is @nosplit: its
    ; address is not that of words, which a pointer to words would read.
    sub split_arguments(^^ast.Node e, ^^symtab.Sym called) {
        ^^ast.Node p = called.decl.a
        ^^ast.Node arg = e.b
        long number = 1
        while p != 0 and arg != 0 {
            ^^symtab.Sym ps = p.extra
            if ps != 0 and ps.type != 0 and types.is_pointer(ps.type) and (types.elem_of(ps.type) == types.T_UWORD or types.elem_of(ps.type) == types.T_WORD)
                    and arg.kind == ast.N_IDENT and arg.extra != 0 and arg.type != 0 and types.is_array(arg.type)
                    and (types.elem_of(arg.type) == types.T_UWORD or types.elem_of(arg.type) == types.T_WORD) {
                ^^symtab.Sym vs = arg.extra
                if vs.kind == symtab.K_VAR and vs.decl != 0 and vs.decl.kind == ast.N_VARDECL and not has_tag(vs.decl, strtab.intern_cstr("nosplit")) {
                    begin_message("argument ")
                    buf.add_long(parser.scratch, number)
                    buf.add_str(parser.scratch, " cannot pass address to a split words array where a word pointer argument is expected, use a @nosplit word array instead")
                    error_scratch(arg)
                }
            }
            number++
            p = p.next
            arg = arg.next
        }
    }

    ; the plain name of a long variable
    sub long_var(^^ast.Node v) -> bool {
        if v == 0 or v.kind != ast.N_IDENT or v.extra == 0 or v.type != types.T_LONG
            return false
        ^^symtab.Sym ls = v.extra
        return ls.kind == symtab.K_VAR or ls.kind == symtab.K_PARAM
    }

    sub struct_decl(^^ast.Node s) {
        check_name(s, s.name)
        keyword_name(s, s.name, "struct name cannot be a keyword")
        if s.name != 0 and symtab.builtins != 0 and symtab.find_in(symtab.builtins, s.name) != 0
            error(s, "builtin function cannot be redefined")
        ^^ast.Node kf = s.a
        while kf != 0 {
            ^^ast.Node kn = kf.c
            while kn != 0 {
                keyword_name(kn, kn.name, "struct field name cannot be a keyword")
                kn = kn.next
            }
            kf = kf.next
        }
        if s.a == 0 {
            if s.kind == ast.N_UNION
                error(s, "union must have at least one field")
            else
                error(s, "struct must contain at least one field")
            return
        }
        ; an array field's length is a constant above zero
        kf = s.a
        while kf != 0 {
            if kf.a != 0 and kf.a.kind == ast.N_TYPE and kf.a.a != 0 {
                bool lok
                quad lv
                lok, lv = typer.const_eval(kf.a.a)
                if not lok
                    error(kf, "array length must be known at compile-time")
                else if lv <= 0
                    error(kf, "array length must be positive")
            }
            kf = kf.next
        }
        ; an array field has plain elements
        ^^symtab.Sym asym = s.extra
        if asym != 0 and asym.inner != 0 {
            ^^symtab.Sym af = asym.inner.syms
            while af != 0 {
                if af.kind == symtab.K_FIELD and af.type != 0 and types.is_array(af.type) {
                    uword afe = types.elem_of(af.type)
                    if types.is_struct(afe) {
                        begin_message("arrays of struct instances are currently not supported as struct fields at '")
                        buf.add_str(parser.scratch, af.name)
                        buf.add_byte(parser.scratch, 39)
                        error_scratch(s)
                    }
                    else if types.is_pointer(afe) and afe != types.ADDRESS_TYPE {
                        begin_message("arrays of typed pointers are currently not supported, use untyped pointer for now at field '")
                        buf.add_str(parser.scratch, af.name)
                        buf.add_byte(parser.scratch, 39)
                        error_scratch(s)
                    }
                }
                af = af.next
            }
        }
        ; a field that is a struct itself (not a pointer to one)
        ^^symtab.Sym ss = s.extra
        if ss != 0 and ss.inner != 0 and s.kind == ast.N_STRUCT and for_6502() {
            ; a field is reached with an index register
            long total = 0
            ^^symtab.Sym sf = ss.inner.syms
            while sf != 0 {
                if sf.kind == symtab.K_FIELD and sf.type != 0
                    total += types.size_of(sf.type)
                sf = sf.next
            }
            if total > 256 {
                begin_message("struct contains too many fields, max struct size is 256 bytes (actual: ")
                buf.add_long(parser.scratch, total)
                buf.add_byte(parser.scratch, ')')
                error_scratch(s)
            }
        }
        if ss != 0 and ss.inner != 0 {
            ^^symtab.Sym f = ss.inner.syms
            while f != 0 {
                if f.type != 0 and types.is_struct(f.type) {
                    begin_message("no support for nested structs at '")
                    buf.add_str(parser.scratch, f.name)
                    buf.add_byte(parser.scratch, 39)
                    error_scratch(s)
                }
                f = f.next
            }
        }
        checks++
    }

    ; @bank of an extsub: a number, a ubyte variable, or a subroutine that takes the
    ; call's ID as a ubyte and gives the bank as a ubyte
    sub bank_selector(^^ast.Node n) {
        if n.d == 0 or n.d.kind != ast.N_IDENT or n.d.extra == 0
            return
        ^^symtab.Sym bs = n.d.extra
        if bs.kind == symtab.K_SUB and bs.decl != 0 and bs.decl.kind == ast.N_SUB {
            ^^ast.Node bp = bs.decl.a
            if bp == 0 or bp.next != 0 or bp.a == 0 or bp.a.type != types.T_UBYTE
                error(n, "bank subroutine must have exactly one ubyte parameter (call id)")
            else {
                ^^ast.Node br = bs.decl.b
                if br == 0 or br.next != 0 or typer.return_type(br) != types.T_UBYTE
                    error(n, "bank subroutine must return a single ubyte")
            }
        }
        else if (bs.kind == symtab.K_VAR or bs.kind == symtab.K_MEMVAR) and bs.type != 0 and bs.type != types.T_UBYTE
            error(n, "@bank must be a ubyte variable or a subroutine(ubyte callid) returning ubyte")
    }

    ; Does a module of the program switch floating point on?  (%option enable_floats,
    ; which importing floats brings.)
    ubyte floats_known = 0          ; 0 not looked yet, 1 no, 2 yes

    sub floats_enabled() -> bool {
        if floats_known == 0 {
            floats_known = 1
            ^^ubyte opt = strtab.intern_cstr("enable_floats")
            ^^importer.Module m = importer.modules
            while m != 0 {
                if m.tree != 0 and symtab.has_option(m.tree.a, opt)
                    floats_known = 2
                m = m.next
            }
        }
        return floats_known == 2
    }

    ^^ast.Node float_results_reported = 0

    ; On the 6502 one floating point value comes back from a call (in FAC1).
    sub float_results(^^ast.Node made) {
        if not for_6502() or made == 0 or made.kind != ast.N_CALL or made.a == 0 or made.a.kind != ast.N_IDENT or made.a.extra == 0
            return
        ^^symtab.Sym cs = made.a.extra
        if cs.kind != symtab.K_SUB or cs.decl == 0 or cs.decl.kind != ast.N_SUB or cs.decl == float_results_reported
            return
        ubyte floats = 0
        ^^ast.Node r = cs.decl.b
        while r != 0 {
            if typer.return_type(r) == types.T_FLOAT
                floats++
            r = r.next
        }
        if floats > 1 {
            float_results_reported = cs.decl
            error(cs.decl, "can only have a single float value in a multi-value result on 6502 targets")
        }
    }

    sub params(^^ast.Node p) {
        ^^ast.Node q = p
        while q != 0 {
            check_name(q, q.name)
            ^^ast.Node other = p
            while other != q {
                if other.name == q.name {
                    error(q, "parameter names must be unique")
                    break
                }
                other = other.next
            }
            uword t = q.a.type
            if types.is_struct(t)
                error(q, "structs can only be passed via a pointer")
            else if types.is_array(t)
                error(q, "this pass-by-reference type can't be used as a parameter type.")
            else if types.is_pointer(t) and types.elem_of(t) == types.T_STR
                error(q, "^^str is not a valid pointer type, use ^^ubyte?")
            q = q.next
        }
    }

    ; an asmsub's body: assembly only
    sub asm_members(^^ast.Node n) {
        ^^ast.Node s = n.c
        while s != 0 {
            if s.kind == ast.N_ASM
                native_asm(s)
            else if s.kind != ast.N_DIRECTIVE {
                error(n, "asmsub can only contain inline assembly (%asm), binary blobs (%asmbinary) and assembly includes (%asminclude)")
                return
            }
            s = s.next
        }
    }

    ; the bit of a CPU register letter: A 1, X 2, Y 4; 0 for anything else
    sub cpu_bits(^^ubyte r) -> ubyte {
        ubyte bits = 0
        ubyte k = 0
        while r[k] != 0 {
            when r[k] & $df {
                'A' -> bits |= 1
                'X' -> bits |= 2
                'Y' -> bits |= 4
                else -> return 0
            }
            k++
        }
        if k > 2
            return 0
        return bits
    }

    ; The registers of an asmsub's or extsub's return values: none used twice, none in
    ; the clobber list, each of the size of its value.
    sub register_returns(^^ast.Node n) {
        ubyte used = 0
        bool twice = false
        bool wrong = false
        ubyte index = 0
        ^^ast.Node r = n.b
        while r != 0 {
            index++
            if r.b != 0 and r.b.kind == ast.N_IDENT and r.b.name != 0 and r.op != token.T_KW_VOID {
                ubyte bits = cpu_bits(r.b.name)
                if bits != 0 {
                    if (used & bits) != 0
                        twice = true
                    used |= bits
                    uword t = typer.return_type(r)
                    if t != 0 and not wrong {
                        long size = types.size_of(t)
                        bool pair = bits != 1 and bits != 2 and bits != 4
                        if not pair and size != 1 {
                            begin_message("return type #")
                            buf.add_long(parser.scratch, index)
                            buf.add_str(parser.scratch, " should be (u)byte")
                            error_scratch(n)
                            wrong = true
                        }
                        else if pair and (size != 2 or (types.is_pointer(t) and t != types.ADDRESS_TYPE and types.elem_of(t) != types.T_UBYTE)) and t != types.T_STR {
                            begin_message("return type #")
                            buf.add_long(parser.scratch, index)
                            buf.add_str(parser.scratch, " should be (u)word/address or ^^ubyte")
                            error_scratch(n)
                            wrong = true
                        }
                    }
                }
            }
            r = r.next
        }
        if twice
            error(n, "a register is used multiple times in the return values")
        ; a status flag gives a boolean
        index = 0
        r = n.b
        while r != 0 {
            index++
            if r.b != 0 and r.b.kind == ast.N_IDENT and r.b.name != 0 and (r.b.name[0] & $df) == 'P' and r.b.name[1] != 0 and r.b.name[2] == 0 and r.op != token.T_KW_VOID {
                uword ft = typer.return_type(r)
                if ft != 0 and ft != types.T_BOOL and not wrong {
                    begin_message("return type #")
                    buf.add_long(parser.scratch, index)
                    buf.add_str(parser.scratch, " should be bool")
                    error_scratch(n)
                    wrong = true
                }
            }
            r = r.next
        }
        ; the clobber list: with the asmsub, or on the first return type of an extsub
        ^^ast.Node clob = n.d
        if n.kind == ast.N_EXTSUB {
            clob = 0
            if n.b != 0
                clob = n.b.d
        }
        ^^ast.Node cl = clob
        while cl != 0 {
            ; (A, X and Y, one by one; D0-D7 and A0-A6 of the 68000)
            bool m68k_register = cl.name != 0 and cl.name[1] >= '0' and cl.name[2] == 0
                    and ((cl.name[0] == 'D' and cl.name[1] <= '7') or (cl.name[0] == 'A' and cl.name[1] <= '6'))
            if cl.kind == ast.N_IDENT and cl.name != 0 and not m68k_register and (cl.name[1] != 0 or cpu_bits(cl.name) == 0) {
                error(n, "Syntax error: invalid cpu register")
                break
            }
            cl = cl.next
        }
        while clob != 0 {
            if clob.kind == ast.N_IDENT and clob.name != 0 and (cpu_bits(clob.name) & used) != 0 {
                error(n, "a return register is also in the clobber list")
                break
            }
            clob = clob.next
        }
    }

    ; The registers of an asmsub's or extsub's parameters: none used twice (AY takes A
    ; and Y), and each of the size of its parameter.
    sub register_params(^^ast.Node p) {
        bool used_a = false
        bool used_x = false
        bool used_y = false
        bool reg_twice = false
        bool flag_twice = false
        ^^ast.Node q = p
        while q != 0 {
            if q.b != 0 and q.b.name != 0 {
                ^^ubyte r = q.b.name
                ubyte letters = 0
                bool cpu = true
                while r[letters] != 0 {
                    ubyte c = r[letters] & $df
                    if c != 'A' and c != 'X' and c != 'Y'
                        cpu = false
                    letters++
                }
                if cpu and letters <= 2 {
                    ubyte k
                    for k in 0 to letters - 1 {
                        when r[k] & $df {
                            'A' -> {
                                if used_a
                                    reg_twice = true
                                used_a = true
                            }
                            'X' -> {
                                if used_x
                                    reg_twice = true
                                used_x = true
                            }
                            'Y' -> {
                                if used_y
                                    reg_twice = true
                                used_y = true
                            }
                        }
                    }
                    uword t = q.a.type
                    if t != 0 {
                        long size = types.size_of(t)
                        if letters == 1 and size != 1 {
                            begin_message("parameter '")
                            buf.add_str(parser.scratch, q.name)
                            buf.add_str(parser.scratch, "' should be (u)byte or bool")
                            error_scratch(q)
                        }
                        else if letters == 2 and size != 2 and t != types.T_STR {
                            begin_message("parameter '")
                            buf.add_str(parser.scratch, q.name)
                            buf.add_str(parser.scratch, "' should be (u)word, str or a pointer")
                            error_scratch(q)
                        }
                    }
                }
                else {
                    if (r[0] & $df) == 'P' and (r[1] & $df) != 'C' and r[1] != 0
                        error(q, "can only use Carry as status flag parameter")
                    else if (r[0] & $df) == 'P' and (r[1] & $df) == 'C' and r[2] == 0 and q.a != 0 and q.a.type != 0 and q.a.type != types.T_BOOL {
                        begin_message("parameter '")
                        buf.add_str(parser.scratch, q.name)
                        buf.add_str(parser.scratch, "' should be of type bool")
                        error_scratch(q)
                    }
                    ; a virtual register or a status flag: the same one twice
                    ^^ast.Node other = p
                    while other != q {
                        if other.b != 0 and other.b.name != 0 and strings.compare_nocase(other.b.name, r) == 0 {
                            if (r[0] & $df) == 'P'
                                flag_twice = true
                            else
                                reg_twice = true
                        }
                        other = other.next
                    }
                }
            }
            q = q.next
        }
        if p != 0 and reg_twice
            error(p, "a register is used multiple times in the parameters")
        if p != 0 and flag_twice
            error(p, "a status flag is used multiple times in the parameters")
    }

    sub return_types(^^ast.Node r) {
        while r != 0 {
            uword t = r.type
            if types.is_struct(t)
                error(r, "structs can only be returned via a pointer")
            else if types.is_array(t)
                error(r, "arrays can't be returned, use a pointer")
            else if types.is_pointer(t) and types.elem_of(t) == types.T_STR
                error(r, "^^str is not a valid return type, use ^^ubyte?")
            r = r.next
        }
    }

    sub sub_decl(^^ast.Node s) {
        check_name(s, s.name)
        if symtab.builtins != 0 and symtab.find_in(symtab.builtins, s.name) != 0
            error(s, "builtin function cannot be redefined")
        params(s.a)
        return_types(s.b)
        ^^symtab.Sym saved_sub = current_sub
        uword saved_depth = loop_depth
        uword saved_nesting = nesting
        current_sub = s.extra
        loop_depth = 0
        nesting = 0
        statements(s.c)
        current_sub = saved_sub
        loop_depth = saved_depth
        nesting = saved_nesting
        ; a register for a parameter of an ordinary subroutine: a virtual one
        ^^ast.Node rp = s.a
        while rp != 0 {
            if rp.b != 0 and rp.b.name != 0 and (rp.b.name[0] & $df) != 'R' {
                error(rp, "can only use R0-R15 as register param for normal subroutines")
                break
            }
            if rp.b != 0 and rp.b.name != 0 and rp.a != 0 and rp.a.type != 0 {
                ; what a virtual register holds
                uword rpt = rp.a.type
                if types.is_pointer(rpt) and rpt != types.ADDRESS_TYPE {
                    error(rp, "pointer parameters cannot be register-mapped")
                    break
                }
                if rpt == types.T_FLOAT or rpt == types.T_STR {
                    error(rp, "using R0-R15 as register param requires integer or boolean type")
                    break
                }
            }
            rp = rp.next
        }
        checks++
        if s.b == 0 or (s.flags & ast.F_INLINE) != 0
            return
        ; a subroutine with result values must return them
        returning_sub = s
        bool any_return = returns_somewhere(s.c)
        returning_sub = 0
        if not any_return {
            error(s, "non-inline subroutine has result value(s) and thus must have at least one 'return' or external 'goto' in it (or the assembler equivalent in case of %asm)")
            return
        }
        ^^ast.Node last = last_statement(s.c)
        if last == 0 {
            sub_return_error(s, s)
            return
        }
        bool bad = false
        when last.kind {
            ast.N_RETURN, ast.N_GOTO, ast.N_ONGOTO, ast.N_ASM -> bad = false
            ast.N_IF, ast.N_BRANCH -> bad = not returns_somewhere(last.b) and not returns_somewhere(last.c)
            ast.N_FOR -> bad = returns_somewhere(last.c)
            ast.N_WHILE -> bad = not returns_somewhere(last.b)
            ast.N_UNTIL -> bad = not returns_somewhere(last.a)
            ast.N_REPEAT -> bad = last.a != 0 or not returns_somewhere(last.b)
            ast.N_WHEN -> {
                bad = true
                ^^ast.Node c = last.b
                while c != 0 {
                    if returns_somewhere(c.b)
                        bad = false
                    c = c.next
                }
            }
            else -> bad = true
        }
        if bad
            sub_return_error(s, last)
    }

    sub sub_return_error(^^ast.Node s, ^^ast.Node at) {
        begin_message("subroutine '")
        buf.add_str(parser.scratch, s.name)
        buf.add_str(parser.scratch, "' has result value(s) but doesn't end with a return statement")
        error_scratch(at)
    }

    ; the last statement that is not a declaration
    sub last_statement(^^ast.Node s) -> ^^ast.Node {
        ^^ast.Node last = 0
        while s != 0 {
            when s.kind {
                ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB, ast.N_VARDECL, ast.N_DIRECTIVE, ast.N_STRUCT, ast.N_UNION, ast.N_ENUM, ast.N_ALIAS -> {
                }
                else -> last = s
            }
            s = s.next
        }
        return last
    }

    ; Is there a return, goto or inline assembly anywhere in the statements
    ; (not looking into nested subroutines)?
    ^^ast.Node returning_sub = 0        ; the subroutine returns_somewhere looks at, when it matters

    sub returns_somewhere(^^ast.Node s) -> bool {
        while s != 0 {
            when s.kind {
                ast.N_GOTO -> {
                    ; a jump to a label of the subroutine itself does not leave it
                    bool leaves = true
                    if returning_sub != 0 and s.a != 0 and s.a.kind == ast.N_IDENT and s.a.extra != 0 {
                        ^^symtab.Sym gl = s.a.extra
                        if gl.kind == symtab.K_LABEL and gl.scope != 0 and gl.scope.owner == returning_sub
                            leaves = false
                    }
                    if leaves
                        return true
                }
                ast.N_RETURN, ast.N_ONGOTO, ast.N_ASM -> return true
                ast.N_IF, ast.N_BRANCH -> {
                    if returns_somewhere(s.b)
                        return true
                    if returns_somewhere(s.c)
                        return true
                }
                ast.N_FOR -> {
                    if returns_somewhere(s.c)
                        return true
                }
                ast.N_WHILE, ast.N_REPEAT, ast.N_UNROLL -> {
                    if returns_somewhere(s.b)
                        return true
                }
                ast.N_UNTIL, ast.N_DEFER -> {
                    if returns_somewhere(s.a)
                        return true
                }
                ast.N_WHEN -> {
                    ^^ast.Node c = s.b
                    while c != 0 {
                        if returns_somewhere(c.b)
                            return true
                        c = c.next
                    }
                }
            }
            s = s.next
        }
        return false
    }

    ; ---- statements ----

    ; an assignment target: a constant or a whole string cannot be assigned
    sub target(^^ast.Node t, bool augmented) {
        if t.kind == ast.N_IDENT {
            ^^symtab.Sym s = t.extra
            if s != 0 {
                if s.kind == symtab.K_CONST
                    error(t, "cannot assign new value to a constant")
                else if s.kind == symtab.K_SUB or s.kind == symtab.K_LABEL or s.kind == symtab.K_BLOCK or s.kind == symtab.K_BUILTIN
                    error(t, "assignment LHS must be register or variable")
            }
        }
        bool is_strvar = false
        if t.kind == ast.N_IDENT and t.op != resolver.R_FIELDREF and t.extra != 0 {
            ^^symtab.Sym vs = t.extra
            is_strvar = vs.kind == symtab.K_VAR and t.type == types.T_STR
        }
        if is_strvar {
            if augmented
                error(t, "cannot assign to string by value (use strings.(n)copy or strings.(n)append)")
            else
                error(t, "cannot assign to string by value (use strings.(n)copy)")
        }
        expression(t)
    }

    sub assignment(^^ast.Node n) {
        ^^ast.Node t = n.a
        if t.kind == ast.N_VOID and t.next == 0 {
            if n.b.kind == ast.N_CALL
                error(n, "cannot assign to 'void', perhaps a void function call was intended")
            else
                error(n, "cannot assign to 'void'")
        }
        while t != 0 {
            if t.kind != ast.N_VOID
                target(t, false)
            t = t.next
        }
        ^^ast.Node value = n.b
        if value.kind == ast.N_TUPLE and ast.list_length(value.a) != ast.list_length(n.a)
            error(n, "Syntax error: multivalue assignment: number of values does not match number of targets")
        if n.a.next == 0 and n.a.kind != ast.N_VOID
            value_shape(n, value, n.a.type)
        if value.kind == ast.N_IDENT and value.extra != 0 {
            ; the name of a subroutine or label is not a value: its address is (&name)
            ^^symtab.Sym vs = value.extra
            if vs.kind == symtab.K_SUB or vs.kind == symtab.K_LABEL
                error(n, "invalid assignment value")
        }
        if value.kind == ast.N_ASSIGN
            assignment(value)
        else
            expression(value)
        if n.a.next == 0 and n.a.kind != ast.N_VOID {
            struct_values(n, n.a.type, value)
            ; arrays are copied whole: the same number of elements on both sides
            uword tt = n.a.type
            if tt != 0 and types.is_array(tt) and value.type != 0 and (types.is_array(value.type) or value.kind == ast.N_ARRAYLIT) {
                long want = typer.known_length(n.a)
                long got = typer.known_length(value)
                if value.kind == ast.N_ARRAYLIT
                    got = ast.list_length(value.a)
                if want > 0 and got > 0 and want != got {
                    begin_message("array size mismatch (expecting ")
                    buf.add_long(parser.scratch, want)
                    buf.add_str(parser.scratch, ", got ")
                    buf.add_long(parser.scratch, got)
                    buf.add_byte(parser.scratch, ')')
                    error_scratch(n)
                }
                else if n.a.kind == ast.N_IDENT
                    error(n, "cannot assign arrays directly. Maybe use sys.memcopy instead.")
            }
            else if tt != 0 and types.is_array(tt) and n.a.kind == ast.N_IDENT and value.kind == ast.N_ARRAYLIT
                error(n, "cannot assign arrays directly. Maybe use sys.memcopy instead.")
        }
        float_results(value)
        ; a call's values and the targets they go to: as many of each
        if value.kind == ast.N_CALL and value.a.extra != 0 {
            ^^symtab.Sym callee = value.a.extra
            if callee.kind == symtab.K_SUB {
                long given = ast.list_length(typer.returns_of(callee))
                long wanted = ast.list_length(n.a)
                if given > wanted and given > 1 {
                    begin_message("call returns too many values: expected ")
                    buf.add_long(parser.scratch, wanted)
                    buf.add_str(parser.scratch, " got ")
                    buf.add_long(parser.scratch, given)
                    error_scratch(n)
                }
                else if given < wanted and wanted > 1 {
                    begin_message("call returns too few values: expected ")
                    buf.add_long(parser.scratch, wanted)
                    buf.add_str(parser.scratch, " got ")
                    buf.add_long(parser.scratch, given)
                    error_scratch(n)
                }
            }
        }
    }

    sub goto_check(^^ast.Node n) {
        ^^ast.Node t = n.a
        if t.kind == ast.N_IDENT {
            ^^symtab.Sym s = t.extra
            if s != 0 {
                if s.kind == symtab.K_BUILTIN
                    error(n, "can't jump to a builtin function")
                else if s.kind == symtab.K_SUB and s.decl.a != 0
                    error(n, "can't jump to a subroutine that takes parameters")
                else if s.kind == symtab.K_VAR and s.type != 0 and s.type != types.T_UWORD and not types.is_pointer(s.type)
                        and (types.POINTER_SIZE == 2 or types.size_of(s.type) < 2)
                    error(n, "wrong address variable datatype, expected uword")
            }
            return
        }
        bool gok
        quad gaddr
        gok, gaddr = typer.const_eval(t)
        if gok and gaddr > max_address
            error(n, "goto address must fit in a pointer")
        expression(t)
    }

    sub unroll_check(^^ast.Node n) {
        bool ok
        quad v
        ok, v = typer.const_eval(n.a)
        if not ok
            error(n, "unroll needs constant number of iterations")
        else if v < 0 or v > 65535
            error(n, "invalid number of unrolls")
        ^^ast.Node s = n.b
        while s != 0 {
            when s.kind {
                ast.N_ASM, ast.N_VARDECL, ast.N_ASSIGN, ast.N_AUGASSIGN, ast.N_INCDEC, ast.N_CALLSTMT -> {
                }
                else -> error(s, "invalid statement in unroll loop")
            }
            s = s.next
        }
        statements(n.b)
    }

    sub whenstmt(^^ast.Node n) {
        uword ct = n.a.type
        if ct == types.T_BOOL
            error(n, "condition is boolean, use if statement instead")
        else if ct != 0 and not types.is_integer(ct)
            error(n, "when condition must be an integer value")
        expression(n.a)
        if n.b == 0
            error(n, "empty when statement")
        bool ok
        quad v
        ^^ast.Node c = n.b
        while c != 0 {
            if c.a == 0 {
                if c.next != 0
                    error(c, "else choice must be the last one")
            }
            else {
                ^^ast.Node value = c.a
                while value != 0 {
                    if value.kind == ast.N_RANGE {
                        ; "10 to 20": every value from the one to the other
                        quad last
                        ok, v = typer.constlike_eval(value.a)
                        if ok
                            ok, last = typer.constlike_eval(value.b)
                        if ok and value.c != 0 {
                            quad step
                            ok, step = typer.constlike_eval(value.c)
                            if ok and step == 0
                                ok = false
                        }
                        if not ok
                            error(value, "choice values must be constant numbers")
                        else if ct != 0 and (not typer.literal_fits(v, ct) or not typer.literal_fits(last, ct))
                            error(value, "choice value datatype differs from condition value")
                        value = value.next
                        continue
                    }
                    ok, v = typer.constlike_eval(value)
                    if not ok
                        error(value, "choice values must be constant numbers")
                    else if ct != 0 and not typer.literal_fits(v, ct)
                        error(value, "choice value datatype differs from condition value")
                    else if occurs_before(n, c, value, v)
                        error(value, "choice value already occurs elsewhere")
                    value = value.next
                }
            }
            statements(c.b)
            c = c.next
        }
        checks++
    }

    ; Does the choice value occur in an earlier choice of the when statement?
    sub occurs_before(^^ast.Node w, ^^ast.Node choice, ^^ast.Node value, quad v) -> bool {
        bool ok
        quad other
        ^^ast.Node c = w.b
        while c != 0 {
            ^^ast.Node cv = c.a
            while cv != 0 {
                if cv == value
                    return false
                ok, other = typer.const_eval(cv)
                if ok and other == v
                    return true
                cv = cv.next
            }
            c = c.next
        }
        return false
    }

    ; An enum's members count upwards: a value that is given is above the one before it.
    ; And "::" is for using a member, not for naming one.
    sub enum_members(^^ast.Node n) {
        if has_colons(n.name)
            error(n, "only enum members can be accessed with '::' syntax")
        ^^ast.Node m = n.a
        quad next_value = 0
        while m != 0 {
            if has_colons(m.name) {
                begin_message("invalid enum member name '")
                buf.add_str(parser.scratch, m.name)
                buf.add_byte(parser.scratch, 39)
                error_scratch(m)
            }
            if m.a != 0 {
                bool mok
                quad mv
                mok, mv = typer.const_eval(m.a)
                if mok {
                    ; a value that is given is not one a member before it has
                    ^^ast.Node earlier = n.a
                    quad ev = 0
                    while earlier != m {
                        if earlier.a != 0 {
                            bool eok
                            quad egiven
                            eok, egiven = typer.const_eval(earlier.a)
                            if eok
                                ev = egiven
                        }
                        if ev == mv {
                            begin_message("invalid enum sequence member value ")
                            buf.add_str(parser.scratch, m.name)
                            buf.add_str(parser.scratch, " = ")
                            buf.add_long(parser.scratch, mv as long)
                            error_scratch(m)
                            break
                        }
                        ev++
                        earlier = earlier.next
                    }
                    next_value = mv
                }
            }
            next_value++
            m = m.next
        }
    }

    sub has_colons(^^ubyte name) -> bool {
        if name == 0
            return false
        long i = 0
        while name[i] != 0 {
            if name[i] == ':'
                return true
            i++
        }
        return false
    }

    sub forloop(^^ast.Node n) {
        ^^ast.Node fo = n.d
        bool walks = false
        while fo != 0 {
            if fo.kind == ast.N_FOROPT and fo.op == token.T_KW_VIA
                walks = true
            fo = fo.next
        }
        fo = n.d
        while fo != 0 {
            if walks and fo.kind == ast.N_FOROPT and fo.op == token.T_KW_STEP
                error(fo, "linked-list for loop cannot use 'step'")
            fo = fo.next
        }
        ^^ast.Node opt = n.d
        bool typed = false
        if opt != 0 and opt.kind == ast.N_TYPE {
            typed = true
            opt = opt.next
        }
        ^^ast.Node via_opt = 0
        ^^ast.Node until_opt = 0
        ^^ast.Node step_opt = 0
        while opt != 0 {
            if opt.op == token.T_KW_VIA
                via_opt = opt
            else if opt.op == token.T_KW_UNTIL
                until_opt = opt
            else
                step_opt = opt
            opt = opt.next
        }
        ^^symtab.Sym lv = n.a.extra
        uword lvt = n.a.type
        uword it = n.b.type
        bool ok
        quad v
        checks++
        if via_opt == 0 and lv != 0 and lvt != 0 and lv.decl != 0 and lv.decl.kind == ast.N_FOR and lv.decl != n {
            ; the variable is an earlier loop's: this loop asks for the same type, which
            ; without one written is that of what it goes over
            uword wanted = 0
            if typed
                wanted = typer.from_type(n.d)
            else if n.b.kind == ast.N_RANGE {
                quad lo
                quad hi
                ok, lo = typer.const_eval(n.b.a)
                if ok {
                    ok, hi = typer.const_eval(n.b.b)
                    if ok {
                        if hi < lo {
                            v = lo
                            lo = hi
                            hi = v
                        }
                        wanted = types.literal_type(hi)
                        if lo < 0 {
                            wanted = types.literal_type(lo)
                            if types.size_of(types.literal_type(hi)) > types.size_of(wanted) or (hi > 127 and types.size_of(wanted) == 1)
                                wanted = types.T_WORD
                        }
                    }
                }
            }
            else if it != 0 and types.is_array(it)
                wanted = types.elem_of(it)
            ; (a wider variable takes the narrower values)
            if wanted != 0 and wanted != lvt and types.is_integer(wanted) and types.is_integer(lvt)
                    and not (types.size_of(lvt) > types.size_of(wanted) and (types.is_signed(lvt) or not types.is_signed(wanted))) {
                begin_message("for loop var '")
                buf.add_str(parser.scratch, lv.name)
                buf.add_str(parser.scratch, "' already has type ")
                types.name_into(parser.scratch, lvt)
                buf.add_str(parser.scratch, " (from an earlier variable declaration or for loop), but the requested type is ")
                types.name_into(parser.scratch, wanted)
                error_scratch(n)
            }
        }
        if via_opt != 0 {
            if lv == 0 or not types.is_pointer(lvt)
                error(n, "linked-list for loop requires a pointer loop variable")
            else if types.is_struct(types.elem_of(lvt)) and via_opt.a != 0 and via_opt.a.name != 0 {
                ; the field the walk follows points to the next node
                ^^types.Type vst = types.get(types.elem_of(lvt))
                ^^symtab.Sym vss = vst.strct
                ^^symtab.Sym vf = 0
                if vss != 0 and vss.inner != 0 {
                    vf = vss.inner.syms
                    while vf != 0 and not (vf.kind == symtab.K_FIELD and strings.compare(vf.name, via_opt.a.name) == 0)
                        vf = vf.next
                }
                if vf == 0 or vf.type != lvt
                    error(n, "linked-list for loop 'via' field must be a pointer to the same node type")
            }
            if until_opt != 0 and until_opt.a != 0 and lv != 0 {
                ; where the walk ends: a node pointer, an address taken with &, or 0
                ^^ast.Node ue = until_opt.a
                bool uok = ue.kind == ast.N_ADDROF or (ue.kind != ast.N_CAST and ue.kind != ast.N_INT and ue.type == lvt)
                if ue.kind == ast.N_INT and ue.value == 0
                    uok = true
                if not uok
                    error(n, "linked-list for loop 'until' must be a compatible node pointer or 0")
            }
            expression(n.b)
            loop_body(n.c)
            return
        }
        if until_opt != 0
            error(n, "'until' can only be used in linked-list for loops")
        if step_opt != 0 {
            if n.b.kind == ast.N_RANGE
                error(n, "step on for-loop cannot be combined with range step - use 'to/downto ... step ...' inside the range")
            else {
                ok, v = typer.const_eval(step_opt.a)
                if not ok
                    error(n, "step for non-range iterable must be a constant 1 or -1")
                else if v != 1 and v != -1
                    error(n, "step for non-range iterable must be 1 or -1 (arrays and strings have no stride)")
            }
        }
        if n.b.kind == ast.N_CALL
            error(n, "can not loop over function call return value")
        else if n.b.kind != ast.N_RANGE and not types.is_iterable(it) and not is_pointer_to_byte(it) {
            if types.is_pointer(it) and types.is_struct(types.elem_of(it))
                error(n, "pointer-linked for loop requires an explicit 'via .field'")
            else
                error(n, "can only loop over an iterable type")
        }
        else if lv == 0 or lv.kind == symtab.K_CONST
            error(n, "for loop requires a variable to loop with")
        else
            loopvar_type(n, lvt, it, typed)
        if n.b.kind == ast.N_RANGE {
            ; a range in a for loop may have a variable step
            expression(n.b.a)
            expression(n.b.b)
            expression(n.b.c)
            range(n.b, true)
        }
        else
            expression(n.b)
        loop_body(n.c)
    }

    sub bad_bound(^^ast.Node b, uword lvt) -> bool {
        if b.kind == ast.N_INT and types.is_integer(lvt) and not typer.literal_fits(b.value, lvt) {
            error(b, "incompatible range value type")
            return true
        }
        return false
    }

    ; a literal range bound takes the loop variable's type when it fits
    sub bound_type(^^ast.Node b, uword lvt) -> uword {
        if b.kind == ast.N_INT and types.is_integer(lvt) and typer.literal_fits(b.value, lvt)
            return lvt
        return b.type
    }

    ; a plain array or string indexed by a signed variable.  An address
    ; variable is not checked: upstream has made ptr[i] into @(ptr+i) before
    ; its check, so a signed index there is allowed and counts backwards.
    sub signed_index(^^ast.Node e) {
        if e.a.kind != ast.N_IDENT or e.a.op == resolver.R_FIELDREF or e.b == 0 or e.b.kind != ast.N_IDENT or e.b.next != 0
            return
        ^^symtab.Sym target = e.a.extra
        ^^symtab.Sym index = e.b.extra
        if target == 0 or index == 0 or target.type == 0 or index.type == 0
            return
        if target.kind != symtab.K_VAR or not types.is_iterable(target.type)
            return
        if (index.kind != symtab.K_VAR and index.kind != symtab.K_PARAM) or e.b.op == resolver.R_FIELDREF
            return
        if types.is_integer(index.type) and types.is_signed(index.type)
            error(e.b, "variable array indexing can't be performed with signed variables")
    }

    sub is_pointer_to_byte(uword t) -> bool {
        if not types.is_pointer(t)
            return false
        uword e = types.elem_of(t)
        return e == types.T_UBYTE or e == types.T_BYTE
    }

    ; the loop variable's type must suit what it iterates over
    sub loopvar_type(^^ast.Node n, uword lvt, uword it, bool typed) {
        bool is_range = n.b.kind == ast.N_RANGE
        if n.b.kind == ast.N_ARRAYLIT
            return          ; the literal's elements take the loop variable's type
        if is_range {
            ; a literal bound that does not fit the loop variable is reported as upstream does
            if bad_bound(n.b.a, lvt) or bad_bound(n.b.b, lvt)
                return
            it = typer.range_type(bound_type(n.b.a, lvt), bound_type(n.b.b, lvt))
        }
        uword elem = 0
        if types.is_array(it)
            elem = types.elem_of(it)
        ubyte base = types.base_of(lvt)
        bool ok = true
        when base {
            types.T_UBYTE -> ok = it == types.T_UBYTE or elem == types.T_UBYTE or it == types.T_STR or is_pointer_to_byte(it)
            types.T_BOOL -> ok = elem == types.T_BOOL
            types.T_UWORD -> ok = it == types.T_UBYTE or it == types.T_UWORD or it == types.T_STR or elem == types.T_UBYTE or elem == types.T_UWORD or elem == types.T_STR
            types.T_BYTE -> ok = it == types.T_BYTE or elem == types.T_BYTE
            types.T_WORD -> {
                ok = it == types.T_BYTE or it == types.T_WORD or elem == types.T_BYTE or elem == types.T_UBYTE or elem == types.T_WORD or elem == types.T_UWORD
                if typed and it == types.T_STR
                    ok = true
            }
            types.T_LONG -> ok = true
            types.T_QUAD, types.T_UQUAD -> ok = not is_range and elem == lvt
            types.T_FLOAT -> ok = false
            types.T_POINTER -> {
                ok = it == types.T_UWORD or elem == types.T_UWORD or elem == types.T_LONG or elem == types.T_STR or types.is_pointer(elem)
                if types.POINTER_SIZE > 4 and elem == types.T_UQUAD
                    ok = true
            }
            else -> ok = false
        }
        if not ok {
            when base {
                types.T_UBYTE -> error(n, "ubyte loop variable can only loop over unsigned bytes or strings")
                types.T_BOOL -> error(n, "bool loop variable can only loop over boolean array")
                types.T_UWORD -> error(n, "uword loop variable can only loop over unsigned bytes, words or strings")
                types.T_BYTE -> error(n, "byte loop variable can only loop over bytes")
                types.T_WORD -> error(n, "word loop variable can only loop over bytes or words")
                types.T_QUAD, types.T_UQUAD -> {
                    if is_range
                        error(n, "quad loop variable can't loop over a range, only over a quad array")
                    else
                        error(n, "quad loop variable can only loop over a quad array")
                }
                types.T_FLOAT -> error(n, "for loop only supports integers")
                types.T_POINTER -> error(n, "pointer loop variable can only loop over pointers or unsigned words")
                else -> error(n, "loop variable must be numeric or pointer type")
            }
            return
        }
        if not is_range
            return
        ; the range bounds must fit the loop variable
        ^^ast.Node r = n.b
        if r.a.kind == ast.N_INT {
            if not typer.literal_fits(r.a.value, lvt)
                error(r, "range start value is incompatible with loop variable type")
        }
        else if r.a.type != 0 and not types.assignable(r.a.type, lvt)
            error(r, "range start value is incompatible with loop variable type")
        if r.b.kind == ast.N_INT {
            if not typer.literal_fits(r.b.value, lvt)
                error(r, "range end value is incompatible with loop variable type")
        }
        else if r.b.type != 0 and not types.assignable(r.b.type, lvt)
            error(r, "range end value is incompatible with loop variable type")
    }

    ; ---- expressions ----

    sub expressions(^^ast.Node e) {
        while e != 0 {
            expression(e)
            e = e.next
        }
    }

    sub expression(^^ast.Node e) {
        if e == 0
            return
        bool ok
        quad v
        if types.POINTER_SIZE == 2 and types.far_bits == 0 and e.kind == ast.N_MEMREAD and e.a != 0 and e.a.kind == ast.N_IDENT and e.a.type == types.T_LONG
            error(e, "invalid address type for memory access")      ; (an address is a word here)
        else if types.POINTER_SIZE == 2 and e.kind == ast.N_MEMREAD and e.a != 0 and e.a.kind == ast.N_INT and (e.a.value > max_data_address() or e.a.value < 0)
            error(e, "invalid address type for memory access")      ; (a number that does not fit one)
        else if types.POINTER_SIZE == 2 and types.far_bits == 0 and e.kind == ast.N_MEMREAD and e.a != 0 and e.a.kind == ast.N_BINARY and e.a.type == types.T_LONG
                and (long_var(e.a.a) or long_var(e.a.b))
            error(e, "invalid address type for memory access")
        when e.kind {
            ast.N_IDENT -> check_name(e, e.name)
            ast.N_STR -> {
                if e.value > 255
                    error(e, "string literal length max is 255")
            }
            ast.N_INDEX -> {
                expression(e.a)
                expressions(e.b)
                signed_index(e)
                if types.POINTER_SIZE == 2 and e.a.kind == ast.N_IDENT and e.a.op == resolver.R_FIELDREF and e.a.type != 0 and types.is_pointer(e.a.type) and e.b != 0 {
                    ; what a struct's pointer field points to is reached with a word
                    ok, v = typer.const_eval(e.b)
                    if ok and v > 65535
                        error(e.b, "index out of range for 16-bit pointers")
                }
                index_bounds(e)
                ; (an element of a two-dimensional array is one index by now)
                if e.a.kind == ast.N_INDEX
                    error(e, "chained indexing requires the variable to be declared as a 2D array")
                uword bt = e.a.type
                if bt == types.T_BOOL or bt == types.T_UBYTE or bt == types.T_BYTE or bt == types.T_WORD or bt == types.T_FLOAT
                    error(e, "indexing requires an iterable, address uword, or pointer variable")
                else if types.POINTER_SIZE == 2 and e.a.kind == ast.N_INT and (e.a.value > max_data_address() or e.a.value < 0)
                    error(e, "invalid address type for memory access")
                else if types.POINTER_SIZE == 2 and types.far_bits == 0 and bt == types.T_LONG and e.a.kind == ast.N_IDENT {
                    ; a long is no address where addresses are words
                    ^^symtab.Sym ls = e.a.extra
                    if ls != 0 and ls.kind == symtab.K_CONST
                        error(e, "invalid address type for memory access")
                    else
                        error(e, "indexing requires an iterable, address uword, or pointer variable")
                }
            }
            ast.N_BINARY -> {
                expression(e.a)
                expression(e.b)
                binary(e)
            }
            ast.N_UNARY -> {
                expression(e.a)
                unary(e)
            }
            ast.N_RANGE -> {
                expression(e.a)
                expression(e.b)
                expression(e.c)
                range(e, false)
            }
            ast.N_CAST -> {
                expression(e.a)
                if e.a.kind == ast.N_DEREF and e.a.type != 0 and types.is_struct(e.a.type)
                    error(e.a, "no support for using struct instances in expressions in this way yet (use pointer to struct instead)")
                if e.b.type == types.T_STR or types.is_array(e.b.type)
                    error(e, "cannot type cast to string or array type")
            }
            ast.N_ADDROF -> {
                if far_variable(e.a) and e.op != token.T_AMP
                    error(e, "the address of a variable in far memory is a long: there is no pointer to it")
                else if far_variable(e.a) and e.b != 0 {
                    bool fiok
                    quad fiv
                    fiok, fiv = typer.const_eval(e.b)
                    if not fiok
                        error(e, "the address of an element in far memory needs a constant index for now")
                }
                if e.op == token.T_AMPAMP and e.a.kind == ast.N_IDENT and e.a.extra != 0 {
                    ^^symtab.Sym tps = e.a.extra
                    if tps.kind == symtab.K_SUB
                        error(e, "no support for typed pointers to subroutines, you can take an untyped pointer instead to use with goto / call() etc.")
                }
                if e.a.kind == ast.N_IDENT and e.b == 0 {
                    ^^symtab.Sym s = e.a.extra
                    if s != 0 and s.kind == symtab.K_CONST
                        error(e, "invalid address-of operand type")
                    if e.op == token.T_AMPGT and s != 0 and for_6502() and s.decl != 0 and s.decl.kind == ast.N_VARDECL {
                        ; the high bytes are apart only in a split word array
                        uword st = s.type
                        uword se = 0
                        if st != 0 and types.is_array(st)
                            se = types.elem_of(st)
                        if se == 0 or types.size_of(se) != 2 or types.is_struct(se) or has_tag(s.decl, strtab.intern_cstr("nosplit")) or s.decl.op == token.T_AMP
                            error(e, "$> can only be used on split word arrays")
                    }
                }
                expression(e.b)
            }
            ast.N_IFEXPR -> {
                expression(e.a)
                expression(e.b)
                expression(e.c)
                ; (a number adapts to the type of the other value)
                if e.b.type != 0 and e.c.type != 0 and e.b.type != e.c.type and e.b.kind != ast.N_INT and e.c.kind != ast.N_INT
                    error(e.b, "both values in the if expression should be the same type")
            }
            ast.N_CALL -> {
                ; (an array is passed by its address, a word)
                ^^ast.Node fararg = e.b
                while fararg != 0 {
                    if far_variable(fararg) and fararg.type != 0 and types.is_array(fararg.type)
                        error(fararg, "an array in far memory cannot be passed to a subroutine yet (its address does not fit a pointer)")
                    fararg = fararg.next
                }
                check_name(e.a, e.a.name)
                expressions(e.b)
                ^^ast.Node marg = e.b
                long margn = 1
                while marg != 0 {
                    if several_values(marg) {
                        begin_message("argument ")
                        buf.add_long(parser.scratch, margn)
                        buf.add_str(parser.scratch, " invalid argument type")
                        error_scratch(marg)
                    }
                    margn++
                    marg = marg.next
                }
                if e.a.kind == ast.N_IDENT and e.a.extra != 0 {
                    ^^symtab.Sym called = e.a.extra
                    if called.kind == symtab.K_BUILTIN
                        builtin_call(e, called)
                    if called.kind == symtab.K_BUILTIN and strings.compare(called.name, "call") == 0 and e.b != 0
                            and types.POINTER_SIZE == 2 and e.b.type == types.T_LONG and e.b.kind == ast.N_IDENT
                        error(e.b, "argument 1 type mismatch, was: long expected: POINTER")
                    if called.kind == symtab.K_SUB and called.decl != 0 and called.decl.kind == ast.N_SUB and for_6502()
                        split_arguments(e, called)
                    if called.kind == symtab.K_BUILTIN and strings.compare(called.name, "call") == 0 and e.b != 0 and e.b.next != 0 {
                        begin_message("invalid number of arguments: expected 1 but got ")
                        buf.add_long(parser.scratch, ast.list_length(e.b))
                        error_scratch(e.b)
                    }
                    if called.kind == symtab.K_BUILTIN and strings.compare(called.name, "memory") == 0 and e.b != 0 and e.b.next != 0 {
                        ; memory(name, size, alignment): both are known when the program is built
                        bool mok
                        quad mv
                        mok, mv = typer.const_eval(e.b.next)
                        if mok and e.b.next.next != 0
                            mok, mv = typer.const_eval(e.b.next.next)
                        if not mok
                            error(e.b.next, "argument must be a constant")
                    }
                    if called.kind == symtab.K_BUILTIN and strings.compare(called.name, "call") == 0 and e.b != 0 {
                        ; a subroutine that is named is called by its name
                        ^^ast.Node what = e.b
                        if what.kind == ast.N_ADDROF and what.b == 0
                            what = what.a
                        if what != 0 and what.kind == ast.N_IDENT and what.extra != 0 {
                            ^^symtab.Sym ws = what.extra
                            if ws.kind == symtab.K_SUB
                                error(e.b, "can't call this indirectly, just use normal function call syntax")
                        }
                    }
                    if called.kind == symtab.K_VAR or called.kind == symtab.K_CONST or called.kind == symtab.K_MEMVAR or called.kind == symtab.K_PARAM {
                        begin_message("cannot call that: ")
                        buf.add_str(parser.scratch, e.a.name)
                        error_scratch(e)
                    }
                }
            }
            ast.N_SIZEOF, ast.N_TYPE -> {
            }
            else -> {
                expressions(e.a)
                expressions(e.b)
                expressions(e.c)
            }
        }
    }

    ; a range outside a for loop needs a constant step; constant bounds must match the step's direction
    sub range(^^ast.Node r, bool in_for) {
        bool ok
        quad stride = 1
        quad from
        quad to_value
        if r.c != 0 {
            ok, stride = typer.const_eval(r.c)
            if not ok {
                if not in_for {
                    error(r, "range stride must be a constant integer")
                    return
                }
                if not types.is_integer(r.c.type) {
                    error(r, "range stride must be an integer != 0")
                    return
                }
                return
            }
            if stride == 0 or not types.is_integer(r.c.type) {
                error(r, "range stride must be an integer != 0")
                return
            }
        }
        else if r.op == token.T_KW_DOWNTO
            stride = -1
        if r.b != 0 and r.b.type == types.T_BOOL {
            error(r.b, "range expression to value must be integer")
            return
        }
        ok, from = typer.const_eval(r.a)
        if not ok
            return
        ok, to_value = typer.const_eval(r.b)
        if not ok
            return
        if r.a.type == types.T_FLOAT or r.b.type == types.T_FLOAT {
            error(r, "range expression must be over integers or over characters")
            return
        }
        if from == to_value
            warning(r, "range is just a single value, don't use a loop here")
        else if from < to_value and stride <= 0
            error(r, "ascending range requires step > 0")
        else if from > to_value and stride >= 0
            error(r, "descending range requires step < 0")
    }

    ; a constant index into an array or string of known length
    sub index_bounds(^^ast.Node e) {
        if e.b == 0 or e.b.next != 0
            return
        bool ok
        quad idx
        ok, idx = typer.const_eval(e.b)
        if not ok
            return
        long length = typer.known_length(e.a)
        checks++
        if idx < 0 {
            ; (below zero counts from the end; the typer has put the index there when it could)
            if length == 0 or -idx > length
                error(e.b, "index out of bounds")
            return
        }
        if length == 0
            return
        if e.a.type == types.T_STR {
            ; the terminating zero of a string may be indexed
            if idx > length
                error(e.b, "index out of bounds")
        }
        else if idx >= length
            error(e.b, "index out of bounds")
    }

    ; A boolean and a number do not meet in an operator: upstream's rules, in its order.
    sub boolean_operands(^^ast.Node e) {
        uword lt = e.a.type
        uword rt = e.b.type
        ubyte op = e.op
        if lt == 0 or rt == 0
            return
        bool lbool = lt == types.T_BOOL
        bool rbool = rt == types.T_BOOL
        if not lbool and not rbool {
            if (op == token.T_KW_AND or op == token.T_KW_OR or op == token.T_KW_XOR) and types.is_numeric(lt)
                error(e.b, "logical operator requires boolean operands")
            return
        }
        if op == token.T_KW_IN or op == parser.OP_NOT_IN
            return
        if op == token.T_AMP or op == token.T_PIPE or op == token.T_CARET {
            if op == token.T_AMP
                error(e.b, "operator requires numeric operands, did you mean logical 'and'?")
            else if op == token.T_PIPE
                error(e.b, "operator requires numeric operands, did you mean logical 'or'?")
            else
                error(e.b, "operator requires numeric operands, did you mean logical 'xor'?")
            return
        }
        if lbool and rbool {
            if op == token.T_LT or op == token.T_LE or op == token.T_GT or op == token.T_GE
                error(e, "can't use boolean operand with this comparison operator")
            return
        }
        if not types.is_numeric(lt) and not lbool
            return
        if not types.is_numeric(rt) and not rbool
            return
        if not lbool {
            if op == token.T_KW_AND or op == token.T_KW_OR or op == token.T_KW_XOR {
                error(e.b, "logical operator requires boolean operands")
                return
            }
            if lt == types.T_UBYTE {
                ; a byte on the left: equal to a boolean variable is allowed (0 or 1)
                if op == token.T_EQ or op == token.T_NE {
                    if e.b.kind == ast.N_IDENT
                        return
                    ; (upstream turns the two around before it complains)
                    error(e, "left and right operands aren't the same type: bool vs ubyte")
                }
                else if op == token.T_LT or op == token.T_LE or op == token.T_GT or op == token.T_GE
                    error(e, "can't use boolean operand with this comparison operator")
                else
                    error(e.b, "operator requires numeric operands")
                return
            }
        }
        begin_message("left and right operands aren't the same type: ")
        types.name_into(parser.scratch, lt)
        buf.add_str(parser.scratch, " vs ")
        types.name_into(parser.scratch, rt)
        error_scratch(e)
    }

    sub binary(^^ast.Node e) {
        bool ok
        quad v
        uword lt = e.a.type
        uword rt = e.b.type
        ubyte op = e.op
        if (op == token.T_EQ or op == token.T_NE or op == token.T_LT or op == token.T_LE or op == token.T_GT or op == token.T_GE)
                and lt != 0 and rt != 0 and types.is_array(lt) and types.is_array(rt)
            error(e, "invalid left operand type")
        if (op == token.T_EQ or op == token.T_NE or op == token.T_LT or op == token.T_LE or op == token.T_GT or op == token.T_GE)
                and lt != 0 and rt != 0 and (lt == types.T_STR) != (rt == types.T_STR) {
            uword other = lt
            if lt == types.T_STR
                other = rt
            ; (a string compared with 0 is a test for a null address)
            ^^ast.Node number = e.a
            if lt == types.T_STR
                number = e.b
            ok, v = typer.const_eval(number)
            ; (but not a string variable itself, which is never null)
            ^^ast.Node text = e.b
            if lt == types.T_STR
                text = e.a
            if ok and v == 0 and text.kind == ast.N_IDENT and text.extra != 0 {
                ^^symtab.Sym ts = text.extra
                if ts.kind == symtab.K_VAR
                    ok = false
            }
            if (other == types.T_BOOL or other == types.T_UBYTE or other == types.T_BYTE or other == types.T_FLOAT
                    or (other == types.T_LONG and types.POINTER_SIZE == 2)) and not (ok and v == 0) {
                begin_message("left and right operands aren't the same type: ")
                types.name_into(parser.scratch, lt)
                buf.add_str(parser.scratch, " vs ")
                types.name_into(parser.scratch, rt)
                error_scratch(e)
            }
        }
        boolean_operands(e)
        if op == token.T_SLASH or op == token.T_PERCENT {
            ok, v = typer.const_eval(e.b)
            if ok and v == 0 and e.b.type != types.T_FLOAT
                error(e.b, "division by zero")
        }
        else if op == token.T_SHL or op == token.T_SHR {
            ok, v = typer.const_eval(e.b)
            if ok and v > 255
                error(e, "bit shift value can not be larger than a byte")
        }
        else if op == token.T_STAR and lt == types.T_STR and rt == types.T_BOOL
            error(e.b, "can only multiply string by integer constant")
        else if op == token.T_STAR and e.a.kind == ast.N_ARRAYLIT and rt == types.T_BOOL
            error(e.b, "can only multiply array by integer constant")
        else if op == token.T_STAR and e.a.kind == ast.N_ARRAYLIT {
            ; [values] * count: at most 255 elements
            ok, v = typer.const_eval(e.b)
            long each = ast.list_length(e.a.a)
            if ok and each > 0 and (v < 1 or v > 255 / each)
                error(e.b, "array length must be 1-255")
        }
        else if op == token.T_STAR and lt == types.T_STR {
            ok, v = typer.const_eval(e.b)
            if not ok
                error(e.a, "can only use string repeat with a constant number value")
        }
        if (op == token.T_KW_IN or op == parser.OP_NOT_IN) and e.b.kind != ast.N_ARRAYLIT and e.b.kind != ast.N_RANGE and e.b.kind != ast.N_STR
                and rt != 0 and not types.is_array(rt) and rt != types.T_STR
            error(e.b, "iterable must be an array, a string, or a range expression")
        if (op == token.T_KW_IN or op == parser.OP_NOT_IN) and far_variable(e.b)
            error(e.b, "an array in far memory cannot be searched with 'in' yet (its address does not fit a pointer)")
        if op == token.T_PLUS or op == token.T_MINUS {
            if types.is_array(lt) or (lt == types.T_STR and e.a.kind == ast.N_IDENT and rt != types.T_STR)
                error(e.a, "missing & (address-of) on the operand")
            if types.is_array(rt) or (rt == types.T_STR and e.b.kind == ast.N_IDENT and lt != types.T_STR)
                error(e.b, "missing & (address-of) on the operand")
            if op == token.T_PLUS and types.is_pointer(lt) and types.is_pointer(rt)
                error(e, "cannot add two pointers; perhaps cast one of them to the numeric address type first")
            if op == token.T_MINUS and types.is_pointer(lt) and types.is_pointer(rt) and lt != rt
                error(e, "cannot subtract pointers of different types")
            if op == token.T_MINUS and types.is_pointer(rt) and lt != 0 and types.is_integer(lt)
                error(e, "unclear pointer arithmetic in expression, perhaps you meant to just subtract addresses? Cast pointer to uword in that case.")
        }
        else if types.is_pointer(lt) or types.is_pointer(rt) {
            if not typer.is_bool_op(op)
                error(e.b, "pointer arithmetic only supported for + and - operators, maybe cast to uword?")
        }
    }

    sub unary(^^ast.Node e) {
        uword t = e.a.type
        if t == 0
            return
        if types.is_pointer(t) {
            error(e, "pointers don't support prefix operators")
            return
        }
        when e.op {
            token.T_MINUS -> {
                if not types.is_signed(t) or not types.is_numeric(t)
                    error(e, "can only take negative of a signed number type")
            }
            token.T_TILDE -> {
                if t == types.T_BOOL
                    error(e, "bitwise invert is for integer types, use 'not' on booleans")
                else if not types.is_integer(t)
                    error(e, "can only use bitwise invert on integer types")
            }
            token.T_KW_NOT -> {
                if t != types.T_BOOL
                    error(e, "logical not is for booleans")
            }
        }
    }

    sub stats() {
        out.puts("checker: ")
        out.putl(checks)
        out.puts(" checks")
        out.nl()
    }
}
