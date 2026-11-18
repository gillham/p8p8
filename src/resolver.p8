; The resolver: links every name used in the program to its symbol, following
; the upstream lookup rules.  An unqualified name is a builtin function, else
; it is searched from the current scope outwards, then among the blocks of all
; modules.  A qualified name a.b.c first tries an alias or a struct-pointer
; variable named a in the current scopes (then b, c are fields), and otherwise
; starts from the global namespace: a is a block.  Resolved identifier nodes
; point at their symbol through node.extra; field chains through a pointer
; variable set node.op to R_FIELDREF and point at the final field.

%import ast
%import token
%import symtab
%import strtab
%import buf
%import diag
%import importer

resolver {
    %option ignore_unused

    const ubyte R_FIELDREF = 1
    const ubyte MAX_PARTS = 16

    ^^symtab.Scope scope = 0            ; the current scope
    ^^importer.Module module = 0
    long resolved = 0
    ^^pointer parts = 0                 ; the parts of the name being looked up
    ubyte nparts = 0

    sub resolve_program() {
        if parts == 0
            parts = mem.alloc(MAX_PARTS * sizeof(pointer))
        ^^importer.Module m = importer.modules
        while m != 0 {
            module = m
            ^^ast.Node b = m.tree.a
            while b != 0 {
                if b.kind == ast.N_BLOCK and b.extra != 0 {
                    ^^symtab.Sym bs = b.extra
                    scope = bs.inner
                    statements(b.a)
                }
                b = b.next
            }
            m = m.next
        }
    }

    sub error(^^ast.Node at, str message, ^^ubyte name) {
        buf.clear(parser.scratch)
        buf.add_str(parser.scratch, message)
        buf.add_str(parser.scratch, name)
        diag.error_at(module.file, at.line, at.col, parser.scratch.data)
    }

    ; ---- lookup ----

    ; Splits a dotted name into interned parts.
    sub split(^^ubyte name) {
        nparts = 0
        long start = 0
        long i = 0
        repeat {
            ubyte c = name[i]
            if c == '.' or c == 0 {
                if nparts < MAX_PARTS {
                    parts[nparts] = strtab.intern(name + start, (i - start) as uword)
                    nparts++
                }
                start = i + 1
            }
            if c == 0
                break
            i++
        }
    }

    ; An unqualified name: builtins, the scope chain, then the blocks of all modules.
    sub lookup_unqualified(^^ubyte name) -> ^^symtab.Sym {
        ^^symtab.Sym s = symtab.find_in(symtab.builtins, name)
        if s != 0
            return s
        ^^symtab.Scope sc = scope
        while sc != 0 {
            s = symtab.find_in(sc, name)
            if s != 0
                return s
            sc = sc.parent
        }
        return 0
    }

    ; The struct scope a symbol points at, when it is a variable, parameter or field of pointer-to-struct type.
    sub pointee_struct(^^symtab.Sym s) -> ^^symtab.Scope {
        if s == 0
            return 0
        ^^ast.Node t = 0
        if s.kind == symtab.K_VAR or s.kind == symtab.K_MEMVAR or s.kind == symtab.K_FIELD {
            if s.decl.kind == ast.N_VARDECL
                t = s.decl.a
            else if s.decl.kind == ast.N_FOR
                t = s.decl.d
        }
        else if s.kind == symtab.K_PARAM
            t = s.decl.a
        if t == 0 or t.kind != ast.N_TYPE or t.op != token.T_IDENT
            return 0
        ; the type name is relative to where the variable is declared, not to where it is used;
        ; resolving it re-enters lookup_name, so the parts of the name being looked up are kept aside
        ^^symtab.Scope saved = scope
        ^^pointer saved_parts = parts
        ubyte saved_nparts = nparts
        if t.extra == 0
            parts = mem.alloc(MAX_PARTS * sizeof(pointer))
        scope = s.scope
        if scope.kind == symtab.S_STRUCT
            scope = scope.parent        ; a field's type name is not looked up among the fields
        ^^symtab.Sym st = resolve_type_name(t)
        scope = saved
        parts = saved_parts
        nparts = saved_nparts
        if st == 0 or st.kind != symtab.K_STRUCT
            return 0
        return st.inner
    }

    ; Follows fields from part index first through struct scopes; returns the final field or 0.
    sub field_chain(^^symtab.Scope fields, ubyte first) -> ^^symtab.Sym {
        ^^symtab.Sym f = 0
        ubyte i = first
        while i < nparts {
            if fields == 0
                return 0
            f = symtab.find_in(fields, parts[i])
            if f == 0
                return 0
            i++
            if i < nparts
                fields = pointee_struct(f)
        }
        return f
    }

    ; Resolves the name of a node; returns its symbol or 0 (reported).
    sub lookup(^^ast.Node node) -> ^^symtab.Sym {
        ^^symtab.Sym s = lookup_name(node.name, node)
        if s == 0
            s = enum_member(node)
        if s == 0
            error(node, "undefined symbol: ", node.name)
        else
            s.marks |= 1
        node.extra = s
        return s
    }

    ; offsetof(Struct.field): the struct by all of the name but its last part, the field
    ; in it by the last
    sub offsetof_field(^^ast.Node id) {
        ^^ubyte name = id.name
        long length = buf.cstr_len(name)
        long dot = length
        while dot > 0 and name[dot - 1] != '.'
            dot--
        ^^symtab.Sym field = 0
        if dot > 1 {
            symtab.prefer_struct = true
            ^^symtab.Sym st = lookup_name(strtab.intern(name, (dot - 1) as uword), id)
            symtab.prefer_struct = false
            if st != 0 and st.kind == symtab.K_STRUCT and st.inner != 0
                field = symtab.find_in(st.inner, strtab.intern(name + dot, (length - dot) as uword))
        }
        if field == 0
            error(id, "undefined symbol: ", name)
        id.extra = field
    }

    ; "name::MEMBER" where name is not the enum's own name in this scope (that is a symbol
    ; of its own): an alias of an enum, or a path to one
    sub enum_member(^^ast.Node node) -> ^^symtab.Sym {
        ^^ubyte name = node.name
        long length = buf.cstr_len(name)
        long at = 0
        while at + 2 < length and not (name[at] == ':' and name[at + 1] == ':')
            at++
        if at + 2 >= length or at == 0
            return 0
        ^^symtab.Sym owner = lookup_name(strtab.intern(name, at as uword), node)
        if owner == 0 or owner.kind != symtab.K_ENUM or owner.inner == 0
            return 0
        return symtab.find_in(owner.inner, strtab.intern(name + at + 2, (length - at - 2) as uword))
    }

    sub lookup_name(^^ubyte name, ^^ast.Node node) -> ^^symtab.Sym {
        split(name)
        if nparts == 1 {
            ^^symtab.Sym s = lookup_unqualified(name)
            if s != 0 and s.kind == symtab.K_ALIAS
                s = alias_target(s, node, 1)        ; no parts follow the alias name
            return s
        }
        ; qualified: an alias or a struct pointer variable in scope?
        ^^symtab.Sym local = lookup_unqualified(parts[0])
        if local != 0 {
            local.marks |= 1            ; (the variable in "variable.field" is used)
            if local.kind == symtab.K_ALIAS
                return alias_target(local, node, 1)
            ^^symtab.Scope fields = pointee_struct(local)
            if fields != 0 {
                ^^symtab.Sym f = field_chain(fields, 1)
                if f != 0 {
                    node.op = R_FIELDREF
                    return f
                }
            }
        }
        ; from the global namespace: a block, then its members
        ^^symtab.Sym s2 = symtab.find_in(symtab.global, parts[0])
        if s2 == 0
            return 0
        ubyte i = 1
        while i < nparts {
            ^^symtab.Sym inner = 0
            if s2.inner != 0
                inner = symtab.find_in(s2.inner, parts[i])
            if inner != 0
                inner.marks |= 1        ; (every name on the way is used: "main.sub.variable.field")
            if inner == 0 {
                ^^symtab.Scope fields2 = pointee_struct(s2)
                if fields2 != 0 {
                    ^^symtab.Sym f2 = field_chain(fields2, i)
                    if f2 != 0 {
                        node.op = R_FIELDREF
                        return f2
                    }
                }
                return 0
            }
            if inner.kind == symtab.K_ALIAS {
                ; alias inside another block: continue from its target with the rest of the name
                inner = alias_target(inner, node, i + 1)
                return inner
            }
            check_visible(inner, node)
            s2 = inner
            i++
        }
        return s2
    }

    ; An alias used with the parts from index rest onwards appended: look up target.rest
    sub alias_target(^^symtab.Sym al, ^^ast.Node node, ubyte rest) -> ^^symtab.Sym {
        ^^ast.Node target = al.decl.a
        if target.kind == ast.N_TYPE
            return resolve_type_name(target)
        if rest >= nparts {
            ; simple: look the target up in the scope of the alias itself
            ^^symtab.Scope saved = scope
            scope = al.scope
            ^^symtab.Sym s = lookup_name(target.name, node)
            scope = saved
            return s
        }
        buf.clear(parser.scratch)
        buf.add_str(parser.scratch, target.name)
        ubyte i = rest
        while i < nparts {
            buf.add_byte(parser.scratch, '.')
            buf.add_str(parser.scratch, parts[i])
            i++
        }
        ^^ubyte combined = strtab.intern(parser.scratch.data, parser.scratch.len as uword)
        ^^symtab.Scope saved2 = scope
        scope = al.scope
        ^^symtab.Sym s3 = lookup_name(combined, node)
        scope = saved2
        return s3
    }

    ; The block scope the current scope is in.
    sub current_block() -> ^^symtab.Scope {
        ^^symtab.Scope sc = scope
        while sc != 0 and sc.kind != symtab.S_BLOCK
            sc = sc.parent
        return sc
    }

    sub block_of(^^symtab.Scope sc) -> ^^symtab.Scope {
        while sc != 0 and sc.kind != symtab.S_BLOCK
            sc = sc.parent
        return sc
    }

    ; A symbol reached through another block must be public.
    sub check_visible(^^symtab.Sym s, ^^ast.Node node) {
        ^^symtab.Scope here = current_block()
        ^^symtab.Scope there = block_of(s.scope)
        if there == 0 or there == here
            return
        if s.flags & ast.F_PRIVATE != 0
            error(node, "symbol is private: ", s.name)
        else if s.scope.private_symbols and s.flags & ast.F_PUBLIC == 0
            error(node, "symbol is private (private_symbols): ", s.name)
    }

    ; The struct symbol a TYPE node names, resolved once and cached in the node.
    sub resolve_type_name(^^ast.Node t) -> ^^symtab.Sym {
        if t.extra != 0
            return t.extra
        if t.op != token.T_IDENT
            return 0
        bool saved = symtab.prefer_struct
        symtab.prefer_struct = true
        ^^symtab.Sym s = lookup_name(t.name, t)
        symtab.prefer_struct = saved
        if s != 0 and s.kind != symtab.K_STRUCT
            s = 0
        t.extra = s
        return s
    }

    sub type(^^ast.Node t) {
        if t == 0
            return
        if t.op == token.T_IDENT {
            if resolve_type_name(t) == 0
                error(t, "undefined struct type: ", t.name)
            else
                resolved++
        }
        ^^ast.Node dim = t.a
        while dim != 0 {
            expression(dim)
            dim = dim.next
        }
    }

    ; ---- walking ----

    sub statements(^^ast.Node s) {
        while s != 0 {
            statement(s)
            s = s.next
        }
    }

    sub enter(^^ast.Node decl) -> ^^symtab.Scope {
        ^^symtab.Scope saved = scope
        if decl.extra != 0 {
            ^^symtab.Sym s = decl.extra
            if s.inner != 0
                scope = s.inner
        }
        return saved
    }

    sub statement(^^ast.Node n) {
        when n.kind {
            ast.N_DIRECTIVE -> {
                ; the directives whose arguments are expressions with names in them
                if strings.compare(n.name, "assert") == 0 or strings.compare(n.name, "jmptable") == 0 {
                    ^^ast.Node da = n.a
                    while da != 0 {
                        if da.kind != ast.N_STR
                            expression(da)
                        da = da.next
                    }
                }
            }
            ast.N_VARDECL -> {
                type(n.a)
                expression(n.b)
            }
            ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB -> {
                ^^symtab.Scope saved = enter(n)
                ^^ast.Node p = n.a
                while p != 0 {
                    type(p.a)
                    p = p.next
                }
                ^^ast.Node r = n.b
                while r != 0 {
                    type(r)
                    r = r.next
                }
                expression(n.c)         ; extsub address, or 0
                if n.kind == ast.N_EXTSUB and n.d != 0 and n.d.kind == ast.N_IDENT
                    expression(n.d)     ; a bank named by a variable or a selector subroutine
                if n.kind != ast.N_EXTSUB
                    statements(n.c)
                scope = saved
            }
            ast.N_STRUCT, ast.N_UNION -> {
                ^^ast.Node f = n.a
                while f != 0 {
                    type(f.a)
                    f = f.next
                }
            }
            ast.N_ENUM -> {
                ^^ast.Node m = n.a
                while m != 0 {
                    expression(m.a)
                    m = m.next
                }
            }
            ast.N_ALIAS -> {
                if n.a.kind == ast.N_TYPE
                    type(n.a)
                else
                    void lookup(n.a)
            }
            ast.N_ASSIGN, ast.N_AUGASSIGN, ast.N_SWAP -> {
                expressions(n.a)
                expression(n.b)
            }
            ast.N_INCDEC, ast.N_CALLSTMT, ast.N_GOTO -> expression(n.a)
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
            ast.N_FOR -> {
                ^^ast.Node opt = n.d
                if opt != 0 and opt.kind == ast.N_TYPE {
                    type(opt)
                    opt = opt.next
                }
                ; the loop variable is declared implicitly by the loop when no variable of that name exists
                ^^symtab.Sym lv = lookup_name(n.a.name, n.a)
                if lv == 0 {
                    if nparts == 1 {
                        lv = symtab.declare(scope, n.a.name, symtab.K_VAR, n, 0)
                        n.a.extra = lv
                    }
                    else
                        error(n.a, "undefined symbol: ", n.a.name)
                }
                else
                    n.a.extra = lv
                expression(n.b)
                while opt != 0 {
                    if opt.op != token.T_KW_VIA
                        expression(opt.a)
                    opt = opt.next
                }
                statements(n.c)
            }
            ast.N_WHILE -> {
                expression(n.a)
                statements(n.b)
            }
            ast.N_UNTIL -> {
                statements(n.a)
                expression(n.b)
            }
            ast.N_REPEAT, ast.N_UNROLL -> {
                expression(n.a)
                statements(n.b)
            }
            ast.N_WHEN -> {
                expression(n.a)
                ^^ast.Node c = n.b
                while c != 0 {
                    expressions(c.a)
                    statements(c.b)
                    c = c.next
                }
            }
            ast.N_DEFER -> statements(n.a)
            ast.N_ONGOTO -> {
                expression(n.a)
                expressions(n.b)
                statements(n.c)
            }
        }
    }

    sub expressions(^^ast.Node e) {
        while e != 0 {
            expression(e)
            e = e.next
        }
    }

    sub expression(^^ast.Node e) {
        if e == 0
            return
        when e.kind {
            ast.N_IDENT -> {
                if lookup(e) != 0
                    resolved++
            }
            ast.N_INDEX -> {
                expression(e.a)
                expressions(e.b)
            }
            ast.N_DEREF, ast.N_FIELD, ast.N_UNARY, ast.N_MEMREAD -> expression(e.a)
            ast.N_BINARY -> {
                expression(e.a)
                expression(e.b)
            }
            ast.N_RANGE, ast.N_IFEXPR -> {
                expression(e.a)
                expression(e.b)
                expression(e.c)
            }
            ast.N_BRANCHEXPR -> {
                expression(e.b)
                expression(e.c)
            }
            ast.N_CALL -> {
                expression(e.a)
                expressions(e.b)
            }
            ast.N_CAST -> {
                expression(e.a)
                type(e.b)
            }
            ast.N_ADDROF -> {
                expression(e.a)
                expression(e.b)
            }
            ast.N_SIZEOF -> {
                if e.op == 1
                    offsetof_field(e.a)
                else if e.a.kind == ast.N_TYPE
                    type(e.a)
                else
                    expression(e.a)
            }
            ast.N_ARRAYLIT, ast.N_TUPLE -> expressions(e.a)
            ast.N_STRUCTINIT -> {
                symtab.prefer_struct = true
                ^^symtab.Sym st = lookup_name(e.name, e)
                symtab.prefer_struct = false
                if st == 0 or st.kind != symtab.K_STRUCT
                    error(e, "undefined struct type: ", e.name)
                else {
                    e.extra = st
                    resolved++
                }
                ^^ast.Node v = e.a
                while v != 0 {
                    if v.kind == ast.N_NAMEDFIELD
                        expression(v.a)
                    else
                        expression(v)
                    v = v.next
                }
            }
            ast.N_ASSIGN -> {
                expressions(e.a)
                expression(e.b)
            }
        }
    }

    sub stats() {
        out.puts("resolver: ")
        out.putl(resolved)
        out.puts(" names resolved")
        out.nl()
    }
}
