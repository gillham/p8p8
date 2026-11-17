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

    ; interned names
    ^^ubyte main_name = 0
    ^^ubyte start_name = 0
    ^^ubyte dirty_name = 0

    ; directives that may only occur at module level, and only once
    str[] module_only = ["output", "launcher", "zeropage", "zpreserved", "zpallowed", "address", "varsaddress", "memtop", "import", "encoding"]
    str[] once_only = ["output", "launcher", "zeropage", "address", "memtop", "varsaddress", "encoding"]
    str[] not_in_module = ["align", "breakpoint", "asminclude", "asmbinary"]
    str[] known_directives = ["address", "align", "asm", "asmbinary", "asminclude", "assert", "breakpoint", "bssaddress", "encoding",
        "import", "ir", "jmptable", "launcher", "link", "memtop", "option", "output", "slabsaddress", "varsaddress",
        "zeropage", "zpallowed", "zpreserved"]
    str[] option_names = ["enable_floats", "force_output", "no_sysinit", "merge", "verafxmuls", "no_symbol_prefixing", "ignore_unused", "romable", "amiga_chipram", "private_symbols", "noframe"]
    str[] block_options = ["force_output", "merge", "verafxmuls", "no_symbol_prefixing", "ignore_unused", "amiga_chipram", "private_symbols"]
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
        }
        else if strings.compare(nm, "assert") == 0 {
            if nargs == 0 or nargs > 2 {
                error(d, "invalid assert directive, expected a constant expression and an optional message string")
                return
            }
            bool ok
            quad v
            ok, v = typer.const_eval(arg)
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
                ast.N_ASSIGN -> {
                    ; only the initialization of the variable declared just before it
                    ok = false
                    if prev != 0 and prev.kind == ast.N_VARDECL and s.a.next == 0 and s.a.kind == ast.N_IDENT {
                        ^^symtab.Sym ts = s.a.extra
                        if ts != 0 and ts.decl == prev
                            ok = true
                    }
                }
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

    sub statement(^^ast.Node n, ubyte level) {
        when n.kind {
            ast.N_DIRECTIVE -> directive(n, level)
            ast.N_VARDECL -> vardecl(n)
            ast.N_SUB -> {
                if level == L_SUB and nesting > 1
                    error(n, "subroutines can only be defined in the scope of a block or within another subroutine")
                sub_decl(n)
            }
            ast.N_ASMSUB, ast.N_EXTSUB -> {
                check_name(n, n.name)
                params(n.a)
                return_types(n.b)
                register_params(n.a)
                register_returns(n)
                if n.kind == ast.N_ASMSUB
                    asm_members(n)
                else {
                    if (n.flags & ast.F_INLINE) != 0
                        error(n, "extsub can never be inline")
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
            ast.N_CALLSTMT -> expression(n.a)
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
        if (has_tag(n, strtab.intern_cstr("alignword")) or has_tag(n, strtab.intern_cstr("align64")) or has_tag(n, strtab.intern_cstr("alignpage")))
                and (has_tag(n, strtab.intern_cstr("zp")) or has_tag(n, strtab.intern_cstr("requirezp")))
            error(n, "zeropage variables can't have alignment")
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
            else if init != 0 and not is_tuple and t != types.T_FLOAT {
                ok, v = typer.constlike_eval(init)
                if not ok
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
                else if v < 0 or v > max_address
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
        if given != 0 and given != fields {
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
                        if at == types.T_FLOAT or at == types.T_BOOL
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
        else if elemsize == 2 {
            if length < 1 or length > limit {
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

    sub struct_decl(^^ast.Node s) {
        check_name(s, s.name)
        if s.a == 0 {
            if s.kind == ast.N_UNION
                error(s, "union must have at least one field")
            else
                error(s, "struct must contain at least one field")
            return
        }
        ; a field that is a struct itself (not a pointer to one)
        ^^symtab.Sym ss = s.extra
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
                        else if pair and size != 2 and t != types.T_STR {
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
        ; the clobber list: with the asmsub, or on the first return type of an extsub
        ^^ast.Node clob = n.d
        if n.kind == ast.N_EXTSUB {
            clob = 0
            if n.b != 0
                clob = n.b.d
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
            rp = rp.next
        }
        checks++
        if s.b == 0 or (s.flags & ast.F_INLINE) != 0
            return
        ; a subroutine with result values must return them
        if not returns_somewhere(s.c) {
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
    sub returns_somewhere(^^ast.Node s) -> bool {
        while s != 0 {
            when s.kind {
                ast.N_RETURN, ast.N_GOTO, ast.N_ONGOTO, ast.N_ASM -> return true
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
            }
        }
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
                ast.N_ASM, ast.N_ASSIGN, ast.N_AUGASSIGN, ast.N_INCDEC, ast.N_CALLSTMT -> {
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

    sub forloop(^^ast.Node n) {
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
        if via_opt != 0 {
            if lv == 0 or not types.is_pointer(lvt)
                error(n, "linked-list for loop requires a pointer loop variable")
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
                index_bounds(e)
                ; (an element of a two-dimensional array is one index by now)
                if e.a.kind == ast.N_INDEX
                    error(e, "chained indexing requires the variable to be declared as a 2D array")
                uword bt = e.a.type
                if bt == types.T_BOOL or bt == types.T_UBYTE or bt == types.T_BYTE or bt == types.T_WORD or bt == types.T_FLOAT
                    error(e, "indexing requires an iterable, address uword, or pointer variable")
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
                if e.b.type == types.T_STR or types.is_array(e.b.type)
                    error(e, "cannot type cast to string or array type")
            }
            ast.N_ADDROF -> {
                if e.a.kind == ast.N_IDENT and e.b == 0 {
                    ^^symtab.Sym s = e.a.extra
                    if s != 0 and s.kind == symtab.K_CONST
                        error(e, "invalid address-of operand type")
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
                check_name(e.a, e.a.name)
                expressions(e.b)
                if e.a.kind == ast.N_IDENT and e.a.extra != 0 {
                    ^^symtab.Sym called = e.a.extra
                    if called.kind == symtab.K_BUILTIN
                        builtin_call(e, called)
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
            error(r, "ascending range requires stride > 0")
        else if from > to_value and stride >= 0
            error(r, "descending range requires stride < 0")
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
            if (other == types.T_BOOL or other == types.T_UBYTE or other == types.T_BYTE or other == types.T_FLOAT) and not (ok and v == 0) {
                begin_message("left and right operands aren't the same type: ")
                types.name_into(parser.scratch, lt)
                buf.add_str(parser.scratch, " vs ")
                types.name_into(parser.scratch, rt)
                error_scratch(e)
            }
        }
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
        else if op == token.T_STAR and lt == types.T_STR {
            ok, v = typer.const_eval(e.b)
            if not ok
                error(e.a, "can only use string repeat with a constant number value")
        }
        if op == token.T_PLUS or op == token.T_MINUS {
            if types.is_array(lt)
                error(e.a, "missing & (address-of) on the operand")
            if types.is_array(rt)
                error(e.b, "missing & (address-of) on the operand")
            if op == token.T_PLUS and types.is_pointer(lt) and types.is_pointer(rt)
                error(e, "cannot add two pointers; perhaps cast one of them to the numeric address type first")
            if op == token.T_MINUS and types.is_pointer(lt) and types.is_pointer(rt) and lt != rt
                error(e, "cannot subtract pointers of different types")
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
