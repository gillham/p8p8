; The typer: gives every declaration and expression its type, following the
; upstream rules.  Pass 1 types the symbols from their declarations; pass 2
; walks all code, infers expression types bottom-up into node.type, and
; checks assignments, arguments and return values.  Calculations keep the
; type of their operands; a literal takes the type of the other operand
; when it fits; comparisons and logic give bool; bitwise results are
; unsigned.

%import ast
%import token
%import types
%import symtab
%import source
%import mem
%import encoding
%import float_platform
%import resolver
%import strtab
%import buf
%import diag
%import importer

typer {
    %option ignore_unused

    ^^importer.Module module = 0
    ^^symtab.Sym current_sub = 0
    long typed = 0
    long unknown = 0
    long checks = 0

    ; builtin function return types: a type id, or one of these rules
    const ubyte R_VOID = 0
    const ubyte R_ARG = 255             ; the type of the first argument
    const ubyte R_ABS = 254             ; abs: unsigned of the argument, float stays float
    const ubyte R_SQRT = 253            ; sqrt: ubyte for bytes and words, uword for long, else the argument type
    const ubyte R_ADDRESS = 252         ; the target's address type
    str[] builtin_names = ["setlsb", "setmsb", "rol", "ror", "rol2", "ror2", "cmp",
        "prog8_lib_stringcompare", "prog8_lib_square_byte", "prog8_lib_square_word", "prog8_lib_square_long",
        "prog8_lib_structalloc", "prog8_lib_copylong", "prog8_lib_copyfloat",
        "abs", "len", "sizeof", "offsetof", "sgn", "sqrt", "divmod", "lmh", "lsb", "msb", "lsw", "msw",
        "mkword", "mklong", "mklong2", "clamp", "min", "max",
        "peek", "peekbool", "peekw", "peekl", "peekq", "peekf", "peekp",
        "poke", "pokebool", "pokebowl", "pokew", "pokel", "pokeq", "pokef", "pokep", "pokemon",
        "rsave", "rrestore", "memory", "callfar", "callfar2", "call",
        "push", "pushw", "pushl", "pushq", "pushf", "pushp", "pop", "popw", "popl", "popq", "popf", "popp"]
    ubyte[] builtin_returns = [R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, R_VOID,
        types.T_BYTE, types.T_UBYTE, types.T_UWORD, types.T_LONG,
        types.T_UWORD, R_VOID, R_VOID,
        R_ABS, types.T_UWORD, types.T_UBYTE, types.T_UBYTE, types.T_BYTE, R_SQRT, R_ARG, types.T_UBYTE, types.T_UBYTE, types.T_UBYTE, types.T_UWORD, types.T_UWORD,
        types.T_UWORD, types.T_LONG, types.T_LONG, R_ARG, R_ARG, R_ARG,
        types.T_UBYTE, types.T_BOOL, types.T_UWORD, types.T_LONG, types.T_QUAD, types.T_FLOAT, R_ADDRESS,
        R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, types.T_UBYTE,
        R_VOID, R_VOID, R_ADDRESS, types.T_UWORD, types.T_UWORD, types.T_UWORD,
        R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, R_VOID, types.T_UBYTE, types.T_UWORD, types.T_LONG, types.T_QUAD, types.T_FLOAT, R_ADDRESS]
    ^^pointer builtin_interned = 0

    sub init() {
        builtin_interned = mem.alloc(len(builtin_names) * sizeof(pointer))
        ubyte i = 0
        while i < len(builtin_names) {
            builtin_interned[i] = strtab.intern_cstr(builtin_names[i])
            i++
        }
    }

    sub run() {
        if builtin_interned == 0
            init()
        types.ensure()
        module_encodings()
        ; pass 1: the declared types of all symbols
        type_scope(symtab.global)
        writes_known = false
        mark_writes()
        writes_known = true
        ; pass 2: expressions and checks
        ^^importer.Module m = importer.modules
        while m != 0 {
            module = m
            ^^ast.Node b = m.tree.a
            while b != 0 {
                if b.kind == ast.N_BLOCK
                    statements(b.a)
                b = b.next
            }
            m = m.next
        }
    }

    ; ---- variables that are never written ----
    ;
    ; Upstream's optimizer makes a variable that is never written a constant, and so
    ; accepts it where a constant is required: as an element of an array initializer, as
    ; a choice of a when statement.  constlike_eval gives such a variable's value in
    ; those places.  It is not used to fold expressions, so no expression changes type.
    ; A module with inline assembly is left alone: assembly can write anything by name.

    bool writes_known = false           ; mark_writes has run: a variable that is not marked is never written
    const ubyte SF_WRITTEN = 16         ; flag on a variable's symbol

    sub mark_writes() {
        ; (assembly can write any variable by its name: never_written looks the name up
        ; in all the assembly of the program, when it is asked about a variable)
        asm_count = 0
        ^^importer.Module m = importer.modules
        while m != 0 {
            collect_assembly(m.tree.a)
            mark_written(m.tree.a)
            m = m.next
        }
    }

    sub has_assembly(^^ast.Node n) -> bool {
        while n != 0 {
            if n.kind == ast.N_ASM or n.kind == ast.N_ASMSUB
                return true
            if n.kind != ast.N_EXTSUB {
                if has_assembly(n.a) or has_assembly(n.b) or has_assembly(n.c) or has_assembly(n.d)
                    return true
            }
            n = n.next
        }
        return false
    }

    ; the assembly texts of the module that is looked at
    const uword MAX_ASM = 16384
    ^^pointer asm_nodes = 0
    uword asm_count = 0

    sub collect_assembly(^^ast.Node n) {
        if asm_nodes == 0
            asm_nodes = mem.alloc(MAX_ASM * sizeof(pointer))
        while n != 0 {
            if n.kind == ast.N_ASM {
                if asm_count < MAX_ASM {
                    asm_nodes[asm_count] = n
                    asm_count++
                }
            }
            else if n.kind != ast.N_EXTSUB {
                collect_assembly(n.a)
                collect_assembly(n.b)
                collect_assembly(n.c)
                collect_assembly(n.d)
            }
            n = n.next
        }
    }

    sub is_word_char(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
    }

    ; does some assembly of the module name this identifier?  (With more texts than
    ; are kept: yes, to be safe.)
    sub named_in_assembly(^^ubyte name) -> bool {
        if asm_count >= MAX_ASM
            return true
        long nlen = buf.cstr_len(name)
        ; (a prefixed name is p8v_name in assembly: the name is still a whole word's end)
        uword k = 0
        while k < asm_count {
            ^^ast.Node an = asm_nodes[k]
            ^^ubyte text = an.extra
            long tlen = an.value as long
            long i = 0
            while text != 0 and i + nlen <= tlen {
                if text[i] == name[0] and buf.bytes_equal(text + i, name, nlen) {
                    bool before = i == 0 or not is_word_char(text[i - 1]) or text[i - 1] == '_'
                    bool after = i + nlen == tlen or not is_word_char(text[i + nlen])
                    if before and after
                        return true
                }
                i++
            }
            k++
        }
        return false
    }

    sub modifies_arguments(^^ubyte name) -> bool {
        return strings.compare(name, "rol") == 0 or strings.compare(name, "ror") == 0
            or strings.compare(name, "rol2") == 0 or strings.compare(name, "ror2") == 0
            or strings.compare(name, "setlsb") == 0 or strings.compare(name, "setmsb") == 0
            or strings.compare(name, "divmod") == 0 or strings.compare(name, "swap") == 0
    }

    const ubyte SF_ASM_LOOKED = 32      ; the assembly was searched for the variable's name
    const ubyte SF_ASM_NAMED = 64       ; and has it

    ; Is this variable written nowhere: not by a statement, not through its address,
    ; and not named in any assembly?
    sub never_written(^^symtab.Sym s) -> bool {
        if (s.flags & SF_WRITTEN) != 0
            return false
        if (s.flags & SF_ASM_LOOKED) == 0 {
            s.flags |= SF_ASM_LOOKED
            if named_in_assembly(s.name)
                s.flags |= SF_ASM_NAMED
        }
        return (s.flags & SF_ASM_NAMED) == 0
    }

    sub set_written(^^ast.Node t) {
        if t != 0 and t.kind == ast.N_IDENT and t.extra != 0 {
            ^^symtab.Sym s = t.extra
            s.flags |= SF_WRITTEN
        }
    }

    ; the variables that an assignment, update, loop, swap or address-of can change
    sub mark_written(^^ast.Node n) {
        while n != 0 {
            when n.kind {
                ast.N_ASSIGN -> {
                    ^^ast.Node t = n.a
                    while t != 0 {
                        set_written(t)
                        t = t.next
                    }
                }
                ast.N_AUGASSIGN, ast.N_INCDEC, ast.N_FOR, ast.N_ADDROF -> set_written(n.a)
                ast.N_SWAP -> {
                    set_written(n.a)
                    set_written(n.b)
                }
                ast.N_CALL, ast.N_CALLSTMT -> {
                    ; the builtins that change an argument where it is
                    ^^ast.Node callee = n.a
                    if n.kind == ast.N_CALLSTMT and callee != 0 and callee.kind == ast.N_CALL
                        callee = callee.a
                    if callee != 0 and callee.kind == ast.N_IDENT and callee.name != 0 and modifies_arguments(callee.name) {
                        ^^ast.Node arg = n.b
                        if n.kind == ast.N_CALLSTMT and n.a != 0 and n.a.kind == ast.N_CALL
                            arg = n.a.b
                        while arg != 0 {
                            set_written(arg)
                            arg = arg.next
                        }
                    }
                }
                ast.N_VARDECL -> {
                    ; several names from one call (uword q, r = divmod(...)) are written by it
                    if n.c != 0 and n.c.next != 0 {
                        ^^ast.Node id = n.c
                        while id != 0 {
                            set_written(id)
                            id = id.next
                        }
                    }
                }
            }
            if n.kind != ast.N_ASM and n.kind != ast.N_EXTSUB {
                mark_written(n.a)
                mark_written(n.b)
                mark_written(n.c)
                mark_written(n.d)
            }
            n = n.next
        }
    }

    ; A constant, or a whole number variable that is never written and starts with one
    ; (const_eval knows both: this is its older name).
    sub constlike_eval(^^ast.Node e) -> bool, quad {
        bool ok
        quad v
        ok, v = const_eval(e)
        return ok, v
    }

    ; The value of a variable that is in effect a constant, as upstream makes it one: a
    ; whole number or boolean with a constant initial value that nothing ever writes,
    ; not @shared and not asked into the zero page.
    sub unwritten_value(^^symtab.Sym s) -> bool, quad {
        if s.kind != symtab.K_VAR or s.decl == 0 or s.decl.kind != ast.N_VARDECL
            return false, 0
        ^^ast.Node d = s.decl
        if d.b == 0 or d.b.kind == ast.N_TUPLE or d.op != 0 or s.type == 0
            return false, 0
        if not types.is_integer(s.type) and s.type != types.T_BOOL
            return false, 0
        ^^ast.Node tag = d.d
        while tag != 0 {
            if tag.kind == ast.N_TAG and tag.name != 0 and (strings.compare(tag.name, "shared") == 0
                    or strings.compare(tag.name, "zp") == 0 or strings.compare(tag.name, "requirezp") == 0)
                return false, 0
            tag = tag.next
        }
        if not never_written(s)
            return false, 0
        bool ok
        quad v
        ok, v = const_eval(d.b)
        return ok, v
    }

    ; Records the %encoding directive of every module as its file's default
    ; encoding, and checks the directive.
    sub module_encodings() {
        ^^importer.Module m = importer.modules
        while m != 0 {
            ^^ast.Node d = m.tree.a
            while d != 0 {
                if d.kind == ast.N_DIRECTIVE and strings.compare(d.name, "encoding") == 0 {
                    ubyte enc = encoding.E_INVALID
                    if d.a != 0 and d.a.next == 0 and d.a.kind == ast.N_IDENT
                        enc = encoding.from_name(d.a.name)
                    if enc == encoding.E_INVALID
                        error(d, "invalid encoding directive, expected one of default, petscii, sc, atascii, iso, iso5, iso16, cp437, kata, c64os")
                    else
                        encoding.file_default[m.file.index as ubyte] = enc
                }
                d = d.next
            }
            m = m.next
        }
    }

    ; Decodes a string or character literal once; a failed one is left
    ; empty so that nothing reports it twice.
    sub decode_literal(^^ast.Node e) {
        if e.extra != 0
            return
        ^^ubyte message = encoding.decode(e)
        if message != 0 {
            error(e, message)
            e.value = 0
            if e.kind == ast.N_STR
                e.extra = mem.alloc(1)
            else
                e.extra = 1
        }
    }

    ; ---- errors ----

    sub error(^^ast.Node at, str message) {
        diag.error_at(source.get(at.file), at.line, at.col, message)
    }

    ; upstream's wording for a value that does not fit its destination
    sub error_mismatch(^^ast.Node at, uword src, uword dst) {
        buf.clear(parser.scratch)
        buf.add_str(parser.scratch, "value type ")
        types.name_into(parser.scratch, src)
        buf.add_str(parser.scratch, " doesn't match target type ")
        types.name_into(parser.scratch, dst)
        buf.add_byte(parser.scratch, 0)
        diag.error_at(source.get(at.file), at.line, at.col, parser.scratch.data)
    }

    ; "message: <from> to <to>"
    sub error_types(^^ast.Node at, str message, uword src, uword dst) {
        buf.clear(parser.scratch)
        buf.add_str(parser.scratch, message)
        buf.add_str(parser.scratch, ": ")
        types.name_into(parser.scratch, src)
        buf.add_str(parser.scratch, " to ")
        types.name_into(parser.scratch, dst)
        diag.error_at(source.get(at.file), at.line, at.col, parser.scratch.data)
    }

    ; ---- pass 1: declarations ----

    sub type_scope(^^symtab.Scope scope) {
        ^^symtab.Sym s = scope.syms
        while s != 0 {
            type_symbol(s)
            if s.inner != 0
                type_scope(s.inner)
            s = s.next
        }
    }

    sub type_symbol(^^symtab.Sym s) {
        if s.type != 0
            return
        ^^ast.Node d = s.decl
        when s.kind {
            symtab.K_VAR, symtab.K_CONST, symtab.K_MEMVAR, symtab.K_FIELD -> {
                if d.kind == ast.N_VARDECL {
                    if d.a != 0
                        s.type = from_type(d.a)
                    ; else: a const without a type, typed from its value in pass 2
                }
                else if d.kind == ast.N_FOR {
                    if d.d != 0 and d.d.kind == ast.N_TYPE
                        s.type = from_type(d.d)
                    ; else: an implicit loop variable, typed from the iterable in pass 2
                }
            }
            symtab.K_PARAM -> {
                s.type = from_type(d.a)
                if s.type == types.T_STR
                    s.type = types.pointer_to(types.T_UBYTE)    ; strings are passed by reference
            }
            symtab.K_SUB -> {
                if d.b != 0 and d.b.op != token.T_KW_VOID
                    s.type = return_type(d.b)
                else
                    s.type = types.T_VOID
            }
            symtab.K_ENUMMEMBER -> {
                ; as wide as its number asks
                s.type = types.T_UBYTE
                quad number = enum_value(d)
                if number > 65535 or number < 0
                    s.type = types.T_LONG
                else if number > 255
                    s.type = types.T_UWORD
            }
            symtab.K_LABEL, symtab.K_BLOCK, symtab.K_STRUCT, symtab.K_ENUM -> s.type = types.T_VOID
        }
    }

    ; The type a TYPE node denotes; cached in the node.
    sub from_type(^^ast.Node t) -> uword {
        if t.type != 0
            return t.type
        uword id
        if t.op == token.T_IDENT {
            if t.extra == 0
                return types.T_UNDEF
            id = types.struct_of(t.extra)
        }
        else
            id = types.from_keyword(t.op)
        if t.flags & ast.F_POINTER != 0
            id = types.pointer_to(id)
        if t.flags & ast.F_EMPTYARRAY != 0
            id = types.array_of(id, 0)
        ^^ast.Node dim = t.a
        if dim != 0 {
            long length = 1
            bool known = true
            bool ok
            quad dv
            while dim != 0 {
                ok, dv = const_eval(dim)
                if ok
                    length *= dv as long
                else
                    known = false
                dim = dim.next
            }
            if not known
                length = 0
            id = types.array_of(id, length)
        }
        t.type = id
        return id
    }

    ; A return type; a str is returned by reference, as a pointer to its bytes.
    sub return_type(^^ast.Node t) -> uword {
        uword id = from_type(t)
        if id == types.T_STR
            return types.pointer_to(types.T_UBYTE)
        return id
    }

    ; The return types of a subroutine as a TYPE list (0 when none).
    ; A number written with the digits of a word is a word, whatever its value: a hex
    ; literal of 3 or 4 digits ($0040), a binary one of 9 to 16.  It is how a program
    ; asks for a word calculation: column * $0040.  (Upstream's rule, measured: 5 or
    ; more hex digits do not make a long, and leading zeros of a decimal number do nothing.)
    sub written_as_word(^^ubyte spelling) -> bool {
        if spelling[0] != '$' and spelling[0] != '%'
            return false
        ubyte digits = 0
        ubyte i = 1
        while spelling[i] != 0 {
            if spelling[i] != '_'
                digits++
            i++
        }
        if spelling[0] == '$'
            return digits == 3 or digits == 4
        return digits >= 9 and digits <= 16
    }

    sub returns_of(^^symtab.Sym s) -> ^^ast.Node {
        if s.kind != symtab.K_SUB
            return 0
        ^^ast.Node r = s.decl.b
        if r != 0 and r.op == token.T_KW_VOID
            return 0
        return r
    }

    ; ---- pass 2: statements ----

    sub statements(^^ast.Node s) {
        while s != 0 {
            statement(s)
            s = s.next
        }
    }

    sub statement(^^ast.Node n) {
        when n.kind {
            ast.N_VARDECL -> vardecl(n)
            ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB -> {
                ^^symtab.Sym saved = current_sub
                current_sub = n.extra
                if n.kind == ast.N_EXTSUB
                    void infer(n.c)
                else
                    statements(n.c)
                current_sub = saved
            }
            ast.N_ENUM -> {
                ^^ast.Node m = n.a
                while m != 0 {
                    void infer(m.a)
                    m = m.next
                }
            }
            ast.N_ASSIGN -> assignment(n)
            ast.N_AUGASSIGN -> {
                uword tt = infer(n.a)
                uword vt = infer(n.b)
                if tt != 0 and not types.is_numeric_or_bool(tt) and not types.is_pointer(tt)
                    error(n, "augmented assignment needs a numeric or pointer target")
                checks++
            }
            ast.N_INCDEC -> {
                uword it = infer(n.a)
                if it != 0 and not types.is_numeric(it) and not types.is_pointer(it)
                    error(n, "++ and -- need a numeric or pointer target")
                checks++
            }
            ast.N_CALLSTMT, ast.N_GOTO -> void infer(n.a)
            ast.N_IF -> {
                condition(n.a)
                statements(n.b)
                statements(n.c)
            }
            ast.N_BRANCH -> {
                statements(n.b)
                statements(n.c)
            }
            ast.N_RETURN -> returnstmt(n)
            ast.N_FOR -> forloop(n)
            ast.N_WHILE -> {
                condition(n.a)
                statements(n.b)
            }
            ast.N_UNTIL -> {
                statements(n.a)
                condition(n.b)
            }
            ast.N_REPEAT, ast.N_UNROLL -> {
                void infer(n.a)
                statements(n.b)
            }
            ast.N_WHEN -> {
                uword wt = infer(n.a)
                ^^ast.Node c = n.b
                while c != 0 {
                    ^^ast.Node v = c.a
                    while v != 0 {
                        void infer(v)
                        v = v.next
                    }
                    statements(c.b)
                    c = c.next
                }
            }
            ast.N_DEFER -> statements(n.a)
            ast.N_SWAP -> {
                void infer(n.a)
                void infer(n.b)
            }
            ast.N_ONGOTO -> {
                void infer(n.a)
                statements(n.c)
            }
        }
    }

    sub condition(^^ast.Node e) {
        uword t = infer(e)
        if t != 0 and t != types.T_BOOL
            error(e, "condition must be a boolean expression")
        checks++
    }

    sub vardecl(^^ast.Node n) {
        ^^symtab.Sym s = n.c.extra
        if s == 0
            return
        if n.b == 0
            return
        uword vt = infer(n.b)
        if n.op == token.T_AMP
            return          ; a memory-mapped variable: the initializer is its address, which the checker checks

        if s.type == 0 {
            ; a const without a declared type takes the type of its value; a whole number
            ; is a long, as upstream has it (its value still goes wherever it fits)
            s.type = vt
            if types.is_integer(vt) and not types.is_pointer(vt)
                s.type = types.T_LONG
            return
        }
        if types.is_array(s.type) {
            ; the initializer fills in an unknown length
            ^^types.Type at = types.get(s.type)
            if at.length == 0 {
                long length = 0
                if n.b.kind == ast.N_ARRAYLIT
                    length = ast.list_length(n.b.a)
                else if n.b.kind == ast.N_STR
                    length = (buf.cstr_len(n.b.name) + 1) as long
                else if n.b.kind == ast.N_RANGE
                    length = range_length(n.b)
                else if vt != 0 and types.is_array(vt) {
                    ^^types.Type vtt = types.get(vt)
                    length = vtt.length
                }
                if length != 0 {
                    s.type = types.array_of(at.elem, length)
                    ; every name of the declaration shares the type
                    ^^ast.Node id = n.c
                    while id != 0 {
                        ^^symtab.Sym s2 = id.extra
                        if s2 != 0
                            s2.type = s.type
                        id = id.next
                    }
                }
            }
            check_array_init(n.b, s.type)
            return
        }
        if n.b.kind == ast.N_TUPLE {
            ; ubyte x, y, z = 1, 2, 3: every name has its own value
            ^^ast.Node tv = n.b.a
            if ast.list_length(tv) != ast.list_length(n.c)
                error(n.b, "number of initialization values does not match number of variables")
            while tv != 0 {
                check_assign(tv, tv.type, s.type)
                tv = tv.next
            }
            return
        }
        declaring = true
        ; (a variable that nothing uses is gone before upstream looks at its value)
        unused_declaration = (s.marks & 1) == 0
        ^^ast.Node utag = n.d
        while utag != 0 {
            if utag.kind == ast.N_TAG and utag.name != 0 and strings.compare(utag.name, "shared") == 0
                unused_declaration = false
            utag = utag.next
        }
        check_assign(n.b, vt, s.type)
        declaring = false
        unused_declaration = false
    }

    ; Each element of an array literal must fit the element type.
    sub check_array_init(^^ast.Node init, uword arraytype) {
        if init.kind == ast.N_STR or init.kind == ast.N_RANGE
            return          ; a string fills a byte array; a range fills an array with its values
        if init.kind == ast.N_BINARY and init.op == token.T_STAR and init.a != 0 and init.a.kind == ast.N_ARRAYLIT {
            ; [6] * 10: the repeated values are the array's elements
            void infer(init)
            check_array_init(init.a, arraytype)
            return
        }
        if init.kind != ast.N_ARRAYLIT {
            uword it = infer(init)
            if it != 0 and it != arraytype and not (types.is_array(it) and types.elem_of(it) == types.elem_of(arraytype))
                error_types(init, "cannot initialize array", it, arraytype)
            return
        }
        uword elem = types.elem_of(arraytype)
        ^^ast.Node e = init.a
        while e != 0 {
            if e.kind == ast.N_ARRAYLIT and types.is_struct(elem) {
                ; a struct value inside an array of struct instances
            }
            else if e.kind == ast.N_ARRAYLIT and types.is_array(elem) {
                check_array_init(e, elem)
            }
            else if e.kind == ast.N_BOOL and types.is_integer(elem) {
                ; true and false are 1 and 0 in a numeric array
            }
            else
                check_assign(e, e.type, elem)
            e = e.next
        }
        checks++
    }

    ; A value of type vt (already inferred, of node v) is stored into type tt.
    ; is this the plain name of a long variable?  (Where addresses are words such a value
    ; does not go into one; an expression of constants that happens to be typed long may.)
    sub long_variable(^^ast.Node v) -> bool {
        if v.kind == ast.N_ADDROF
            return true         ; (the address of something in far memory)
        if v.kind != ast.N_IDENT or v.extra == 0
            return false
        ^^symtab.Sym ls = v.extra
        return (ls.kind == symtab.K_VAR or ls.kind == symtab.K_PARAM) and ls.type == types.T_LONG
    }

    long arg_checked = 0            ; the number of the argument check_assign looks at, or 0

    ; a pointer type's name for a message, a struct with its block as upstream has it: ^^main.Node
    sub pointer_name(uword t) {
        if types.is_pointer(t) and types.is_struct(types.elem_of(t)) {
            ^^types.Type st = types.get(types.elem_of(t))
            ^^symtab.Sym ss = st.strct
            buf.add_str(parser.scratch, "^^")
            if ss != 0 and ss.scope != 0 and ss.scope.owner != 0 and ss.scope.owner.kind == ast.N_BLOCK and ss.scope.owner.name != 0 {
                buf.add_str(parser.scratch, ss.scope.owner.name)
                buf.add_byte(parser.scratch, '.')
            }
            if ss != 0
                buf.add_str(parser.scratch, ss.name)
            return
        }
        types.name_into(parser.scratch, t)
    }

    bool declaring = false      ; check_assign looks at a declaration's first value
    bool returning = false      ; or at a returned value
    bool unused_declaration = false

    sub check_assign(^^ast.Node v, uword vt, uword tt) {
        checks++
        if vt == 0 or tt == 0
            return
        if types.POINTER_SIZE == 2 and tt == types.T_LONG and types.is_pointer(vt) {
            error(v, "cannot use a pointer as a long, a pointer is an unsigned word")
            return
        }
        if v.kind == ast.N_BINARY and (v.op == token.T_AMP or v.op == token.T_PIPE or v.op == token.T_CARET)
            and types.size_of(vt) == types.size_of(tt) and types.is_integer(tt)
            return          ; a bitwise operation between different types of the same size
        if v.kind == ast.N_UNARY and v.op == token.T_TILDE and types.is_integer(vt) and types.is_integer(tt) and types.size_of(vt) == types.size_of(tt) {
            ; an inversion too; of a signed value it is unsigned, as upstream has it
            if types.is_signed(vt) and types.is_signed(tt) and types.size_of(vt) <= 2
                error_mismatch(v, types.unsigned_of(vt), tt)
            return
        }
        if v.kind == ast.N_INT and tt == types.T_BOOL and not unused_declaration and (arg_checked != 0 or returning or not declaring or v.value != 0) {
            ; a number is not a boolean (a declaration may start at 0)
            buf.clear(parser.scratch)
            if arg_checked != 0 {
                buf.add_str(parser.scratch, "argument ")
                buf.add_long(parser.scratch, arg_checked)
                buf.add_str(parser.scratch, " type mismatch, was: ")
                types.name_into(parser.scratch, types.literal_type(v.value))
                buf.add_str(parser.scratch, " expected: bool")
            }
            else if returning {
                buf.add_str(parser.scratch, "return value type ")
                types.name_into(parser.scratch, types.literal_type(v.value))
                buf.add_str(parser.scratch, " doesn't match subroutine return type bool")
            }
            else {
                buf.add_str(parser.scratch, "value type ")
                types.name_into(parser.scratch, types.literal_type(v.value))
                buf.add_str(parser.scratch, " doesn't match target type bool")
            }
            buf.add_byte(parser.scratch, 0)
            diag.error_at(source.get(v.file), v.line, v.col, parser.scratch.data)
            return
        }
        if v.kind == ast.N_INT and tt == types.T_FLOAT
            v.flags |= AS_FLOAT
        if v.kind == ast.N_INT {
            if types.POINTER_SIZE == 2 and types.is_pointer(tt) and (v.value > 65535 or v.value < 0) {
                error(v, "address out of range")
                return
            }
            if not literal_fits(v.value, tt) {
                if types.is_numeric(tt) {
                    buf.clear(parser.scratch)
                    buf.add_str(parser.scratch, "value out of range for ")
                    types.name_into(parser.scratch, tt)
                    diag.error_at(source.get(v.file), v.line, v.col, parser.scratch.data)
                }
                else if not types.is_address(tt)
                    error_mismatch(v, vt, tt)
            }
            return
        }
        if v.kind == ast.N_ARRAYLIT and types.is_array(tt) {
            check_array_init(v, tt)
            return
        }
        if v.kind == ast.N_STRUCTINIT or v.kind == ast.N_ARRAYLIT {
            return          ; struct values: checked against the fields later
        }
        if vt == tt or types.assignable(vt, tt)
            return
        ; a str holds an address: a string pointer or an address goes in (a str variable itself can't be reassigned; checked elsewhere)
        if tt == types.T_STR and (types.is_address(vt) or vt == types.T_UWORD or vt == types.T_LONG or (types.is_array(vt) and types.elem_of(vt) == types.T_UBYTE))
            return
        ; an array or string is passed by reference: its address goes into an address or a pointer to its elements
        if types.is_array(vt) {
            if types.is_address(tt) or tt == types.T_UWORD or tt == types.T_LONG
                return
            if types.is_pointer(tt) and types.elem_of(tt) == types.elem_of(vt)
                return
            if types.is_pointer(tt) and types.elem_of(tt) == types.T_UBYTE and types.elem_of(vt) == types.T_BOOL
                return
        }
        ; a string goes where an array of bytes is expected (a parameter), by its address
        if vt == types.T_STR and types.is_array(tt) and types.elem_of(tt) == types.T_UBYTE
            return
        ; a pointer to bytes takes a pointer to pointers
        if types.is_pointer(tt) and types.is_pointer(vt) and types.elem_of(tt) == types.T_UBYTE and types.is_pointer(types.elem_of(vt))
            return
        ; the untyped address type takes any pointer or address-sized integer
        if tt == types.ADDRESS_TYPE and (types.is_pointer(vt) or vt == types.T_UWORD or (vt == types.T_LONG and (types.POINTER_SIZE > 2 or not long_variable(v))))
            return
        ; typed pointers to different things do not go into each other
        if types.is_pointer(tt) and types.is_pointer(vt) and tt != types.ADDRESS_TYPE and vt != types.ADDRESS_TYPE {
            buf.clear(parser.scratch)
            if arg_checked != 0 {
                buf.add_str(parser.scratch, "argument ")
                buf.add_long(parser.scratch, arg_checked)
                buf.add_str(parser.scratch, " type mismatch, was: ")
                pointer_name(vt)
                buf.add_str(parser.scratch, " expected: ")
                pointer_name(tt)
            }
            else {
                buf.add_str(parser.scratch, "cannot assign different pointer type, expected ")
                pointer_name(tt)
                buf.add_str(parser.scratch, " or uword but got ")
                pointer_name(vt)
            }
            buf.add_byte(parser.scratch, 0)
            diag.error_at(source.get(v.file), v.line, v.col, parser.scratch.data)
            return
        }
        ; a typed pointer takes the same pointer type (checked above) or an untyped address
        if types.is_pointer(tt) and (vt == types.ADDRESS_TYPE or vt == types.T_UWORD or (vt == types.T_LONG and types.POINTER_SIZE > 2))
            return
        if types.is_pointer(vt) and tt == types.T_UWORD
            return
        error_mismatch(v, vt, tt)
    }

    ; True when the literal value is representable in the type (or the type isn't numeric).
    ; the first numbers in the program that need more than 32 bits; one that is a
    ; floating point value where it stands (float f = 5000000000) is marked AS_FLOAT
    const ubyte WIDE_MAX = 16
    ^^pointer wide_literals = 0         ; (WIDE_MAX of them, allocated when the first is met)
    ubyte wide_count = 0
    const ubyte AS_FLOAT = ast.F_VOID       ; (a flag that means nothing else on a number)

    sub wide_integer() -> ^^ast.Node {
        ubyte wk = 0
        while wk < wide_count {
            ^^ast.Node wn = wide_literals[wk]
            if (wn.flags & AS_FLOAT) == 0
                return wn
            wk++
        }
        return 0
    }

    bool sizing = false         ; inside sizeof(): a name has its declared type

    ; The number that a directive is given: written out, or the name of a constant (which
    ; nothing has looked up yet where it stands in a directive).  For %overlay.
    sub directive_number(^^ast.Node arg) -> bool, quad {
        if arg == 0
            return false, 0
        if arg.kind == ast.N_IDENT and arg.extra == 0 and arg.name != 0 {
            ^^symtab.Sym s = resolver.lookup_name(arg.name, arg)
            if s == 0 or s.kind != symtab.K_CONST or s.decl == 0 or s.decl.b == 0
                return false, 0
            bool ok
            quad v
            ok, v = const_eval(s.decl.b)
            return ok, v
        }
        bool ok2
        quad v2
        ok2, v2 = const_eval(arg)
        return ok2, v2
    }

    ; the name of a memory mapped variable at an address of more than 16 bits, on a
    ; machine with far memory
    sub far_memvar(^^ast.Node e) -> bool {
        if e == 0 or e.kind != ast.N_IDENT or e.extra == 0 or types.far_bits == 0
            return false
        ^^symtab.Sym s = e.extra
        if s.kind != symtab.K_MEMVAR or s.decl == 0 or s.decl.kind != ast.N_VARDECL or s.decl.b == 0
            return false
        bool ok
        quad v
        ok, v = const_eval(s.decl.b)
        return ok and v > 65535
    }

    sub literal_fits(quad value, uword t) -> bool {
        when t {
            types.T_BOOL -> return value == 0 or value == 1
            types.T_UBYTE -> return value >= 0 and value <= 255
            types.T_BYTE -> return value >= -128 and value <= 127
            types.T_UWORD -> return value >= 0 and value <= 65535
            types.T_WORD -> return value >= -32768 and value <= 32767
            types.T_LONG -> return value >= -4294967295 and value <= 4294967295       ; a 32-bit pattern is a long too, whichever way it is written
            types.T_UQUAD -> return true
            types.T_QUAD, types.T_FLOAT -> return true
            else -> return true
        }
    }

    sub assignment(^^ast.Node n) {
        ^^ast.Node value = n.b
        ; a chain a = b = c: the inner assignment's value is the value
        while value.kind == ast.N_ASSIGN {
            assignment(value)
            value = value.b
        }
        uword vt = 0
        if value.kind != ast.N_ASSIGN
            vt = infer(value)
        ^^ast.Node target = n.a
        if target.next == 0 {
            uword tt = infer(target)
            if target.kind == ast.N_INDEX and types.is_integer(vt) and types.is_integer(tt) and types.size_of(vt) == types.size_of(tt)
                return          ; upstream lets an integer of the same size into an array element
            ; (a signed byte's number goes into memory as it is: @(address) = -100)
            if target.kind == ast.N_MEMREAD and value.kind == ast.N_INT and value.value < 0 and value.value >= -128
                return
            if target.kind != ast.N_VOID
                check_assign(value, vt, tt)
            return
        }
        ; several targets: the values of a tuple, or the results of a call
        ^^ast.Node rtype = 0
        ^^ast.Node tuple = 0
        if value.kind == ast.N_TUPLE
            tuple = value.a
        else if value.kind == ast.N_CALL and value.a.extra != 0
            rtype = returns_of(value.a.extra)
        while target != 0 {
            uword tt2 = infer(target)
            if tuple != 0 {
                if target.kind != ast.N_VOID
                    check_assign(tuple, tuple.type, tt2)
                tuple = tuple.next
            }
            else if rtype != 0 {
                if target.kind != ast.N_VOID
                    check_assign(value, return_type(rtype), tt2)
                rtype = rtype.next
            }
            target = target.next
        }
    }

    sub returnstmt(^^ast.Node n) {
        ^^ast.Node r = 0
        if current_sub != 0
            r = returns_of(current_sub)
        ^^ast.Node v = n.a
        while v != 0 {
            uword vt = infer(v)
            if r == 0 {
                ; ("return other()" where neither returns anything is a call and a return)
                bool call_of_nothing = v.kind == ast.N_CALL and v == n.a and v.next == 0 and (vt == 0 or vt == types.T_VOID)
                if current_sub != 0 and not call_of_nothing
                    error(v, "too many return values")
            }
            else {
                returning = true
                check_assign(v, vt, return_type(r))
                returning = false
                r = r.next
            }
            v = v.next
        }
        if r != 0 and n.a == 0 and current_sub != 0 and current_sub.decl.kind == ast.N_SUB
            error(n, "return value expected")
        else if r != 0 and n.a != 0 and not (n.a.next == 0 and n.a.kind == ast.N_CALL) {
            ; (a single call may pass on the values of a subroutine with several)
            long expected = ast.list_length(returns_of(current_sub))
            buf.clear(parser.scratch)
            buf.add_str(parser.scratch, "too few return values for the subroutine: expected ")
            buf.add_long(parser.scratch, expected)
            buf.add_str(parser.scratch, " got ")
            buf.add_long(parser.scratch, ast.list_length(n.a))
            buf.add_byte(parser.scratch, 0)
            error(n, parser.scratch.data)
        }
    }

    sub forloop(^^ast.Node n) {
        ^^ast.Node opt = n.d
        if opt != 0 and opt.kind == ast.N_TYPE
            opt = opt.next
        uword it = infer(n.b)
        ^^symtab.Sym lv = n.a.extra
        if lv != 0 and lv.type == 0 {
            ; an implicit loop variable takes the element type of what it iterates over
            if n.b.kind == ast.N_RANGE
                lv.type = it
            else if types.is_iterable(it)
                lv.type = types.index_elem(it)
            else if types.is_pointer(it)
                lv.type = it            ; a linked list walk
            else
                lv.type = it
        }
        n.a.type = lv.type
        while opt != 0 {
            if opt.op != token.T_KW_VIA
                void infer(opt.a)
            opt = opt.next
        }
        statements(n.c)
    }

    ; ---- expressions ----

    ; "abc" * 3 and "abc" + "def" are string literals: the node becomes one
    sub fold_string(^^ast.Node e) {
        if e.kind != ast.N_BINARY or e.a == 0 or e.b == 0
            return
        if e.a.kind == ast.N_BINARY
            fold_string(e.a)
        if e.b.kind == ast.N_BINARY
            fold_string(e.b)
        if e.a.kind != ast.N_STR
            return
        ^^ubyte made = 0
        long total = 0
        long first
        if e.op == token.T_STAR {
            bool ok
            quad times
            ok, times = const_eval(e.b)
            if not ok or times < 0
                return
            decode_literal(e.a)
            first = e.a.value as long
            total = first * (times as long)
            if total > 255 {
                error(e, "string length must be 0-255")
                return
            }
            made = mem.alloc(total + 1)
            long k = 0
            while k < total {
                mem.copy(e.a.extra, made + k, first)
                k += first
            }
        }
        else if e.op == token.T_PLUS and e.b.kind == ast.N_STR {
            decode_literal(e.a)
            decode_literal(e.b)
            first = e.a.value as long
            total = first + (e.b.value as long)
            if total > 255 {
                error(e, "string length must be 0-255")
                return
            }
            made = mem.alloc(total + 1)
            mem.copy(e.a.extra, made, first)
            mem.copy(e.b.extra, made + first, e.b.value as long)
        }
        else
            return
        e.kind = ast.N_STR
        e.name = e.a.name
        e.extra = made
        e.value = total
        e.a = 0
        e.b = 0
        e.c = 0
        e.op = 0
    }

    sub infer(^^ast.Node e) -> uword {
        if e == 0
            return 0
        if e.kind == ast.N_BINARY and e.a != 0 and (e.a.kind == ast.N_STR or e.a.kind == ast.N_BINARY)
            fold_string(e)
        uword t = infer_kind(e)
        e.type = t
        if t == 0
            unknown++
        else {
            typed++
            fold(e)
            t = e.type          ; folding may have narrowed it
        }
        return t
    }

    ; ---- constant folding ----

    long folded = 0

    ; Replaces a constant expression by its value, keeping the expression's type.
    sub fold(^^ast.Node e) {
        ubyte k = e.kind
        if k != ast.N_BINARY and k != ast.N_UNARY and k != ast.N_IDENT and k != ast.N_CAST and k != ast.N_SIZEOF and k != ast.N_CALL
            return
        if k == ast.N_IDENT {
            ^^symtab.Sym s = e.extra
            if s == 0 or (s.kind != symtab.K_CONST and s.kind != symtab.K_ENUMMEMBER)
                return
        }
        bool ok
        quad value
        if k == ast.N_CAST and e.a != 0 and e.a.kind == ast.N_INT and e.type != 0 and types.is_integer(e.type) {
            ; a constant that needs more bytes than the type has is not cut down by a cast
            quad cv = e.a.value
            ubyte needs = 4
            if cv >= -128 and cv <= 255
                needs = 1
            else if cv >= -32768 and cv <= 65535
                needs = 2
            if types.size_of(e.type) < needs {
                buf.clear(parser.scratch)
                buf.add_str(parser.scratch, "no cast available from ")
                if needs == 4
                    buf.add_str(parser.scratch, "LONG")
                else if cv < 0
                    buf.add_str(parser.scratch, "WORD")
                else
                    buf.add_str(parser.scratch, "UWORD")
                buf.add_str(parser.scratch, " to ")
                when e.type {
                    types.T_UBYTE -> buf.add_str(parser.scratch, "UBYTE")
                    types.T_BYTE -> buf.add_str(parser.scratch, "BYTE")
                    types.T_UWORD -> buf.add_str(parser.scratch, "UWORD")
                    types.T_WORD -> buf.add_str(parser.scratch, "WORD")
                    else -> types.name_into(parser.scratch, e.type)
                }
                buf.add_str(parser.scratch, " for value ")
                buf.add_long(parser.scratch, cv as long)
                buf.add_str(parser.scratch, ".0")
                buf.add_byte(parser.scratch, 0)
                error(e, parser.scratch.data)
                return
            }
        }
        if k == ast.N_CAST and e.a != 0 and e.a.type == types.T_FLOAT and e.type != 0 and types.is_integer(e.type) and types.size_of(e.type) <= 2 and float_eval(e.a) {
            ; a floating point constant outside the type's range
            float fv = float_value
            float flo = 0.0
            float fhi = 255.0
            when e.type {
                types.T_BYTE -> {
                    flo = -128.0
                    fhi = 127.0
                }
                types.T_UWORD -> fhi = 65535.0
                types.T_WORD -> {
                    flo = -32768.0
                    fhi = 32767.0
                }
            }
            if fv < flo or fv >= fhi + 1.0 {
                buf.clear(parser.scratch)
                buf.add_str(parser.scratch, "no cast available from FLOAT to ")
                when e.type {
                    types.T_UBYTE -> buf.add_str(parser.scratch, "UBYTE")
                    types.T_BYTE -> buf.add_str(parser.scratch, "BYTE")
                    types.T_UWORD -> buf.add_str(parser.scratch, "UWORD")
                    else -> buf.add_str(parser.scratch, "WORD")
                }
                buf.add_str(parser.scratch, " for value ")
                if fv < 0.0 {
                    buf.add_byte(parser.scratch, '-')
                    fv = 0.0 - fv
                }
                long whole = fv as long
                buf.add_long(parser.scratch, whole)
                buf.add_byte(parser.scratch, '.')
                ; (the fraction as it is written out, to six places without the zeros at the end)
                long frac = ((fv - (whole as float)) * 1000000.0 + 0.5) as long
                if frac == 0
                    buf.add_byte(parser.scratch, '0')
                else {
                    long scale = 100000
                    while frac != 0 and scale != 0 {
                        buf.add_byte(parser.scratch, '0' + (frac / scale) as ubyte)
                        frac = frac % scale
                        scale /= 10
                    }
                }
                buf.add_byte(parser.scratch, 0)
                error(e, parser.scratch.data)
                return
            }
        }
        ok, value = const_eval(e)
        if not ok
            return
        if not types.is_integer(e.type) and e.type != types.T_BOOL
            return
        if (k == ast.N_CALL or k == ast.N_SIZEOF) and e.type != types.T_BOOL
            e.type = types.literal_type(value)      ; a builtin's constant result takes the smallest type, as upstream does
        else if k == ast.N_BINARY and (e.op == token.T_AMP or e.op == token.T_PIPE or e.op == token.T_CARET) and value < 0
                and e.a != 0 and e.b != 0 and types.is_integer(e.a.type) and types.is_integer(e.b.type)
                and types.size_of(e.a.type) <= 2 and types.size_of(e.b.type) <= 2 {
            ; bits have no sign: of signed bytes or words the result is the unsigned pattern
            if types.size_of(e.a.type) == 2 or types.size_of(e.b.type) == 2 {
                value &= $ffff
                e.type = types.T_UWORD
            }
            else {
                value &= $ff
                e.type = types.T_UBYTE
            }
        }
        else if (k == ast.N_BINARY or k == ast.N_UNARY) and types.is_integer(e.type) {
            ; folded arithmetic takes the larger of its own type and the
            ; smallest type holding the value, as upstream does (so
            ; len(x) * sizeof(pointer) is not a byte even when both are)
            uword optimal = types.literal_type(value)
            if types.size_of(optimal) > types.size_of(e.type)
                e.type = optimal
            else if value < 0 and not types.is_signed(e.type)
                e.type = types.signed_of(e.type)
        }
        e.kind = ast.N_INT
        if e.type == types.T_BOOL
            e.kind = ast.N_BOOL         ; (so that it is still a boolean when it is looked at again)
        e.value = value
        e.a = 0
        e.b = 0
        e.c = 0
        e.op = 0
        buf.clear(parser.scratch)
        buf.add_quad(parser.scratch, value)
        e.name = strtab.intern(parser.scratch.data, parser.scratch.len as uword)
        folded++
    }

    ; The value of a constant integer expression, when it is one.
    sub const_eval(^^ast.Node e) -> bool, quad {
        bool ok
        quad a
        quad b
        when e.kind {
            ast.N_INT -> return true, e.value
            ast.N_BOOL -> return true, e.value
            ast.N_ADDROF -> {
                ; The address of a memory-mapped variable is its constant; a constant that is
                ; indexed is an address itself.  With a constant index, the element's address.
                if e.op != token.T_AMP
                    return false, 0
                bool aok = false
                quad base = 0
                quad esize = 1
                if e.a.kind == ast.N_IDENT {
                    ^^symtab.Sym ms = e.a.extra
                    if ms == 0
                        return false, 0
                    if ms.kind == symtab.K_MEMVAR and ms.decl.b != 0 {
                        aok, base = const_eval(ms.decl.b)
                        if types.is_array(ms.type)
                            esize = types.size_of(types.index_elem(ms.type))
                    }
                    else if ms.kind == symtab.K_CONST and e.b != 0 {
                        aok, base = const_eval(e.a)
                        if types.is_pointer(ms.type)
                            esize = types.size_of(types.index_elem(ms.type))
                    }
                }
                else if e.b != 0
                    aok, base = const_eval(e.a)
                if not aok
                    return false, 0
                if e.b == 0
                    return true, base
                bool iok
                quad index
                iok, index = const_eval(e.b)
                if not iok
                    return false, 0
                if esize == 0
                    esize = 1
                return true, base + index * esize
            }
            ast.N_CHAR -> {
                decode_literal(e)
                return true, e.value
            }
            ast.N_IDENT -> {
                ^^symtab.Sym s = e.extra
                if s == 0
                    return false, 0
                if s.kind == symtab.K_CONST {
                    ^^ast.Node d = s.decl
                    if d.b == 0 or d.b.kind == ast.N_TUPLE
                        return false, 0
                    if d.b.kind != ast.N_INT and d.b.type == 0
                        void infer(d.b)          ; a constant declared later in the file
                    ; (its value may be a variable that is never written: upstream makes
                    ; such a variable a constant)
                    return const_eval(d.b)
                }
                if s.kind == symtab.K_ENUMMEMBER
                    return true, enum_value(s.decl)
                if s.kind == symtab.K_VAR and writes_known {
                    ok, a = unwritten_value(s)
                    return ok, a
                }
                return false, 0
            }
            ast.N_IFEXPR -> {
                ; if condition value else value, the condition a constant
                ok, a = const_eval(e.a)
                if not ok
                    return false, 0
                if a != 0
                    return const_eval(e.b)
                return const_eval(e.c)
            }
            ast.N_UNARY -> {
                ok, a = const_eval(e.a)
                if not ok
                    return false, 0
                if e.op == token.T_MINUS
                    return true, 0 - a
                if e.op == token.T_PLUS
                    return true, a
                if e.op == token.T_TILDE {
                    ; all the bits of the operand's own width: ~7 is 248
                    uword ot = e.a.type
                    if ot == 0 or not types.is_integer(ot)
                        ot = types.literal_type(a)
                    when types.size_of(ot) {
                        1 -> return true, ((~a) & $ff) as quad
                        2 -> return true, ((~a) & $ffff) as quad
                        4 -> {
                            if not types.is_signed(ot)
                                return true, ((~a) & $ffffffff) as quad
                        }
                    }
                    return true, (~a) as quad
                }
                if e.op == token.T_KW_NOT
                    return true, (a == 0) as quad
                return false, 0
            }
            ast.N_BINARY -> {
                ok, a = const_eval(e.a)
                if not ok
                    return false, 0
                ; (and/or stop at a first operand that decides: the second is not looked at,
                ; so it does not have to be a constant)
                if e.op == token.T_KW_AND and a == 0
                    return true, 0
                if e.op == token.T_KW_OR and a != 0
                    return true, 1
                ok, b = const_eval(e.b)
                if not ok
                    return false, 0
                return binary_const(e.op, a, b)
            }
            ast.N_CAST -> {
                ok, a = const_eval(e.a)
                if not ok {
                    ; a constant float made an integer: its whole part
                    uword into = from_type(e.b)
                    if into != types.T_FLOAT and types.is_integer(into) and (e.a.kind == ast.N_FLOAT or e.a.type == types.T_FLOAT) and float_eval(e.a) {
                        if float_value < 0.0
                            a = 0 - ((0.0 - float_value) as quad)
                        else
                            a = float_value as quad
                        return true, truncate(a, into)
                    }
                    return false, 0
                }
                return true, truncate(a, from_type(e.b))
            }
            ast.N_SIZEOF -> {
                if e.op == 1 {
                    ; offsetof: the sizes of the fields before this one (none in a union)
                    ^^symtab.Sym field = e.a.extra
                    if field == 0
                        return false, 0
                    ^^symtab.Scope fsc = field.scope
                    if fsc.owner != 0 and fsc.owner.kind == ast.N_UNION
                        return true, 0
                    quad before = 0
                    ^^symtab.Sym fs = fsc.syms
                    while fs != 0 and fs != field {
                        if fs.type != 0
                            before += types.size_of(fs.type)
                        fs = fs.next
                    }
                    return true, before
                }
                if e.a.kind == ast.N_TYPE
                    return true, types.size_of(from_type(e.a))
                if e.a.kind == ast.N_ADDROF
                    return true, types.POINTER_SIZE
                ^^symtab.Sym ss = e.a.extra
                if ss == 0
                    return false, 0
                if ss.kind == symtab.K_STRUCT
                    return true, types.struct_size(ss)
                if ss.type == types.T_STR and ss.kind == symtab.K_VAR and known_length(e.a) != 0
                    return true, known_length(e.a) + 1      ; (a string variable: its bytes, the zero too)
                if ss.type != 0
                    return true, types.size_of(ss.type)
                return false, 0
            }
            ast.N_CALL -> {
                ^^symtab.Sym cs = e.a.extra
                if e.a != 0 and e.a.kind == ast.N_IDENT and e.a.name != 0 and e.b != 0 and cs != 0 and cs.kind == symtab.K_SUB {
                    if buf.bytes_equal(e.a.name, "math.", 5) {
                        ok, a = library_const(e.a.name + 5, e.b)
                        return ok, a
                    }
                    if strings.compare(e.a.name, "strings.isdigit") == 0 {
                        ok, a = const_eval(e.b)
                        if ok
                            return true, (a >= 48 and a <= 57) as quad
                        return false, 0
                    }
                }
                if cs == 0 or cs.kind != symtab.K_BUILTIN or e.b == 0
                    return false, 0
                if cs.name == builtin_interned[15] {
                    ; len() of an array or string of known length
                    long length = known_length(e.b)
                    if length == 0
                        return false, 0
                    return true, length
                }
                return builtin_const(cs.name, e.b)
            }
            else -> return false, 0
        }
    }

    ; The value of a constant floating point expression: true and the value
    ; in float_value.  (It started as a workaround for bugs/multi_return_float.p8,
    ; since fixed; it stays because the callers read better with a plain bool.)
    float float_value = 0.0

    sub float_eval(^^ast.Node e) -> bool {
        bool ok
        float a
        quad q
        when e.kind {
            ast.N_FLOAT -> {
                ; the spelling without the digit group underscores
                buf.clear(parser.scratch)
                long i = 0
                while e.name[i] != 0 {
                    if e.name[i] != '_'
                        buf.add_byte(parser.scratch, e.name[i])
                    i++
                }
                buf.add_byte(parser.scratch, 0)
                float_value = float_platform.parse(parser.scratch.data)
                return true
            }
            ast.N_INT, ast.N_BOOL, ast.N_CHAR -> {
                ok, q = const_eval(e)
                if ok {
                    float_value = q as float
                    return true
                }
                return false
            }
            ast.N_IDENT -> {
                ^^symtab.Sym s = e.extra
                if s != 0 and s.kind == symtab.K_CONST and s.decl.b != 0 and s.decl.b.kind != ast.N_TUPLE
                    return float_eval(s.decl.b)
                return false
            }
            ast.N_UNARY -> {
                if not float_eval(e.a)
                    return false
                if e.op == token.T_MINUS {
                    float_value = -float_value
                    return true
                }
                if e.op == token.T_PLUS
                    return true
                return false
            }
            ast.N_BINARY -> {
                if not float_eval(e.a)
                    return false
                a = float_value
                if not float_eval(e.b)
                    return false
                when e.op {
                    token.T_PLUS -> float_value = a + float_value
                    token.T_MINUS -> float_value = a - float_value
                    token.T_STAR -> float_value = a * float_value
                    token.T_SLASH -> float_value = a / float_value
                    else -> return false
                }
                return true
            }
            ast.N_CAST -> return float_eval(e.a)
            ast.N_CALL -> {
                ; a floats library function of constants, which upstream evaluates too
                if e.a == 0 or e.a.kind != ast.N_IDENT or not buf.bytes_equal(e.a.name, "floats.", 7)
                    return false
                float fa = 0.0
                float fb = 0.0
                float fc = 0.0
                ubyte fn = 0
                ^^ast.Node farg = e.b
                while farg != 0 {
                    if not float_eval(farg)
                        return false
                    when fn {
                        0 -> fa = float_value
                        1 -> fb = float_value
                        2 -> fc = float_value
                        else -> return false
                    }
                    fn++
                    farg = farg.next
                }
                if fn == 0 or not float_platform.evaluate(e.a.name + 7, fa, fb, fc)
                    return false
                float_value = float_platform.result
                return true
            }
        }
        return false
    }

    ; The math library's functions of constants that upstream evaluates when it compiles:
    ; the sines and cosines of the 256 (or, with an r, 180) step circle, log2, diff.
    sub library_const(^^ubyte name, ^^ast.Node args) -> bool, quad {
        bool ok
        quad x
        quad y
        ok, x = const_eval(args)
        if not ok
            return false, 0
        if strings.compare(name, "diff") == 0 or strings.compare(name, "diffw") == 0 {
            if args.next == 0
                return false, 0
            ok, y = const_eval(args.next)
            if not ok
                return false, 0
            if x > y
                return true, x - y
            return true, y - x
        }
        if strings.compare(name, "atan2") == 0 {
            ; the direction from (x1, y1) to (x2, y2) on the 256 step circle
            quad x2
            quad y2
            if args.next == 0 or args.next.next == 0 or args.next.next.next == 0 or args.next.next.next.next != 0
                return false, 0
            ok, y = const_eval(args.next)
            if not ok
                return false, 0
            ok, x2 = const_eval(args.next.next)
            if not ok
                return false, 0
            ok, y2 = const_eval(args.next.next.next)
            if not ok
                return false, 0
            float dx = (x2 - x) as float
            float dy = (y2 - y) as float
            float radians = 0.0
            if dx == 0.0 {
                if dy > 0.0
                    radians = 3.141592653589793 / 2.0
                else if dy < 0.0
                    radians = 3.141592653589793 * 1.5
            }
            else {
                if not float_platform.evaluate("atan", dy / dx, 0.0, 0.0)
                    return false, 0
                radians = float_platform.result
                if dx < 0.0
                    radians += 3.141592653589793
                else if radians < 0.0
                    radians += 2.0 * 3.141592653589793
            }
            quad step = (radians / 2.0 / 3.141592653589793 * 256.0) as quad
            if step < 0 or step > 255
                return false, 0
            return true, step
        }
        if args.next != 0
            return false, 0
        if strings.compare(name, "log2") == 0 or strings.compare(name, "log2w") == 0 {
            if x <= 0
                return false, 0
            quad bits = 0
            while x > 1 {
                x >>= 1
                bits++
            }
            return true, bits
        }
        ; sin8u cos8u sin8 cos8 sinr8u cosr8u sinr8 cosr8
        bool cosine = name[0] == 'c'
        if not ((name[0] == 's' and name[1] == 'i' and name[2] == 'n') or (cosine and name[1] == 'o' and name[2] == 's'))
            return false, 0
        float steps = 256.0
        ubyte at = 3
        if name[at] == 'r' {
            steps = 180.0
            at++
        }
        if name[at] != '8'
            return false, 0
        bool unsigned = name[at + 1] == 'u'
        if (unsigned and name[at + 2] != 0) or (not unsigned and name[at + 1] != 0)
            return false, 0
        float angle = (x as float) / steps * 2.0 * 3.141592653589793
        ^^ubyte fname = "sin"
        if cosine
            fname = "cos"
        if not float_platform.evaluate(fname, angle, 0.0, 0.0)
            return false, 0
        float wave = float_platform.result
        if unsigned
            wave = 128.0 + 127.5 * wave
        else
            wave = 127.0 * wave
        ; (towards zero)
        if wave < 0.0
            return true, 0 - ((0.0 - wave) as quad)
        return true, wave as quad
    }

    ; msb, lsb, msw, lsw, mkword and mklong2 of constant arguments
    sub builtin_const(^^ubyte name, ^^ast.Node args) -> bool, quad {
        bool ok
        quad a
        quad b
        ok, a = const_eval(args)
        if not ok
            return false, 0
        if name == builtin_interned[22]         ; lsb
            return true, (a & $ff) as quad
        if name == builtin_interned[23]         ; msb
            return true, ((a >> 8) & $ff) as quad
        if name == builtin_interned[24]         ; lsw
            return true, (a & $ffff) as quad
        if name == builtin_interned[25]         ; msw
            return true, ((a >> 16) & $ffff) as quad
        if args.next == 0
            return false, 0
        ok, b = const_eval(args.next)
        if not ok
            return false, 0
        if name == builtin_interned[26]         ; mkword(msb, lsb)
            return true, (((a & $ff) << 8) | (b & $ff)) as quad
        if name == builtin_interned[28]         ; mklong2(msw, lsw)
            return true, (((a & $ffff) << 16) | (b & $ffff)) as quad
        return false, 0
    }

    sub binary_const(ubyte op, quad a, quad b) -> bool, quad {
        when op {
            token.T_PLUS -> return true, a + b
            token.T_MINUS -> return true, a - b
            token.T_STAR -> return true, a * b
            token.T_SLASH -> {
                if b == 0
                    return false, 0
                return true, a / b
            }
            token.T_PERCENT -> {
                if b == 0
                    return false, 0
                return true, a % b
            }
            token.T_AMP -> return true, (a & b) as quad
            token.T_PIPE -> return true, (a | b) as quad
            token.T_CARET -> return true, (a ^ b) as quad
            token.T_SHL -> return true, a << b
            token.T_SHR -> return true, a >> b
            token.T_EQ -> return true, (a == b) as quad
            token.T_NE -> return true, (a != b) as quad
            token.T_LT -> return true, (a < b) as quad
            token.T_GT -> return true, (a > b) as quad
            token.T_LE -> return true, (a <= b) as quad
            token.T_GE -> return true, (a >= b) as quad
            token.T_KW_AND -> return true, (a != 0 and b != 0) as quad
            token.T_KW_OR -> return true, (a != 0 or b != 0) as quad
            token.T_KW_XOR -> return true, ((a != 0) xor (b != 0)) as quad
            else -> return false, 0
        }
    }

    ; the value as stored in the type (wrapping like a cast does)
    sub truncate(quad value, uword t) -> quad {
        when t {
            types.T_UBYTE -> return (value & $ff) as quad
            types.T_BYTE -> return (((value & $ff) ^ $80) as quad) - $80
            types.T_UWORD -> return (value & $ffff) as quad
            types.T_WORD -> return (((value & $ffff) ^ $8000) as quad) - $8000
            types.T_LONG -> return (((value & $ffff_ffff) ^ $8000_0000) as quad) - $8000_0000
            types.T_BOOL -> return (value != 0) as quad
            else -> return value
        }
    }

    ; An enum member's value: explicit, or one more than the previous member's.
    sub enum_value(^^ast.Node member) -> quad {
        ^^ast.Node en = member.extra
        ; walk the enum's members from the start, numbering as we go
        ^^symtab.Sym ms = member.extra
        ^^symtab.Scope members = ms.scope
        ^^ast.Node enumdecl = members.owner
        quad value = 0
        bool ok
        quad explicit
        ^^ast.Node m = enumdecl.a
        while m != 0 {
            if m.a != 0 {
                ok, explicit = const_eval(m.a)
                if ok
                    value = explicit
            }
            if m == member
                return value
            value++
            m = m.next
        }
        return 0
    }

    ; The element count of an array or string expression, or 0 when not known.
    ; how many values a constant range has; 0 when it is not constant
    ; a constant that is a whole number, written as an integer or as a float (1.0 to 3.0
    ; fills an array of floats)
    sub whole_const(^^ast.Node e) -> bool, quad {
        bool ok
        quad v
        ok, v = const_eval(e)
        if ok
            return true, v
        if e != 0 and e.type == types.T_FLOAT and float_eval(e) {
            v = float_value as quad
            if (v as float) == float_value
                return true, v
        }
        return false, 0
    }

    sub range_length(^^ast.Node r) -> long {
        bool ok
        quad from
        quad to_value
        quad stride = 1
        ok, from = whole_const(r.a)
        if not ok
            return 0
        ok, to_value = whole_const(r.b)
        if not ok
            return 0
        if r.c != 0 {
            ok, stride = const_eval(r.c)
            if not ok or stride == 0
                return 0
        }
        else if r.op == token.T_KW_DOWNTO
            stride = -1
        if stride > 0 {
            if to_value < from
                return 0
            return ((to_value - from) / stride + 1) as long
        }
        if from < to_value
            return 0
        return ((from - to_value) / -stride + 1) as long
    }

    sub known_length(^^ast.Node e) -> long {
        if e.kind == ast.N_STR {
            decode_literal(e)
            return e.value as long
        }
        if e.kind == ast.N_BINARY and e.type == types.T_STR {
            ; "abc" * 3 and "abc" + "def"
            long left = known_length(e.a)
            if left == 0
                return 0
            if e.op == token.T_PLUS
                return left + known_length(e.b)
            bool ok
            quad count
            ok, count = const_eval(e.b)
            if ok
                return left * (count as long)
            return 0
        }
        if e.kind == ast.N_IDENT {
            ; a variable, possibly not typed yet: its type's length, else count its initializer
            ^^symtab.Sym s = e.extra
            if s != 0 and s.decl.kind == ast.N_VARDECL {
                if s.type != 0 {
                    ^^types.Type st = types.get(s.type)
                    if st.base == types.T_ARRAY and st.length != 0
                        return st.length
                }
                if s.decl.b != 0 {
                    if s.decl.b.kind == ast.N_STR or s.decl.b.kind == ast.N_BINARY
                        return known_length(s.decl.b)
                    if s.decl.b.kind == ast.N_ARRAYLIT
                        return ast.list_length(s.decl.b.a)
                    if s.decl.b.kind == ast.N_RANGE
                        return range_length(s.decl.b)
                }
            }
        }
        if e.type == 0
            return 0
        ^^types.Type t = types.get(e.type)
        if t.base == types.T_ARRAY and t.length != 0
            return t.length
        return 0
    }

    ; matrix[row][column] of a variable declared with two dimensions becomes
    ; matrix[row * columns + column]: the array is stored flat, row by row
    sub flatten_2d(^^ast.Node e) {
        ^^ast.Node inner = e.a
        if inner == 0 or inner.kind != ast.N_INDEX or inner.a.kind != ast.N_IDENT or inner.a.extra == 0
            return
        ^^symtab.Sym ms = inner.a.extra
        if ms.decl == 0 or ms.decl.kind != ast.N_VARDECL or ms.decl.a == 0
            return
        ^^ast.Node dims = ms.decl.a.a
        if dims == 0 or dims.next == 0
            return
        bool ok
        quad columns
        ok, columns = const_eval(dims.next)
        if not ok
            return
        ^^ast.Node count = mem.alloc(sizeof(ast.Node))
        mem.copy(e, count, sizeof(ast.Node))
        count.kind = ast.N_INT
        count.name = "0"
        count.value = columns
        count.a = 0
        count.b = 0
        count.c = 0
        count.d = 0
        count.next = 0
        count.extra = 0
        count.type = 0
        count.op = 0
        ^^ast.Node scaled = mem.alloc(sizeof(ast.Node))
        mem.copy(count, scaled, sizeof(ast.Node))
        scaled.kind = ast.N_BINARY
        scaled.name = 0
        scaled.value = 0
        scaled.op = token.T_STAR
        scaled.a = inner.b
        scaled.b = count
        ^^ast.Node flat = mem.alloc(sizeof(ast.Node))
        mem.copy(scaled, flat, sizeof(ast.Node))
        flat.op = token.T_PLUS
        flat.a = scaled
        flat.b = e.b
        e.a = inner.a
        e.b = flat
    }

    sub infer_kind(^^ast.Node e) -> uword {
        when e.kind {
            ast.N_INT -> {
                if e.name != 0 and (e.value > 4294967295 or e.value < -4294967296) and wide_count < WIDE_MAX {
                    ; (for the checker: not every target has 64 bits)
                    if wide_literals == 0
                        wide_literals = mem.alloc(WIDE_MAX as long * sizeof(pointer))
                    ubyte wk = 0
                    while wk < wide_count and wide_literals[wk] != e
                        wk++
                    if wk == wide_count {
                        wide_literals[wide_count] = e
                        wide_count++
                    }
                }
                if e.name[0] == '$' or e.name[0] == '%'
                    if e.value < 0
                        return types.T_UQUAD       ; a 64-bit hex or binary literal with the top bit set
                uword lit = types.literal_type(e.value)
                if lit == types.T_UBYTE and written_as_word(e.name)
                    return types.T_UWORD
                return lit
            }
            ast.N_FLOAT -> return types.T_FLOAT
            ast.N_STR -> {
                decode_literal(e)
                return types.T_STR
            }
            ast.N_CHAR -> {
                decode_literal(e)
                return types.T_UBYTE
            }
            ast.N_BOOL -> return types.T_BOOL
            ast.N_ARRAYLIT -> return arraylit(e)
            ast.N_IDENT -> {
                ^^symtab.Sym s = e.extra
                if s == 0
                    return 0
                if s.kind == symtab.K_SUB or s.kind == symtab.K_LABEL or s.kind == symtab.K_BLOCK
                    return types.ADDRESS_TYPE          ; a routine used as a value is its address
                if s.type == 0
                    type_symbol(s)
                if s.kind == symtab.K_CONST and s.type == types.T_LONG and not sizing and s.decl != 0 and s.decl.kind == ast.N_VARDECL and s.decl.a == 0 and s.decl.b != 0 {
                    ; a constant declared without a type is a long by itself, and in an
                    ; expression its value, like the number written there
                    bool uok
                    quad uvalue
                    uok, uvalue = const_eval(s.decl.b)
                    if uok
                        return types.literal_type(uvalue)
                }
                return s.type
            }
            ast.N_INDEX -> {
                flatten_2d(e)
                uword basetype = infer(e.a)
                ^^ast.Node ix = e.b
                while ix != 0 {
                    void infer(ix)
                    ix = ix.next
                }
                if basetype == 0
                    return 0
                if e.b != 0 and e.b.next == 0 {
                    ; a constant index below zero counts from the end of an array
                    bool nok
                    quad nidx
                    nok, nidx = const_eval(e.b)
                    if nok and nidx < 0 {
                        long nlen = known_length(e.a)
                        if nlen != 0 and -nidx <= nlen {
                            e.b.kind = ast.N_INT
                            e.b.value = nlen + nidx
                            e.b.a = 0
                            e.b.b = 0
                            e.b.type = 0
                            void infer(e.b)
                        }
                    }
                }
                uword elem = types.index_elem(basetype)
                if elem == 0 and types.is_integer(basetype)
                    elem = types.T_UBYTE        ; an integer used as an address: the byte there
                return elem
            }
            ast.N_DEREF -> {
                uword pt = infer(e.a)
                if types.is_pointer(pt)
                    return types.elem_of(pt)
                if pt != 0 and e.a.kind == ast.N_INDEX {
                    ^^types.Type indexed = types.get(pt)
                    if indexed.base == types.T_STRUCT {
                        ; pointer[i]^^: the element is the struct already, the ^^ says no more
                        ^^ast.Node after = e.next
                        mem.copy(e.a, e, sizeof(ast.Node))
                        e.next = after
                        return pt
                    }
                }
                if pt == types.ADDRESS_TYPE or pt == types.T_UWORD
                    return types.T_UBYTE
                if pt != 0
                    error(e, "unable to determine type of dereferenced pointer expression, make sure it dereferences an actual pointer type")
                return 0
            }
            ast.N_FIELD -> return field(e)
            ast.N_BINARY -> return binary(e)
            ast.N_UNARY -> {
                uword ot = infer(e.a)
                if e.op == token.T_KW_NOT
                    return types.T_BOOL
                if e.op == token.T_MINUS and e.a.kind == ast.N_INT {
                    ; fold the negative literal into one node
                    quad negated = 0 - e.a.value
                    e.kind = ast.N_INT
                    e.value = negated
                    e.name = e.a.name
                    e.a = 0
                    e.op = 0
                    return types.literal_type(negated)
                }
                if e.op == token.T_TILDE
                    return ot
                if e.op == token.T_MINUS and ot == types.T_UBYTE
                    return types.T_BYTE
                if e.op == token.T_MINUS and ot == types.T_UWORD
                    return types.T_WORD
                return ot
            }
            ast.N_RANGE -> {
                uword ft = infer(e.a)
                uword tt = infer(e.b)
                void infer(e.c)
                return range_type(ft, tt)
            }
            ast.N_CALL -> return call_expr(e)
            ast.N_CAST -> {
                void infer(e.a)
                return from_type(e.b)
            }
            ast.N_ADDROF -> {
                uword vt = infer(e.a)
                void infer(e.b)
                if e.op == token.T_AMP and far_memvar(e.a)
                    return types.T_LONG         ; (in far memory: its address is a long)
                if e.op == token.T_AMPAMP {
                    if e.b != 0 or types.is_array(vt)
                        return types.pointer_to(types.index_elem(vt))
                    if vt == types.T_STR
                        return types.pointer_to(types.T_UBYTE)
                    return types.pointer_to(vt)
                }
                if e.op == token.T_AMPLT or e.op == token.T_AMPGT
                    return types.T_UWORD
                if e.b != 0 and vt == types.T_UWORD {
                    ; &word[i]: the word is an address (a variable or a constant), and so is
                    ; the element's, a word like it
                    return types.T_UWORD
                }
                return types.ADDRESS_TYPE
            }
            ast.N_MEMREAD -> {
                void infer(e.a)
                return types.T_UBYTE
            }
            ast.N_SIZEOF -> {
                if e.op != 1 and e.a != 0 {
                    ; not of the type str, nor of an enum, a subroutine or a block
                    bool sizable = true
                    if e.a.kind == ast.N_TYPE and e.a.op == token.T_KW_STR and (e.a.flags & ast.F_POINTER) == 0 and e.a.a == 0
                        sizable = false
                    if (e.a.kind == ast.N_IDENT or (e.a.kind == ast.N_TYPE and e.a.op == token.T_IDENT)) and e.a.extra != 0 {
                        ^^symtab.Sym zs = e.a.extra
                        if zs.kind == symtab.K_ENUM or zs.kind == symtab.K_SUB or zs.kind == symtab.K_BLOCK
                            sizable = false
                    }
                    if not sizable
                        error(e, "Syntax error: sizeof argument should be an identifier, number, or type name")
                }
                if e.a.kind != ast.N_TYPE and e.op != 1 {
                    sizing = true
                    void infer(e.a)
                    sizing = false
                }
                return types.T_UBYTE
            }
            ast.N_IFEXPR -> {
                condition(e.a)
                uword at = infer(e.b)
                uword bt = infer(e.c)
                return common_with_literals(e.b, at, e.c, bt)
            }
            ast.N_BRANCHEXPR -> {
                uword at2 = infer(e.b)
                uword bt2 = infer(e.c)
                return common_with_literals(e.b, at2, e.c, bt2)
            }
            ast.N_STRUCTINIT -> {
                ^^ast.Node v = e.a
                while v != 0 {
                    if v.kind == ast.N_NAMEDFIELD
                        void infer(v.a)
                    else
                        void infer(v)
                    v = v.next
                }
                if e.extra == 0
                    return 0
                return types.pointer_to(types.struct_of(e.extra))
            }
            ast.N_TUPLE -> {
                ^^ast.Node v2 = e.a
                while v2 != 0 {
                    void infer(v2)
                    v2 = v2.next
                }
                return types.T_VOID
            }
            ast.N_VOID -> return types.T_VOID
            ast.N_ASSIGN -> {
                assignment(e)
                return e.b.type
            }
            else -> return 0
        }
    }

    ; the element type of an array literal: the common type of its elements
    sub arraylit(^^ast.Node e) -> uword {
        if e.flags & ast.F_EMPTYARRAY != 0
            return types.array_of(types.T_UBYTE, 0)
        uword elem = 0
        long count = 0
        ^^ast.Node v = e.a
        while v != 0 {
            uword vt = infer(v)
            if vt == types.T_STR
                vt = types.T_STR
            if elem == 0
                elem = vt
            else if vt != 0 and vt != elem {
                if v.kind == ast.N_INT and literal_fits(v.value, elem) {
                    ; fits the element type so far
                }
                else if types.is_numeric(vt) and types.is_numeric(elem)
                    elem = types.common(elem, vt)
            }
            count++
            v = v.next
        }
        if elem == 0
            return 0
        return types.array_of(elem, count)
    }

    ; a.b where a is a pointer to a struct, or a struct instance
    sub field(^^ast.Node e) -> uword {
        uword bt = infer(e.a)
        if bt == 0
            return 0
        pointer strct = 0
        ^^types.Type t = types.get(bt)
        if t.base == types.T_POINTER {
            ^^types.Type pt = types.get(t.elem)
            if pt.base == types.T_STRUCT
                strct = pt.strct
        }
        else if t.base == types.T_STRUCT {
            strct = t.strct
            ; pointer^^.field: the field is reached through the pointer itself; taking
            ; what it points at first and then the field would follow the pointer twice
            if e.a.kind == ast.N_DEREF and e.a.a != 0 and types.is_pointer(e.a.a.type)
                e.a = e.a.a
        }
        if strct == 0 {
            error(e, "field access needs a struct pointer")
            return 0
        }
        ^^symtab.Sym ss = strct
        ^^symtab.Sym f = symtab.find_in(ss.inner, e.name)
        if f == 0 {
            buf.clear(parser.scratch)
            buf.add_str(parser.scratch, "no such field: ")
            buf.add_str(parser.scratch, e.name)
            diag.error_at(source.get(e.file), e.line, e.col, parser.scratch.data)
            return 0
        }
        e.extra = f
        if f.type == 0
            type_symbol(f)
        return f.type
    }

    ; The common type of two operands, where a literal takes the other side's type when it fits.
    sub common_with_literals(^^ast.Node left, uword lt, ^^ast.Node right, uword rt) -> uword {
        if lt == 0 or rt == 0
            return 0
        if left.kind == ast.N_INT and types.is_numeric_or_bool(rt) and not types.is_pointer(rt) and lt != types.T_LONG and not types.is_quad(lt) {
            if literal_fits(left.value, rt) and not (types.is_word(lt) and types.is_byte(rt))
                return rt
        }
        if right.kind == ast.N_INT and types.is_numeric_or_bool(lt) and not types.is_pointer(lt) and rt != types.T_LONG and not types.is_quad(rt) {
            if literal_fits(right.value, lt) and not (types.is_word(rt) and types.is_byte(lt))
                return lt
        }
        return types.common(lt, rt)
    }

    ; The element type of a range, as upstream infers it: bytes stay bytes,
    ; a signed bound makes it signed, otherwise the larger type wins.
    sub range_type(uword ft, uword tt) -> uword {
        if ft == 0 or tt == 0
            return 0
        if ft == types.T_UBYTE and tt == types.T_UBYTE
            return types.T_UBYTE
        if ft == types.T_UWORD and tt == types.T_UWORD
            return types.T_UWORD
        if ft == types.T_WORD or tt == types.T_WORD
            return types.T_WORD
        if ft == types.T_BYTE or tt == types.T_BYTE
            return types.T_BYTE
        if types.size_of(ft) > types.size_of(tt)
            return ft
        return tt
    }

    ; operators whose result is a bool
    sub is_bool_op(ubyte op) -> bool {
        return op == token.T_KW_AND or op == token.T_KW_OR or op == token.T_KW_XOR or op == token.T_KW_IN or op == parser.OP_NOT_IN
            or op == token.T_LT or op == token.T_GT or op == token.T_LE or op == token.T_GE or op == token.T_EQ or op == token.T_NE
    }

    sub binary(^^ast.Node e) -> uword {
        uword lt = infer(e.a)
        uword rt = infer(e.b)
        ubyte op = e.op
        if lt == types.T_FLOAT and e.b.kind == ast.N_INT
            e.b.flags |= AS_FLOAT
        if rt == types.T_FLOAT and e.a.kind == ast.N_INT
            e.a.flags |= AS_FLOAT
        if is_bool_op(op)
            return types.T_BOOL
        if lt == 0 or rt == 0
            return 0
        if op == token.T_SHL or op == token.T_SHR
            return lt
        if op == token.T_AMP or op == token.T_PIPE or op == token.T_CARET
            return types.unsigned_of(lt)
        if lt == types.T_STR and (op == token.T_PLUS or op == token.T_STAR)
            return types.T_STR          ; string concatenation and repetition
        if types.is_array(lt) and op == token.T_STAR {
            ; [value] * count: an array literal repeated
            bool rok
            quad rcount
            rok, rcount = const_eval(e.b)
            if rok
                return types.array_of(types.elem_of(lt), types.get(lt).length * (rcount as long))
            return lt
        }
        ; + - * / %
        if op == token.T_MINUS and types.is_pointer(lt) and types.is_pointer(rt)
            return types.ADDRESS_TYPE
        if types.is_pointer(lt)
            return lt
        if types.is_pointer(rt)
            return rt
        ; with 8-byte addresses, a signed integer added to or subtracted from an address is sign extended to it
        if types.POINTER_SIZE > 4 and (op == token.T_PLUS or op == token.T_MINUS) {
            if (lt == types.ADDRESS_TYPE and types.is_signed(rt)) or (rt == types.ADDRESS_TYPE and types.is_signed(lt) and op == token.T_PLUS)
                return types.ADDRESS_TYPE
        }
        return common_with_literals(e.a, lt, e.b, rt)
    }

    sub call_expr(^^ast.Node e) -> uword {
        ^^symtab.Sym s = e.a.extra
        ^^ast.Node arg = e.b
        uword first = 0
        long nargs = 0
        while arg != 0 {
            uword at = infer(arg)
            if nargs == 0
                first = at
            nargs++
            arg = arg.next
        }
        if s == 0
            return 0
        e.a.type = s.type
        if s.kind == symtab.K_BUILTIN
            return builtin_return(s.name, first, e)
        if s.kind != symtab.K_SUB {
            ; calling through a variable holding an address
            return types.T_VOID
        }
        ; arguments against parameters
        ^^ast.Node p = s.decl.a
        arg = e.b
        long nparams = ast.list_length(p)
        if nargs != nparams {
            buf.clear(parser.scratch)
            buf.add_str(parser.scratch, "wrong number of arguments: expected ")
            buf.add_long(parser.scratch, nparams)
            buf.add_str(parser.scratch, ", got ")
            buf.add_long(parser.scratch, nargs)
            diag.error_at(source.get(e.file), e.line, e.col, parser.scratch.data)
        }
        else {
            long arg_index = 0
            while p != 0 {
                ^^symtab.Sym ps = p.extra
                if ps != 0 {
                    if ps.type == 0
                        type_symbol(ps)
                    arg_index++
                    arg_checked = arg_index
                    check_assign(arg, arg.type, ps.type)
                    arg_checked = 0
                }
                else
                    arg_index++
                p = p.next
                arg = arg.next
            }
        }
        if s.type == 0
            type_symbol(s)
        return s.type
    }

    sub builtin_return(^^ubyte name, uword first, ^^ast.Node e) -> uword {
        ubyte i = 0
        while i < len(builtin_names) {
            if builtin_interned[i] == name {
                ubyte r = builtin_returns[i]
                when r {
                    R_VOID -> return types.T_VOID
                    R_ARG -> return first
                    R_ABS -> {
                        if first == types.T_FLOAT
                            return first
                        return types.unsigned_of(first)
                    }
                    R_SQRT -> {
                        if types.is_byte(first) or types.is_word(first)
                            return types.T_UBYTE
                        if first == types.T_LONG
                            return types.T_UWORD
                        return first
                    }
                    R_ADDRESS -> return types.ADDRESS_TYPE
                    else -> return r
                }
            }
            i++
        }
        return 0
    }

    sub stats() {
        out.puts("typer: ")
        out.putl(typed)
        out.puts(" expressions typed, ")
        out.putl(unknown)
        out.puts(" unknown, ")
        out.putl(checks)
        out.puts(" checks, ")
        out.putl(folded)
        out.puts(" constants folded")
        out.nl()
    }
}
