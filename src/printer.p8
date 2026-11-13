; The pretty printer: writes an AST back out as Prog8 source.  Its purpose
; is the round trip test (print, reparse, compare dumps), so it is exact
; rather than pretty: every operand that isn't a simple value is
; parenthesized, and every statement body is written in braces.

%import ast
%import token
%import out

printer {
    %option ignore_unused

    ubyte depth = 0

    sub print_module(^^ast.Node m) {
        ^^ast.Node e = m.a
        while e != 0 {
            statement(e)
            e = e.next
        }
    }

    sub indent() {
        repeat depth
            out.puts("    ")
    }

    sub opname(ubyte op) {
        ast.put_opname(op)
    }

    sub modifiers(^^ast.Node n) {
        if n.flags & ast.F_PRIVATE != 0
            out.puts("private ")
        if n.flags & ast.F_PUBLIC != 0
            out.puts("public ")
        if n.flags & ast.F_INLINE != 0
            out.puts("inline ")
    }

    ; ---- declarations and statements ----

    sub statements(^^ast.Node s) {
        depth++
        while s != 0 {
            statement(s)
            s = s.next
        }
        depth--
    }

    ; a statement body in braces, followed by a newline
    sub body(^^ast.Node s) {
        out.puts(" {")
        out.nl()
        statements(s)
        indent()
        out.putc('}')
        out.nl()
    }

    sub statement(^^ast.Node n) {
        indent()
        when n.kind {
            ast.N_DIRECTIVE -> directive(n)
            ast.N_BLOCK -> {
                out.puts(n.name)
                if n.b != 0 {
                    out.putc(' ')
                    expression(n.b)
                }
                body(n.a)
            }
            ast.N_VARDECL -> vardecl(n)
            ast.N_SUB -> {
                modifiers(n)
                out.puts("sub ")
                out.puts(n.name)
                out.putc('(')
                params(n.a)
                out.putc(')')
                returns(n.b)
                body(n.c)
            }
            ast.N_ASMSUB -> {
                modifiers(n)
                out.puts("asmsub ")
                out.puts(n.name)
                out.putc('(')
                params(n.a)
                out.putc(')')
                clobber_list(n.d)
                returns(n.b)
                body(n.c)
            }
            ast.N_EXTSUB -> extsub_decl(n)
            ast.N_STRUCT, ast.N_UNION -> {
                modifiers(n)
                if n.kind == ast.N_STRUCT
                    out.puts("struct ")
                else
                    out.puts("union ")
                out.puts(n.name)
                out.puts(" {")
                out.nl()
                depth++
                ^^ast.Node f = n.a
                while f != 0 {
                    indent()
                    vardecl(f)
                    f = f.next
                }
                depth--
                indent()
                out.putc('}')
                out.nl()
            }
            ast.N_ENUM -> {
                modifiers(n)
                out.puts("enum ")
                out.puts(n.name)
                out.puts(" {")
                out.nl()
                depth++
                ^^ast.Node m = n.a
                while m != 0 {
                    indent()
                    out.puts(m.name)
                    if m.a != 0 {
                        out.puts(" = ")
                        expression(m.a)
                    }
                    if m.next != 0
                        out.putc(',')
                    out.nl()
                    m = m.next
                }
                depth--
                indent()
                out.putc('}')
                out.nl()
            }
            ast.N_ALIAS -> {
                modifiers(n)
                out.puts("alias ")
                out.puts(n.name)
                out.puts(" = ")
                if n.a.kind == ast.N_TYPE
                    type(n.a)
                else
                    expression(n.a)
                out.nl()
            }
            ast.N_LABEL -> {
                out.puts(n.name)
                out.putc(':')
                out.nl()
            }
            ast.N_ASM -> {
                out.putc('%')
                out.puts(n.name)
                out.puts(" {{")
                out.put_bytes(n.extra, n.value as long)
                out.puts("}}")
                out.nl()
            }
            ast.N_ASSIGN -> {
                assignment(n)
                out.nl()
            }
            ast.N_AUGASSIGN -> {
                expression(n.a)
                out.putc(' ')
                opname(n.op)
                out.putc(' ')
                expression(n.b)
                out.nl()
            }
            ast.N_INCDEC -> {
                expression(n.a)
                opname(n.op)
                out.nl()
            }
            ast.N_CALLSTMT -> {
                if n.flags & ast.F_VOID != 0
                    out.puts("void ")
                expression(n.a)
                out.nl()
            }
            ast.N_IF -> {
                out.puts("if ")
                expression(n.a)
                body(n.b)
                else_part(n.c)
            }
            ast.N_BRANCH -> {
                opname(n.op)
                body(n.b)
                else_part(n.c)
            }
            ast.N_RETURN -> {
                out.puts("return")
                if n.a != 0 {
                    out.putc(' ')
                    list(n.a)
                }
                out.nl()
            }
            ast.N_FOR -> forloop(n)
            ast.N_WHILE -> {
                out.puts("while ")
                expression(n.a)
                body(n.b)
            }
            ast.N_UNTIL -> {
                out.puts("do")
                out.puts(" {")
                out.nl()
                statements(n.a)
                indent()
                out.puts("} until ")
                expression(n.b)
                out.nl()
            }
            ast.N_REPEAT, ast.N_UNROLL -> {
                if n.kind == ast.N_REPEAT
                    out.puts("repeat")
                else
                    out.puts("unroll")
                if n.a != 0 {
                    out.putc(' ')
                    expression(n.a)
                }
                body(n.b)
            }
            ast.N_WHEN -> {
                out.puts("when ")
                expression(n.a)
                out.puts(" {")
                out.nl()
                depth++
                ^^ast.Node c = n.b
                while c != 0 {
                    indent()
                    if c.a == 0
                        out.puts("else")
                    else
                        list(c.a)
                    out.puts(" ->")
                    body(c.b)
                    c = c.next
                }
                depth--
                indent()
                out.putc('}')
                out.nl()
            }
            ast.N_BREAK -> {
                out.puts("break")
                out.nl()
            }
            ast.N_CONTINUE -> {
                out.puts("continue")
                out.nl()
            }
            ast.N_GOTO -> {
                out.puts("goto ")
                expression(n.a)
                out.nl()
            }
            ast.N_DEFER -> {
                out.puts("defer")
                body(n.a)
            }
            ast.N_SWAP -> {
                out.puts("swap(")
                expression(n.a)
                out.puts(", ")
                expression(n.b)
                out.putc(')')
                out.nl()
            }
            ast.N_ONGOTO -> {
                out.puts("on ")
                expression(n.a)
                out.putc(' ')
                opname(n.op)
                out.puts(" (")
                list(n.b)
                out.putc(')')
                if n.c != 0 {
                    out.puts(" else")
                    body(n.c)
                }
                else
                    out.nl()
            }
            else -> {
                out.puts("; unknown statement kind ")
                out.puts(ast.names[n.kind])
                out.nl()
            }
        }
    }

    sub else_part(^^ast.Node s) {
        if s == 0
            return
        indent()
        out.puts("else")
        body(s)
    }

    sub directive(^^ast.Node n) {
        out.putc('%')
        out.puts(n.name)
        if n.flags & ast.F_BANG != 0
            out.putc('!')
        if n.a != 0 {
            out.putc(' ')
            if n.flags & ast.F_NAMED != 0 {
                out.putc('(')
                list(n.a)
                out.putc(')')
            }
            else
                list(n.a)
        }
        out.nl()
    }

    sub vardecl(^^ast.Node n) {
        modifiers(n)
        if n.op == token.T_KW_CONST
            out.puts("const ")
        else if n.op == token.T_AMP
            out.putc('&')
        if n.a != 0 {
            type(n.a)
            out.putc(' ')
        }
        tags(n.d)
        list(n.c)
        if n.b != 0 {
            out.puts(" = ")
            expression(n.b)
        }
        out.nl()
    }

    sub tags(^^ast.Node t) {
        while t != 0 {
            out.putc('@')
            out.puts(t.name)
            out.putc(' ')
            t = t.next
        }
    }

    sub type(^^ast.Node t) {
        if t.flags & ast.F_POINTER != 0
            out.puts("^^")
        if t.op == token.T_IDENT
            out.puts(t.name)
        else
            opname(t.op)
        if t.flags & ast.F_EMPTYARRAY != 0
            out.puts("[]")
        ^^ast.Node dim = t.a
        while dim != 0 {
            out.putc('[')
            expression(dim)
            out.putc(']')
            dim = dim.next
        }
    }

    sub params(^^ast.Node p) {
        while p != 0 {
            type(p.a)
            out.putc(' ')
            tags(p.d)
            out.puts(p.name)
            if p.b != 0 {
                out.puts(" @")
                out.puts(p.b.name)
            }
            if p.next != 0
                out.puts(", ")
            p = p.next
        }
    }

    sub returns(^^ast.Node r) {
        if r == 0
            return
        out.puts(" -> ")
        while r != 0 {
            if r.op != token.T_KW_VOID
                type(r)
            if r.b != 0 {
                out.puts(" @")
                out.puts(r.b.name)
            }
            if r.next != 0
                out.puts(", ")
            r = r.next
        }
    }

    sub clobber_list(^^ast.Node c) {
        if c == 0
            return
        out.puts(" clobbers(")
        list(c)
        out.putc(')')
    }

    sub extsub_decl(^^ast.Node n) {
        modifiers(n)
        out.puts("extsub ")
        if n.c == 0 {
            out.puts(n.name)
            out.putc('(')
            params(n.a)
            out.putc(')')
            returns(n.b)
            out.nl()
            return
        }
        if n.d != 0 {
            out.puts("@bank ")
            expression(n.d)
            out.putc(' ')
        }
        expression(n.c)
        out.puts(" = ")
        out.puts(n.name)
        out.putc('(')
        params(n.a)
        out.putc(')')
        if n.b != 0 and n.b.d != 0
            clobber_list(n.b.d)
        if n.b != 0 and (n.b.op != token.T_KW_VOID or n.b.next != 0)
            returns(n.b)
        out.nl()
    }

    sub forloop(^^ast.Node n) {
        out.puts("for ")
        ^^ast.Node opt = n.d
        if opt != 0 and opt.kind == ast.N_TYPE {
            type(opt)
            out.putc(' ')
            opt = opt.next
        }
        expression(n.a)
        out.puts(" in ")
        expression(n.b)
        while opt != 0 {
            out.putc(' ')
            opname(opt.op)
            out.putc(' ')
            if opt.op == token.T_KW_VIA
                out.putc('.')
            expression(opt.a)
            opt = opt.next
        }
        body(n.c)
    }

    sub assignment(^^ast.Node n) {
        list(n.a)
        out.puts(" = ")
        if n.b.kind == ast.N_ASSIGN
            assignment(n.b)
        else
            expression(n.b)
    }

    ; ---- expressions ----

    ; comma separated expressions
    sub list(^^ast.Node e) {
        while e != 0 {
            expression(e)
            if e.next != 0
                out.puts(", ")
            e = e.next
        }
    }

    sub is_simple(^^ast.Node e) -> bool {
        ubyte k = e.kind
        return k == ast.N_INT or k == ast.N_FLOAT or k == ast.N_STR or k == ast.N_CHAR or k == ast.N_BOOL
            or k == ast.N_IDENT or k == ast.N_INDEX or k == ast.N_DEREF or k == ast.N_FIELD or k == ast.N_CALL
            or k == ast.N_ADDROF or k == ast.N_MEMREAD or k == ast.N_SIZEOF or k == ast.N_ARRAYLIT
            or k == ast.N_STRUCTINIT or k == ast.N_VOID
    }

    ; an operand: parenthesized unless simple
    sub operand(^^ast.Node e) {
        if is_simple(e)
            expression(e)
        else {
            out.putc('(')
            expression(e)
            out.putc(')')
        }
    }

    sub expression(^^ast.Node e) {
        if e == 0 {
            out.puts("?missing?")
            return
        }
        when e.kind {
            ast.N_INT, ast.N_FLOAT -> out.puts(e.name)
            ast.N_STR, ast.N_CHAR -> {
                if e.a != 0 {
                    out.puts(e.a.name)
                    out.putc(':')
                }
                if e.kind == ast.N_STR
                    out.putc('"')
                else
                    out.putc('\'')
                out.puts(e.name)
                if e.kind == ast.N_STR
                    out.putc('"')
                else
                    out.putc('\'')
            }
            ast.N_BOOL -> {
                if e.value != 0
                    out.puts("true")
                else
                    out.puts("false")
            }
            ast.N_ARRAYLIT -> {
                if e.flags & ast.F_EMPTYARRAY != 0
                    out.puts("[]")
                else {
                    out.putc('[')
                    list(e.a)
                    out.putc(']')
                }
            }
            ast.N_IDENT -> out.puts(e.name)
            ast.N_VOID -> out.puts("void")
            ast.N_INDEX -> {
                operand(e.a)
                out.putc('[')
                list(e.b)
                out.putc(']')
            }
            ast.N_DEREF -> {
                operand(e.a)
                out.puts("^^")
            }
            ast.N_FIELD -> {
                operand(e.a)
                out.putc('.')
                out.puts(e.name)
            }
            ast.N_BINARY -> {
                operand(e.a)
                out.putc(' ')
                opname(e.op)
                out.putc(' ')
                operand(e.b)
            }
            ast.N_UNARY -> {
                opname(e.op)
                if e.op == token.T_KW_NOT
                    out.putc(' ')
                operand(e.a)
            }
            ast.N_RANGE -> {
                operand(e.a)
                out.putc(' ')
                opname(e.op)
                out.putc(' ')
                operand(e.b)
                if e.c != 0 {
                    out.puts(" step ")
                    operand(e.c)
                }
            }
            ast.N_CALL -> {
                expression(e.a)
                out.putc('(')
                list(e.b)
                out.putc(')')
            }
            ast.N_CAST -> {
                operand(e.a)
                out.puts(" as ")
                type(e.b)
            }
            ast.N_ADDROF -> {
                opname(e.op)
                expression(e.a)
                if e.b != 0 {
                    out.putc('[')
                    expression(e.b)
                    out.putc(']')
                }
            }
            ast.N_MEMREAD -> {
                out.puts("@(")
                expression(e.a)
                out.putc(')')
            }
            ast.N_SIZEOF -> {
                out.puts("sizeof(")
                if e.a.kind == ast.N_TYPE
                    type(e.a)
                else
                    expression(e.a)
                out.putc(')')
            }
            ast.N_IFEXPR -> {
                out.puts("if ")
                expression(e.a)
                out.puts(" then ")
                operand(e.b)
                out.puts(" else ")
                operand(e.c)
            }
            ast.N_BRANCHEXPR -> {
                opname(e.op)
                out.putc(' ')
                operand(e.b)
                out.puts(" else ")
                operand(e.c)
            }
            ast.N_STRUCTINIT -> {
                if e.flags & ast.F_POINTER != 0
                    out.puts("^^")
                out.puts(e.name)
                out.puts(": [")
                if e.flags & ast.F_NAMED != 0 {
                    ^^ast.Node f = e.a
                    while f != 0 {
                        out.puts(f.name)
                        out.putc('=')
                        expression(f.a)
                        if f.next != 0
                            out.puts(", ")
                        f = f.next
                    }
                }
                else
                    list(e.a)
                out.putc(']')
            }
            ast.N_TUPLE -> list(e.a)
            ast.N_ASSIGN -> assignment(e)
            else -> {
                out.puts("?")
                out.puts(ast.names[e.kind])
                out.putc('?')
            }
        }
    }
}
