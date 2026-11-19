; The symbol table: scopes and the symbols declared in them.  Built in one
; pass over all modules before any name is resolved, since Prog8 needs no
; forward declarations.  The global scope holds the blocks of all modules
; (modules are not scopes); blocks hold subroutines, variables, structs,
; enums, labels and aliases; subroutines hold parameters and everything
; declared anywhere in their body, since if/for/while bodies are not scopes.
; Declaration nodes point at their symbol through node.extra.

%import ast
%import token
%import strtab
%import diag
%import importer

symtab {
    %option ignore_unused

    ; scope kinds
    const ubyte S_GLOBAL = 0
    const ubyte S_BLOCK = 1
    const ubyte S_SUB = 2
    const ubyte S_STRUCT = 3
    const ubyte S_ENUM = 4
    const ubyte S_BUILTIN = 5

    ; symbol kinds
    const ubyte K_BLOCK = 1
    const ubyte K_SUB = 2
    const ubyte K_VAR = 3
    const ubyte K_CONST = 4
    const ubyte K_MEMVAR = 5
    const ubyte K_STRUCT = 6
    const ubyte K_ENUM = 7
    const ubyte K_ENUMMEMBER = 8
    const ubyte K_LABEL = 9
    const ubyte K_ALIAS = 10
    const ubyte K_PARAM = 11
    const ubyte K_BUILTIN = 12
    const ubyte K_FIELD = 13

    str[] kind_names = ["?", "block", "sub", "var", "const", "memvar", "struct", "enum", "enummember", "label", "alias", "param", "builtin", "field"]

    struct Scope {
        ^^Scope parent
        ^^Sym syms              ; declared symbols, in declaration order
        ^^Sym last
        ^^ast.Node owner        ; the declaring node (BLOCK, SUB, STRUCT, ENUM) or 0
        ^^ubyte name
        ubyte kind
        bool private_symbols    ; %option private_symbols applies here
    }

    struct Sym {
        ^^Sym next
        ^^ubyte name
        ^^ast.Node decl         ; the declaring node
        ^^Scope inner           ; the scope this symbol opens (block, sub, struct, enum), or 0
        ^^Scope scope           ; the scope it is declared in
        ^^importer.Module module
        ^^ubyte irname          ; scoped name for the IR (irgen), made when first needed
        uword type              ; type id (types.p8) of a variable, constant, parameter or field; a subroutine's first return type
        ubyte kind
        ubyte flags             ; ast.F_PRIVATE / ast.F_PUBLIC from the declaration
        ubyte marks             ; notes of later stages (1: the resolver saw the name used)
    }

    ^^Scope global = 0
    ^^Scope builtins = 0
    long scope_count = 0
    long sym_count = 0
    ^^importer.Module current_module = 0
    ^^ubyte kw_option = 0
    ^^ubyte kw_merge = 0
    ^^ubyte kw_private_symbols = 0

    str[] builtin_names = ["setlsb", "setmsb", "rol", "ror", "rol2", "ror2", "cmp",
        "prog8_lib_stringcompare", "prog8_lib_square_byte", "prog8_lib_square_word", "prog8_lib_square_long",
        "prog8_lib_structalloc", "prog8_lib_copylong", "prog8_lib_copyfloat",
        "abs", "len", "sizeof", "offsetof", "sgn", "sqrt", "divmod", "lmh", "lsb", "msb", "lsw", "msw",
        "mkword", "mklong", "mklong2", "clamp", "min", "max",
        "peek", "peekbool", "peekw", "peekl", "peekq", "peekf", "peekp",
        "poke", "pokebool", "pokebowl", "pokew", "pokel", "pokeq", "pokef", "pokep", "pokemon",
        "rsave", "rrestore", "memory", "callfar", "callfar2", "call",
        "push", "pushw", "pushl", "pushq", "pushf", "pushp", "pop", "popw", "popl", "popq", "popf", "popp"]

    sub new_scope(^^Scope parent, ubyte kind, ^^ubyte name, ^^ast.Node owner) -> ^^Scope {
        ^^Scope s = mem.alloc(sizeof(Scope))
        s.parent = parent
        s.kind = kind
        s.name = name
        s.owner = owner
        if parent != 0 and parent.kind == S_BLOCK
            s.private_symbols = parent.private_symbols
        scope_count++
        return s
    }

    ; Struct types have their own namespace: a struct may share its name with a
    ; subroutine or variable.  A lookup that wants a type sets prefer_struct.
    bool prefer_struct = false

    ; The symbol named name declared directly in the scope, or 0.  With two
    ; symbols of the name (a struct and another), the preferred kind wins.
    sub find_in(^^Scope scope, ^^ubyte name) -> ^^Sym {
        ^^Sym found = 0
        ^^Sym s = scope.syms
        while s != 0 {
            if s.name == name {
                if (s.kind == K_STRUCT) == prefer_struct
                    return s
                if found == 0
                    found = s
            }
            s = s.next
        }
        return found
    }

    ; Declares a symbol; reports a conflict when the name is taken in the scope.
    sub declare(^^Scope scope, ^^ubyte name, ubyte kind, ^^ast.Node decl, ubyte flags) -> ^^Sym {
        bool saved = prefer_struct
        prefer_struct = kind == K_STRUCT
        ^^Sym existing = find_in(scope, name)
        prefer_struct = saved
        if existing != 0 and (existing.kind == K_STRUCT) != (kind == K_STRUCT)
            existing = 0            ; a struct and a non-struct may share a name
        if existing != 0 {
            buf.clear(parser.scratch)
            buf.add_str(parser.scratch, "name conflict '")
            buf.add_str(parser.scratch, name)
            buf.add_str(parser.scratch, "', also defined at line ")
            buf.add_long(parser.scratch, existing.decl.line)
            diag.error_at(current_module.file, decl.line, decl.col, parser.scratch.data)
            return existing
        }
        ^^Sym s = mem.alloc(sizeof(Sym))
        s.name = name
        s.kind = kind
        s.decl = decl
        s.scope = scope
        s.flags = flags & (ast.F_PRIVATE | ast.F_PUBLIC)
        s.module = current_module
        if scope.syms == 0
            scope.syms = s
        else
            scope.last.next = s
        scope.last = s
        sym_count++
        return s
    }

    sub init() {
        kw_option = strtab.intern_cstr("option")
        kw_merge = strtab.intern_cstr("merge")
        kw_private_symbols = strtab.intern_cstr("private_symbols")
        global = new_scope(0, S_GLOBAL, "", 0)
        builtins = new_scope(0, S_BUILTIN, "builtins", 0)
        ubyte i = 0
        while i < len(builtin_names) {
            void declare(builtins, strtab.intern_cstr(builtin_names[i]), K_BUILTIN, 0, 0)
            i++
        }
    }

    ; True when a directive list contains "%option <name>".
    sub has_option(^^ast.Node stmts, ^^ubyte optname) -> bool {
        ^^ast.Node d = stmts
        while d != 0 {
            if d.kind == ast.N_DIRECTIVE and d.name == kw_option {
                ^^ast.Node arg = d.a
                while arg != 0 {
                    if arg.kind == ast.N_IDENT and arg.name == optname
                        return true
                    arg = arg.next
                }
            }
            d = d.next
        }
        return false
    }

    ; Builds the whole table from the loaded modules.
    sub build() {
        if global == 0
            init()
        ; blocks first, so %option merge blocks (second pass) find their targets
        ^^importer.Module m = importer.modules
        while m != 0 {
            current_module = m
            bool module_private = has_option(m.tree.a, kw_private_symbols)
            ^^ast.Node b = m.tree.a
            while b != 0 {
                if b.kind == ast.N_BLOCK and not has_option(b.a, kw_merge)
                    declare_block(b, module_private)
                b = b.next
            }
            m = m.next
        }
        m = importer.modules
        while m != 0 {
            current_module = m
            bool module_private2 = has_option(m.tree.a, kw_private_symbols)
            ^^ast.Node b2 = m.tree.a
            while b2 != 0 {
                if b2.kind == ast.N_BLOCK and has_option(b2.a, kw_merge)
                    merge_block(b2, module_private2)
                b2 = b2.next
            }
            m = m.next
        }
    }

    sub declare_block(^^ast.Node b, bool module_private) {
        ^^Sym s = declare(global, b.name, K_BLOCK, b, 0)
        if s.decl != b
            return          ; a duplicate; reported
        ^^Scope scope = new_scope(global, S_BLOCK, b.name, b)
        scope.private_symbols = module_private or has_option(b.a, kw_private_symbols)
        s.inner = scope
        b.extra = s
        declare_statements(scope, b.a)
    }

    ; A %option merge block adds its contents to the block of the same name.
    sub merge_block(^^ast.Node b, bool module_private) {
        ^^Sym target = find_in(global, b.name)
        if target == 0 {
            ; nothing to merge into: it is just a block
            declare_block(b, module_private)
            return
        }
        b.extra = target
        merging = true
        declare_statements(target.inner, b.a)
        merging = false
    }

    bool merging = false            ; declaring the contents of a %option merge block

    ; the same number of parameters with the same names: the signature a routine of a
    ; merged block must have to take the place of the block's own
    sub same_parameters(^^ast.Node a, ^^ast.Node b) -> bool {
        while a != 0 and b != 0 {
            if a.name != b.name
                return false
            a = a.next
            b = b.next
        }
        return a == 0 and b == 0
    }

    sub count_list(^^ast.Node n) -> uword {
        uword k = 0
        while n != 0 {
            k++
            n = n.next
        }
        return k
    }

    ; Declares everything in a statement list, descending into statement bodies
    ; (which are not scopes) but not into subroutines, structs and enums (which are).
    sub declare_statements(^^Scope scope, ^^ast.Node stmts) {
        ^^ast.Node s = stmts
        while s != 0 {
            declare_statement(scope, s)
            s = s.next
        }
    }

    sub declare_statement(^^Scope scope, ^^ast.Node s) {
        when s.kind {
            ast.N_VARDECL -> {
                ubyte kind = K_VAR
                if s.op == token.T_KW_CONST
                    kind = K_CONST
                else if s.op == token.T_AMP
                    kind = K_MEMVAR
                ^^ast.Node id = s.c
                while id != 0 {
                    ^^Sym vs = declare(scope, id.name, kind, s, s.flags)
                    id.extra = vs
                    id = id.next
                }
            }
            ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB -> {
                ^^Sym ss = 0
                if merging and scope.kind == S_BLOCK {
                    ; A routine of a merged block takes the place of the block's own routine
                    ; of that name with the same parameters (upstream: "monkeypatched").
                    ^^Sym prior = find_in(scope, s.name)
                    if prior != 0 and prior.kind == K_SUB and prior.decl != 0 and prior.decl != s
                            and same_parameters(prior.decl.a, s.a) {
                        prior.decl.kind = ast.N_REMOVED
                        prior.decl = s
                        prior.module = current_module
                        ss = prior
                    }
                }
                if ss == 0 {
                    ss = declare(scope, s.name, K_SUB, s, s.flags)
                    if ss.decl != s
                        return
                }
                ^^Scope inner = new_scope(scope, S_SUB, s.name, s)
                ss.inner = inner
                s.extra = ss
                ^^ast.Node p = s.a
                while p != 0 {
                    p.extra = declare(inner, p.name, K_PARAM, p, 0)
                    p = p.next
                }
                if s.kind != ast.N_EXTSUB
                    declare_statements(inner, s.c)
            }
            ast.N_STRUCT, ast.N_UNION -> {
                ^^Sym st = declare(scope, s.name, K_STRUCT, s, s.flags)
                if st.decl != s
                    return
                ^^Scope fields = new_scope(scope, S_STRUCT, s.name, s)
                st.inner = fields
                s.extra = st
                ^^ast.Node f = s.a
                while f != 0 {
                    ^^ast.Node fid = f.c
                    while fid != 0 {
                        fid.extra = declare(fields, fid.name, K_FIELD, f, 0)
                        fid = fid.next
                    }
                    f = f.next
                }
            }
            ast.N_ENUM -> {
                ^^Sym es = declare(scope, s.name, K_ENUM, s, s.flags)
                if es.decl != s
                    return
                ^^Scope members = new_scope(scope, S_ENUM, s.name, s)
                es.inner = members
                s.extra = es
                ^^ast.Node mem = s.a
                while mem != 0 {
                    mem.extra = declare(members, mem.name, K_ENUMMEMBER, mem, 0)
                    ; also reachable as Enum::member from the enclosing scope
                    buf.clear(parser.scratch)
                    buf.add_str(parser.scratch, s.name)
                    buf.add_str(parser.scratch, "::")
                    buf.add_str(parser.scratch, mem.name)
                    void declare(scope, strtab.intern(parser.scratch.data, parser.scratch.len as uword), K_ENUMMEMBER, mem, s.flags)
                    mem = mem.next
                }
            }
            ast.N_LABEL -> s.extra = declare(scope, s.name, K_LABEL, s, 0)
            ast.N_ALIAS -> s.extra = declare(scope, s.name, K_ALIAS, s, s.flags)
            ast.N_DIRECTIVE -> {
                if s.name == kw_option and scope.kind == S_BLOCK {
                    ^^ast.Node arg = s.a
                    while arg != 0 {
                        if arg.kind == ast.N_IDENT and arg.name == kw_private_symbols
                            scope.private_symbols = true
                        arg = arg.next
                    }
                }
            }
            ast.N_IF, ast.N_BRANCH -> {
                declare_statements(scope, s.b)
                declare_statements(scope, s.c)
            }
            ast.N_FOR -> {
                if s.d != 0 and s.d.kind == ast.N_TYPE {
                    ; a typed loop variable; consecutive loops may share one of the same type
                    ^^Sym earlier = find_in(scope, s.a.name)
                    if earlier != 0 and earlier.decl.kind == ast.N_FOR and earlier.decl.d.op == s.d.op and earlier.decl.d.name == s.d.name
                        s.a.extra = earlier
                    else
                        s.a.extra = declare(scope, s.a.name, K_VAR, s, 0)
                }
                declare_statements(scope, s.c)
            }
            ast.N_WHILE, ast.N_REPEAT, ast.N_UNROLL -> declare_statements(scope, s.b)
            ast.N_UNTIL, ast.N_DEFER -> declare_statements(scope, s.a)
            ast.N_ONGOTO -> declare_statements(scope, s.c)
            ast.N_WHEN -> {
                ^^ast.Node c = s.b
                while c != 0 {
                    declare_statements(scope, c.b)
                    c = c.next
                }
            }
        }
    }

    ; ---- dump ----

    sub dump() {
        dump_scope(global, 0)
    }

    sub dump_scope(^^Scope scope, ubyte indent) {
        ^^Sym s = scope.syms
        while s != 0 {
            repeat indent
                out.puts("  ")
            out.puts(kind_names[s.kind])
            out.putc(' ')
            out.puts(s.name)
            if s.flags & ast.F_PRIVATE != 0
                out.puts(" private")
            if s.flags & ast.F_PUBLIC != 0
                out.puts(" public")
            out.nl()
            if s.inner != 0
                dump_scope(s.inner, indent + 1)
            s = s.next
        }
    }

    sub stats() {
        out.puts("symbols: ")
        out.putl(sym_count)
        out.puts(" in ")
        out.putl(scope_count)
        out.puts(" scopes")
        out.nl()
    }
}
