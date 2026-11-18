; The parser: recursive descent over the token array of one file, building
; the AST of ast.p8.  Expressions use precedence climbing; see binop_level().
; The parser is permissive where the grammar is fussy (newlines before an
; opening brace, postfix operators on any primary): the semantic phase
; rejects what the language doesn't allow.  All subroutines here recurse
; through parse_expression() and parse_statements(), so their locals are
; scalars only.

%import ast
%import token
%import lexer
%import strtab
%import buf
%import diag

parser {
    %option ignore_unused

    const ubyte MAX_ERRORS = 30
    const ubyte OP_NOT_IN = 255         ; pseudo operator kind for "not in"

    ^^token.Token toks = 0
    long pos = 0
    long count = 0
    ^^source.File file = 0
    ubyte fileindex = 0
    ^^buf.Buf scratch = 0

    ; Parses the tokens of one file into a MODULE node.
    sub parse(^^lexer.Tokens t) -> ^^ast.Node {
        toks = t.items
        count = t.count
        pos = 0
        file = t.file
        fileindex = lsb(t.file.index)
        if scratch == 0
            scratch = buf.new(64)
        return parse_module()
    }

    ; ---- token access ----

    sub cur() -> ^^token.Token {
        return toks + pos
    }

    sub kind() -> ubyte {
        ^^token.Token t = toks + pos
        return t.kind
    }

    sub kind_at(long offset) -> ubyte {
        long p = pos + offset
        if p >= count
            p = count - 1
        ^^token.Token t = toks + p
        return t.kind
    }

    sub advance() {
        if pos < count - 1
            pos++
    }

    sub accept(ubyte k) -> bool {
        if kind() == k {
            advance()
            return true
        }
        return false
    }

    sub skip_eol() {
        while kind() == token.T_EOL
            advance()
    }

    sub is_ident_kind(ubyte k) -> bool {
        return k == token.T_IDENT or token.is_identifier_keyword(k)
    }

    sub at_ident() -> bool {
        return is_ident_kind(kind())
    }

    sub is_basetype(ubyte k) -> bool {
        return k >= token.T_KW_UBYTE and k <= token.T_KW_BOOL or k == token.T_KW_POINTER
    }

    sub is_branch_kw(ubyte k) -> bool {
        return k >= token.T_KW_IF_CS and k <= token.T_KW_IF_VC
    }

    ; ---- errors ----

    sub error(str message) {
        error_near(message, true)
    }

    sub error_near(str message, bool show_token) {
        ^^token.Token t = cur()
        buf.clear(scratch)
        buf.add_str(scratch, message)
        if show_token {
            buf.add_str(scratch, " near ")
            describe_token(t)
        }
        diag.error_at(file, t.line, t.col, scratch.data)
        if diag.errors >= MAX_ERRORS {
            diag.error_at(file, t.line, t.col, "too many errors")
            out.exit(1)
        }
    }

    sub describe_token(^^token.Token t) {
        ubyte k = t.kind
        if k == token.T_EOF
            buf.add_str(scratch, "end of file")
        else if k == token.T_EOL
            buf.add_str(scratch, "end of line")
        else if token.is_keyword(k) {
            buf.add_byte(scratch, '\'')
            buf.add_str(scratch, t.text)
            buf.add_byte(scratch, '\'')
        }
        else if token.is_punct(k) {
            buf.add_byte(scratch, '\'')
            buf.add_str(scratch, token.names[k])
            buf.add_byte(scratch, '\'')
        }
        else {
            buf.add_str(scratch, token.names[k])
            if t.text != 0 and k != token.T_ASMBLOCK {
                buf.add_str(scratch, " '")
                buf.add_bytes(scratch, t.text, t.len)
                buf.add_byte(scratch, '\'')
            }
        }
    }

    ; Reports "expected <what>" when the token isn't k, and skips it when it is.
    sub expect(ubyte k, str what) -> bool {
        if kind() == k {
            advance()
            return true
        }
        buf.clear(scratch)
        buf.add_str(scratch, "expected ")
        buf.add_str(scratch, what)
        buf.add_str(scratch, " near ")
        describe_token(cur())
        ^^token.Token t = cur()
        diag.error_at(file, t.line, t.col, scratch.data)
        if diag.errors >= MAX_ERRORS
            out.exit(1)
        return false
    }

    ; Skips to the end of the line (or a closing brace) after an error.
    sub sync() {
        while kind() != token.T_EOL and kind() != token.T_EOF and kind() != token.T_RBRACE
            advance()
        skip_eol()
    }

    ; ---- node helpers ----

    sub node(ubyte k) -> ^^ast.Node {
        return ast.new(k, cur(), fileindex)
    }

    sub node_at(ubyte k, ^^token.Token t) -> ^^ast.Node {
        return ast.new(k, t, fileindex)
    }

    ; An identifier token's text, advancing past it.
    sub take_ident(str what) -> ^^ubyte {
        if at_ident() {
            ^^token.Token t = cur()
            advance()
            return t.text
        }
        void expect(token.T_IDENT, what)
        return "?"
    }

    ; A dotted name a.b.c as one interned string, advancing past it.
    sub take_dotted(str what) -> ^^ubyte {
        ^^ubyte first = take_ident(what)
        if not (kind() == token.T_DOT and is_ident_kind(kind_at(1)))
            return first
        buf.clear(scratch)
        buf.add_str(scratch, first)
        while kind() == token.T_DOT and is_ident_kind(kind_at(1)) {
            advance()
            ^^token.Token t = cur()
            buf.add_byte(scratch, '.')
            buf.add_bytes(scratch, t.text, t.len)
            advance()
        }
        return strtab.intern(scratch.data, scratch.len as uword)
    }

    ; ---- module level ----

    sub parse_module() -> ^^ast.Node {
        ^^ast.Node m = node(ast.N_MODULE)
        ^^ast.Node tail = 0
        skip_eol()
        while kind() != token.T_EOF {
            ^^ast.Node e = 0
            if kind() == token.T_DIRECTIVE
                e = parse_directive()
            else if at_ident()
                e = parse_block()
            else {
                error("directive or block expected")
                sync()
            }
            if e != 0 {
                if m.a == 0
                    m.a = e
                tail = ast.link(tail, e)
            }
            skip_eol()
        }
        return m
    }

    sub parse_block() -> ^^ast.Node {
        ^^ast.Node b = node(ast.N_BLOCK)
        b.name = take_ident("block name")
        if kind() == token.T_INT
            b.b = parse_primary()
        skip_eol()
        if not expect(token.T_LBRACE, "'{' after block name") {
            sync()
            return b
        }
        b.a = parse_statements()
        void expect(token.T_RBRACE, "'}' at the end of the block")
        return b
    }

    ; Statements up to a closing brace (not consumed) or the end of the file.
    sub parse_statements() -> ^^ast.Node {
        ^^ast.Node head = 0
        ^^ast.Node tail = 0
        repeat {
            skip_eol()
            ubyte k = kind()
            if k == token.T_RBRACE or k == token.T_EOF
                break
            ^^ast.Node s = parse_statement()
            if s != 0 {
                if head == 0
                    head = s
                tail = ast.link(tail, s)
            }
        }
        return head
    }

    ; A statement, or a statement block in braces: both give a list.
    sub parse_body() -> ^^ast.Node {
        skip_eol()
        if kind() == token.T_LBRACE {
            advance()
            ^^ast.Node body = parse_statements()
            void expect(token.T_RBRACE, "'}'")
            return body
        }
        return parse_statement()
    }

    ; ---- statements ----

    sub parse_statement() -> ^^ast.Node {
        ubyte k = kind()
        ubyte flags = 0
        ^^ast.Node n
        ; private/public/inline modifiers, when a declaration follows
        while (k == token.T_KW_PRIVATE or k == token.T_KW_PUBLIC or k == token.T_KW_INLINE) and starts_declaration(kind_at(1)) {
            if k == token.T_KW_PRIVATE
                flags |= ast.F_PRIVATE
            else if k == token.T_KW_PUBLIC
                flags |= ast.F_PUBLIC
            else
                flags |= ast.F_INLINE
            advance()
            k = kind()
        }
        if k == token.T_DIRECTIVE {
            ^^token.Token t = cur()
            if is_asm_directive(t.text) and (kind_at(1) == token.T_ASMBLOCK or (kind_at(1) == token.T_EOL and kind_at(2) == token.T_ASMBLOCK))
                return parse_inline_asm()
            return parse_directive()
        }
        if k == token.T_KW_SUB
            return parse_sub(flags)
        if k == token.T_KW_ASMSUB
            return parse_asmsub(flags)
        if k == token.T_KW_EXTSUB
            return parse_extsub(flags)
        if k == token.T_KW_STRUCT or k == token.T_KW_UNION
            return parse_struct(flags)
        if k == token.T_KW_ENUM
            return parse_enum(flags)
        if k == token.T_KW_ALIAS
            return parse_alias(flags)
        if k == token.T_KW_CONST or is_basetype(k) or k == token.T_CARETCARET or k == token.T_AMP
            return parse_vardecl(flags)
        if k == token.T_KW_IF
            return parse_if()
        if is_branch_kw(k)
            return parse_branch()
        if k == token.T_KW_WHILE
            return parse_while()
        if k == token.T_KW_DO
            return parse_until()
        if k == token.T_KW_FOR
            return parse_for()
        if k == token.T_KW_REPEAT or k == token.T_KW_UNROLL
            return parse_repeat()
        if k == token.T_KW_WHEN
            return parse_when()
        if k == token.T_KW_RETURN
            return parse_return()
        if k == token.T_KW_BREAK {
            n = node(ast.N_BREAK)
            advance()
            return n
        }
        if k == token.T_KW_CONTINUE {
            n = node(ast.N_CONTINUE)
            advance()
            return n
        }
        if k == token.T_KW_GOTO {
            n = node(ast.N_GOTO)
            advance()
            n.a = parse_expression()
            return n
        }
        if k == token.T_KW_DEFER {
            n = node(ast.N_DEFER)
            advance()
            n.a = parse_body()
            return n
        }
        if k == token.T_KW_SWAP
            return parse_swap()
        if k == token.T_KW_ON and kind_at(1) != token.T_ASSIGN and kind_at(1) != token.T_DOT and kind_at(1) != token.T_LPAREN and kind_at(1) != token.T_LBRACKET and kind_at(1) != token.T_COLON
            return parse_ongoto()
        if at_ident() {
            if kind_at(1) == token.T_COLON {
                n = node(ast.N_LABEL)
                n.name = take_ident("label")
                advance()
                return n
            }
            if looks_like_declaration()
                return parse_vardecl(flags)
        }
        if at_ident() or k == token.T_LPAREN or k == token.T_AT or k == token.T_KW_VOID
            return parse_simple_statement()
        error("statement expected")
        sync()
        return 0
    }

    sub starts_declaration(ubyte k) -> bool {
        return k == token.T_KW_SUB or k == token.T_KW_ASMSUB or k == token.T_KW_EXTSUB or k == token.T_KW_INLINE
            or k == token.T_KW_STRUCT or k == token.T_KW_UNION or k == token.T_KW_ENUM or k == token.T_KW_ALIAS
            or k == token.T_KW_CONST or is_basetype(k) or k == token.T_CARETCARET or k == token.T_AMP
            or k == token.T_IDENT or k == token.T_KW_PUBLIC or k == token.T_KW_PRIVATE
    }

    sub is_asm_directive(^^ubyte name) -> bool {
        return name == strtab.intern_cstr("asm") or name == strtab.intern_cstr("ir")
    }

    ; At an identifier: is this "Type name", "Type[n] name" or "Type @tag name"?
    sub looks_like_declaration() -> bool {
        long j = 1
        while kind_at(j) == token.T_DOT and is_ident_kind(kind_at(j + 1))
            j += 2
        ubyte k = kind_at(j)
        if k == token.T_LBRACKET {
            uword depth = 0
            repeat {
                k = kind_at(j)
                if k == token.T_LBRACKET
                    depth++
                else if k == token.T_RBRACKET {
                    depth--
                    if depth == 0 {
                        j++
                        break
                    }
                }
                else if k == token.T_EOL or k == token.T_EOF
                    return false
                j++
            }
            k = kind_at(j)
            if k == token.T_LBRACKET       ; a second dimension
                return looks_like_declaration_after(j)
        }
        return is_ident_kind(k) or k == token.T_TAG
    }

    sub looks_like_declaration_after(long j) -> bool {
        uword depth = 0
        repeat {
            ubyte k = kind_at(j)
            if k == token.T_LBRACKET
                depth++
            else if k == token.T_RBRACKET {
                depth--
                if depth == 0 {
                    j++
                    break
                }
            }
            else if k == token.T_EOL or k == token.T_EOF
                return false
            j++
        }
        ubyte after = kind_at(j)
        return is_ident_kind(after) or after == token.T_TAG
    }

    sub parse_inline_asm() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_ASM)
        ^^token.Token t = cur()
        n.name = t.text
        advance()
        skip_eol()
        t = cur()
        n.extra = t.text
        n.value = t.value
        advance()
        return n
    }

    sub parse_directive() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_DIRECTIVE)
        ^^token.Token t = cur()
        n.name = t.text
        advance()
        if accept(token.T_BANG)
            n.flags |= ast.F_BANG
        ^^ast.Node tail = 0
        if kind() == token.T_LPAREN {
            ; a name list in parentheses, possibly over several lines
            n.flags |= ast.F_NAMED
            advance()
            skip_eol()
            while kind() != token.T_RPAREN and kind() != token.T_EOF {
                ^^ast.Node id = node(ast.N_IDENT)
                id.name = take_dotted("name")
                if n.a == 0
                    n.a = id
                tail = ast.link(tail, id)
                if not accept(token.T_COMMA)
                    break
                skip_eol()
            }
            skip_eol()
            void expect(token.T_RPAREN, "')' after the name list")
            return n
        }
        while kind() != token.T_EOL and kind() != token.T_EOF and kind() != token.T_RBRACE {
            ^^ast.Node arg = parse_expression()
            if arg == 0
                break
            if n.a == 0
                n.a = arg
            tail = ast.link(tail, arg)
            if not accept(token.T_COMMA)
                break
        }
        return n
    }

    ; const/var/memory declarations: [const] type [dims] @tags names [= value]
    sub parse_vardecl(ubyte flags) -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_VARDECL)
        n.flags = flags
        bool needs_init = false
        if accept(token.T_KW_CONST) {
            n.op = token.T_KW_CONST
            needs_init = true
            ; the type is optional for a const
            if not (at_ident() and (kind_at(1) == token.T_ASSIGN or kind_at(1) == token.T_COMMA))
                n.a = parse_type()
        }
        else {
            if accept(token.T_AMP) {
                n.op = token.T_AMP
                needs_init = true
            }
            n.a = parse_type()
        }
        ^^ast.Node tail = 0
        while kind() == token.T_TAG {
            ^^ast.Node tag = node(ast.N_TAG)
            ^^token.Token t = cur()
            tag.name = t.text
            advance()
            if n.d == 0
                n.d = tag
            tail = ast.link(tail, tag)
        }
        tail = 0
        repeat {
            ^^ast.Node id = node(ast.N_IDENT)
            id.name = take_ident("variable name")
            if n.c == 0
                n.c = id
            tail = ast.link(tail, id)
            if not accept(token.T_COMMA)
                break
        }
        if accept(token.T_ASSIGN)
            n.b = parse_tuple_or_expression()
        else if needs_init
            error("'=' and a value expected")
        return n
    }

    ; expression, or several separated by commas as a TUPLE
    sub parse_tuple_or_expression() -> ^^ast.Node {
        ^^token.Token start = cur()
        ^^ast.Node e = parse_expression()
        if kind() != token.T_COMMA
            return e
        ^^ast.Node t = node_at(ast.N_TUPLE, start)
        t.a = e
        ^^ast.Node tail = e
        while accept(token.T_COMMA) {
            skip_eol()
            e = parse_expression()
            if e == 0
                break
            tail = ast.link(tail, e)
        }
        return t
    }

    ; type: [^^] basetype | ^^ name | name, then [n], [n,m], [n][m] or []
    sub parse_type() -> ^^ast.Node {
        ^^ast.Node t = node(ast.N_TYPE)
        if accept(token.T_CARETCARET)
            t.flags |= ast.F_POINTER
        ubyte k = kind()
        if is_basetype(k) {
            t.op = k
            advance()
        }
        else if at_ident() {
            t.op = token.T_IDENT
            t.name = take_dotted("type name")
        }
        else {
            void expect(token.T_IDENT, "a type")
            return t
        }
        ; array dimensions
        ^^ast.Node tail = 0
        while kind() == token.T_LBRACKET {
            advance()
            if accept(token.T_RBRACKET) {
                t.flags |= ast.F_EMPTYARRAY
                break
            }
            repeat {
                ^^ast.Node dim = parse_expression()
                if dim == 0
                    break
                if t.a == 0
                    t.a = dim
                tail = ast.link(tail, dim)
                if not accept(token.T_COMMA)
                    break
            }
            void expect(token.T_RBRACKET, "']' after the array size")
        }
        return t
    }

    sub parse_params() -> ^^ast.Node {
        ; after '(' up to ')': type [@tag] name [@register] , ...
        ^^ast.Node head = 0
        ^^ast.Node tail = 0
        skip_eol()
        while kind() != token.T_RPAREN and kind() != token.T_EOF {
            ^^ast.Node p = node(ast.N_PARAM)
            p.a = parse_type()
            if p.a != 0 and p.a.flags & ast.F_EMPTYARRAY != 0 and p.a.flags & ast.F_POINTER == 0
                    and (p.a.op == token.T_KW_UBYTE or p.a.op == token.T_KW_BYTE or p.a.op == token.T_KW_BOOL) {
                ; "ubyte[] name": an array is passed by its address; the parameter is a
                ; pointer to its elements
                p.a.flags = (p.a.flags & ~ast.F_EMPTYARRAY) | ast.F_POINTER
                p.a.a = 0
            }
            ^^ast.Node tagtail = 0
            while kind() == token.T_TAG {
                ^^ast.Node tag = node(ast.N_TAG)
                ^^token.Token t = cur()
                tag.name = t.text
                advance()
                if p.d == 0
                    p.d = tag
                tagtail = ast.link(tagtail, tag)
            }
            p.name = take_ident("parameter name")
            if accept(token.T_AT) {
                ^^ast.Node reg = node(ast.N_IDENT)
                reg.name = take_ident("register")
                p.b = reg
            }
            if head == 0
                head = p
            tail = ast.link(tail, p)
            if not accept(token.T_COMMA)
                break
            skip_eol()
        }
        skip_eol()
        return head
    }

    ; -> type [@register], ...
    sub parse_returns() -> ^^ast.Node {
        ^^ast.Node head = 0
        ^^ast.Node tail = 0
        if not accept(token.T_ARROW)
            return 0
        repeat {
            skip_eol()
            ^^ast.Node t = parse_type()
            if accept(token.T_AT) {
                ^^ast.Node reg = node(ast.N_IDENT)
                reg.name = take_ident("register")
                t.b = reg
            }
            if head == 0
                head = t
            tail = ast.link(tail, t)
            if not accept(token.T_COMMA)
                break
        }
        return head
    }

    sub parse_sub(ubyte flags) -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_SUB)
        n.flags = flags
        advance()
        n.name = take_ident("subroutine name")
        void expect(token.T_LPAREN, "'(' after the subroutine name")
        n.a = parse_params()
        void expect(token.T_RPAREN, "')' after the parameters")
        n.b = parse_returns()
        skip_eol()
        if expect(token.T_LBRACE, "'{' to start the subroutine body") {
            n.c = parse_statements()
            void expect(token.T_RBRACE, "'}' at the end of the subroutine")
        }
        return n
    }

    ; clobbers(A,X) -> stored as an IDENT list
    sub parse_clobbers() -> ^^ast.Node {
        ^^ast.Node head = 0
        ^^ast.Node tail = 0
        if not accept(token.T_KW_CLOBBERS)
            return 0
        void expect(token.T_LPAREN, "'(' after clobbers")
        while at_ident() {
            ^^ast.Node id = node(ast.N_IDENT)
            id.name = take_ident("register")
            if head == 0
                head = id
            tail = ast.link(tail, id)
            if not accept(token.T_COMMA)
                break
        }
        void expect(token.T_RPAREN, "')' after the clobbered registers")
        return head
    }

    sub parse_asmsub(ubyte flags) -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_ASMSUB)
        n.flags = flags
        advance()
        n.name = take_ident("asmsub name")
        void expect(token.T_LPAREN, "'(' after the asmsub name")
        n.a = parse_params()
        void expect(token.T_RPAREN, "')' after the parameters")
        n.d = parse_clobbers()
        n.b = parse_returns()
        skip_eol()
        if expect(token.T_LBRACE, "'{' to start the asmsub body") {
            n.c = parse_statements()
            void expect(token.T_RBRACE, "'}' at the end of the asmsub")
        }
        return n
    }

    sub parse_extsub(ubyte flags) -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_EXTSUB)
        n.flags = flags
        advance()
        if at_ident() and kind_at(1) == token.T_LPAREN {
            ; an external routine without an address (a C function)
            n.name = take_ident("extsub name")
            advance()
            n.a = parse_params()
            void expect(token.T_RPAREN, "')' after the parameters")
            n.b = parse_returns()
            return n
        }
        if kind() == token.T_TAG {
            ; @bank <constant or variable>
            advance()
            if kind() == token.T_INT
                n.d = parse_primary()
            else {
                ^^ast.Node bank = node(ast.N_IDENT)
                bank.name = take_dotted("bank")
                n.d = bank
            }
        }
        n.c = parse_expression()
        void expect(token.T_ASSIGN, "'=' after the extsub address")
        n.name = take_ident("extsub name")
        void expect(token.T_LPAREN, "'(' after the extsub name")
        n.a = parse_params()
        void expect(token.T_RPAREN, "')' after the parameters")
        ^^ast.Node clob = parse_clobbers()
        n.b = parse_returns()
        if clob != 0 {
            ; without a return type there is nowhere to hang them: make an empty TYPE
            if n.b == 0 {
                n.b = node(ast.N_TYPE)
                n.b.op = token.T_KW_VOID
            }
            n.b.d = clob
        }
        return n
    }

    sub parse_struct(ubyte flags) -> ^^ast.Node {
        ^^ast.Node n
        if kind() == token.T_KW_STRUCT
            n = node(ast.N_STRUCT)
        else
            n = node(ast.N_UNION)
        n.flags = flags
        advance()
        n.name = take_ident("struct name")
        skip_eol()
        if not expect(token.T_LBRACE, "'{' after the struct name") {
            sync()
            return n
        }
        ^^ast.Node tail = 0
        repeat {
            skip_eol()
            if kind() == token.T_RBRACE or kind() == token.T_EOF
                break
            ^^ast.Node f = node(ast.N_VARDECL)
            f.a = parse_type()
            ^^ast.Node nametail = 0
            repeat {
                ^^ast.Node id = node(ast.N_IDENT)
                id.name = take_ident("field name")
                if f.c == 0
                    f.c = id
                nametail = ast.link(nametail, id)
                if not accept(token.T_COMMA)
                    break
            }
            if n.a == 0
                n.a = f
            tail = ast.link(tail, f)
            ; (the next field may be on the same line: upstream's grammar asks for no line end)
        }
        void expect(token.T_RBRACE, "'}' at the end of the struct")
        return n
    }

    sub parse_enum(ubyte flags) -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_ENUM)
        n.flags = flags
        advance()
        n.name = take_ident("enum name")
        skip_eol()
        if not expect(token.T_LBRACE, "'{' after the enum name") {
            sync()
            return n
        }
        ^^ast.Node tail = 0
        repeat {
            skip_eol()
            if kind() == token.T_RBRACE or kind() == token.T_EOF
                break
            ^^ast.Node m = node(ast.N_ENUMMEMBER)
            m.name = take_ident("enum member")
            if accept(token.T_ASSIGN)
                m.a = parse_expression()
            if n.a == 0
                n.a = m
            tail = ast.link(tail, m)
            if not accept(token.T_COMMA)
                break
        }
        skip_eol()
        void expect(token.T_RBRACE, "'}' at the end of the enum")
        return n
    }

    sub parse_alias(ubyte flags) -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_ALIAS)
        n.flags = flags
        advance()
        n.name = take_ident("alias name")
        void expect(token.T_ASSIGN, "'=' after the alias name")
        if is_basetype(kind()) or kind() == token.T_CARETCARET
            n.a = parse_type()
        else {
            ^^ast.Node id = node(ast.N_IDENT)
            id.name = take_dotted("alias target")
            n.a = id
        }
        return n
    }

    sub parse_if() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_IF)
        advance()
        n.a = parse_expression()
        n.b = parse_body()
        n.c = parse_else()
        return n
    }

    ; an else part, possibly after a newline
    sub parse_else() -> ^^ast.Node {
        if kind() == token.T_EOL and kind_at(1) == token.T_KW_ELSE
            advance()
        if accept(token.T_KW_ELSE)
            return parse_body()
        return 0
    }

    sub parse_branch() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_BRANCH)
        n.op = kind()
        advance()
        n.b = parse_body()
        n.c = parse_else()
        return n
    }

    sub parse_while() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_WHILE)
        advance()
        n.a = parse_expression()
        n.b = parse_body()
        return n
    }

    sub parse_until() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_UNTIL)
        advance()
        n.a = parse_body()
        skip_eol()
        void expect(token.T_KW_UNTIL, "'until' after the loop body")
        n.b = parse_expression()
        return n
    }

    sub parse_for() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_FOR)
        advance()
        ; an optional type before the loop variable
        if is_basetype(kind()) or kind() == token.T_CARETCARET or (at_ident() and is_ident_kind(kind_at(1)))
            n.d = parse_type()
        ^^ast.Node v = node(ast.N_IDENT)
        v.name = take_dotted("loop variable")
        n.a = v
        void expect(token.T_KW_IN, "'in' after the loop variable")
        n.b = parse_expression()
        ^^ast.Node tail = n.d
        repeat {
            ubyte k = kind()
            if k != token.T_KW_VIA and k != token.T_KW_UNTIL and k != token.T_KW_STEP
                break
            ^^ast.Node opt = node(ast.N_FOROPT)
            opt.op = k
            advance()
            if k == token.T_KW_VIA {
                void expect(token.T_DOT, "'.' after via")
                ^^ast.Node f = node(ast.N_IDENT)
                f.name = take_ident("field name")
                opt.a = f
            }
            else
                opt.a = parse_expression()
            if n.d == 0
                n.d = opt
            tail = ast.link(tail, opt)
        }
        n.c = parse_body()
        return n
    }

    sub parse_repeat() -> ^^ast.Node {
        ^^ast.Node n
        if kind() == token.T_KW_REPEAT
            n = node(ast.N_REPEAT)
        else
            n = node(ast.N_UNROLL)
        advance()
        if kind() != token.T_EOL and kind() != token.T_LBRACE
            n.a = parse_expression()
        n.b = parse_body()
        return n
    }

    sub parse_when() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_WHEN)
        advance()
        n.a = parse_expression()
        skip_eol()
        if not expect(token.T_LBRACE, "'{' after the when expression") {
            sync()
            return n
        }
        ^^ast.Node tail = 0
        repeat {
            skip_eol()
            if kind() == token.T_RBRACE or kind() == token.T_EOF
                break
            ^^ast.Node c = node(ast.N_CHOICE)
            if not accept(token.T_KW_ELSE) {
                ^^ast.Node vtail = 0
                repeat {
                    ^^ast.Node v = parse_expression()
                    if v == 0
                        break
                    if c.a == 0
                        c.a = v
                    vtail = ast.link(vtail, v)
                    if not accept(token.T_COMMA)
                        break
                    skip_eol()
                }
            }
            if not expect(token.T_ARROW, "'->' after the when choice") {
                sync()
                continue
            }
            c.b = parse_body()
            if n.b == 0
                n.b = c
            tail = ast.link(tail, c)
        }
        void expect(token.T_RBRACE, "'}' at the end of the when statement")
        return n
    }

    sub parse_return() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_RETURN)
        advance()
        ubyte k = kind()
        if k == token.T_EOL or k == token.T_EOF or k == token.T_RBRACE or k == token.T_KW_ELSE
            return n
        ^^ast.Node tail = 0
        repeat {
            ^^ast.Node v = parse_expression()
            if v == 0
                break
            if n.a == 0
                n.a = v
            tail = ast.link(tail, v)
            if not accept(token.T_COMMA)
                break
        }
        return n
    }

    sub parse_swap() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_SWAP)
        advance()
        void expect(token.T_LPAREN, "'(' after swap")
        n.a = parse_postfix()
        void expect(token.T_COMMA, "',' between the swap targets")
        n.b = parse_postfix()
        void expect(token.T_RPAREN, "')' after the swap targets")
        return n
    }

    sub parse_ongoto() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_ONGOTO)
        advance()
        n.a = parse_expression()
        if kind() == token.T_KW_GOTO or kind() == token.T_KW_CALL {
            n.op = kind()
            advance()
        }
        else
            void expect(token.T_KW_GOTO, "'goto' or 'call' after the on expression")
        void expect(token.T_LPAREN, "'(' before the jump targets")
        skip_eol()
        ^^ast.Node tail = 0
        while kind() != token.T_RPAREN and kind() != token.T_EOF {
            ^^ast.Node id = node(ast.N_IDENT)
            id.name = take_dotted("jump target")
            if n.b == 0
                n.b = id
            tail = ast.link(tail, id)
            if not accept(token.T_COMMA)
                break
            skip_eol()
        }
        skip_eol()
        void expect(token.T_RPAREN, "')' after the jump targets")
        n.c = parse_else()
        return n
    }

    ; assignment, augmented assignment, ++/--, or a call statement
    sub parse_simple_statement() -> ^^ast.Node {
        ^^token.Token start = cur()
        ^^ast.Node target
        ^^ast.Node n
        if accept(token.T_KW_VOID) {
            if at_ident() {
                ; void call(...)
                ^^ast.Node cs = node_at(ast.N_CALLSTMT, start)
                cs.flags |= ast.F_VOID
                cs.a = parse_postfix()
                if cs.a == 0 or cs.a.kind != ast.N_CALL
                    error("call expected after void")
                return cs
            }
            target = node_at(ast.N_VOID, start)
        }
        else
            target = parse_postfix()
        if target == 0 {
            sync()
            return 0
        }
        ubyte k = kind()
        if k == token.T_ASSIGN or k == token.T_COMMA {
            n = node_at(ast.N_ASSIGN, start)
            n.a = target
            ^^ast.Node tail = target
            while accept(token.T_COMMA) {
                ^^ast.Node t2
                if accept(token.T_KW_VOID)
                    t2 = node_at(ast.N_VOID, start)
                else
                    t2 = parse_postfix()
                if t2 == 0
                    break
                tail = ast.link(tail, t2)
            }
            void expect(token.T_ASSIGN, "'=' after the assignment target")
            n.b = parse_assignment_value()
            return n
        }
        if k >= token.T_PLUSEQ and k <= token.T_SHREQ {
            n = node_at(ast.N_AUGASSIGN, start)
            n.op = k
            advance()
            n.a = target
            n.b = parse_expression()
            return n
        }
        if k == token.T_PLUSPLUS or k == token.T_MINUSMINUS {
            n = node_at(ast.N_INCDEC, start)
            n.op = k
            advance()
            n.a = target
            return n
        }
        if target.kind == ast.N_CALL {
            n = node_at(ast.N_CALLSTMT, start)
            n.a = target
            return n
        }
        error("'=' expected after the assignment target")
        sync()
        return 0
    }

    ; the right side of '=': a value, a tuple, or another assignment (a = b = 0)
    sub parse_assignment_value() -> ^^ast.Node {
        ^^token.Token start = cur()
        ^^ast.Node v = parse_tuple_or_expression()
        if kind() == token.T_ASSIGN and v != 0 {
            advance()
            ^^ast.Node n = node_at(ast.N_ASSIGN, start)
            n.a = v
            n.b = parse_assignment_value()
            return n
        }
        return v
    }

    ; ---- expressions ----

    ; Precedence of a binary operator token kind; 0 when it is not one.
    ; Low binds loosest: xor < or < and < in < to/downto < == != < < > <= >= < | < ^ < & < << >> < + - < * / %
    sub binop_level(ubyte k) -> ubyte {
        if k == token.T_KW_XOR
            return 1
        if k == token.T_KW_OR
            return 2
        if k == token.T_KW_AND
            return 3
        if k == token.T_KW_IN
            return 5
        if k == token.T_KW_TO or k == token.T_KW_DOWNTO
            return 6
        if k == token.T_EQ or k == token.T_NE
            return 7
        if k == token.T_LT or k == token.T_GT or k == token.T_LE or k == token.T_GE
            return 8
        if k == token.T_PIPE
            return 9
        if k == token.T_CARET
            return 10
        if k == token.T_AMP
            return 11
        if k == token.T_SHL or k == token.T_SHR
            return 12
        if k == token.T_PLUS or k == token.T_MINUS
            return 13
        if k == token.T_STAR or k == token.T_SLASH or k == token.T_PERCENT
            return 14
        return 0
    }

    ; the operator at the current position, looking past a line end for one
    ; (except '&', which starts a memory-mapped declaration on the next line)
    sub binop_here() -> ubyte {
        ubyte k = kind()
        if k == token.T_EOL {
            k = kind_at(1)
            if k == token.T_AMP
                return 0
            if k == token.T_MINUS or k == token.T_PLUS {
                ; An operator may stand at the start of the next line, but so may the
                ; sign of a value there: a choice of a when ("-1 -> ...").  The line is
                ; one of those when it has the arrow in it.
                uword ahead = 2
                repeat {
                    ubyte ak = kind_at(ahead)
                    if ak == token.T_ARROW
                        return 0
                    if ak == token.T_EOL or ak == token.T_EOF or ak == token.T_LBRACE or ak == token.T_RBRACE
                        break
                    ahead++
                }
            }
        }
        if k == token.T_KW_NOT {
            if kind() == token.T_EOL {
                if kind_at(2) == token.T_KW_IN
                    return OP_NOT_IN
            }
            else if kind_at(1) == token.T_KW_IN
                return OP_NOT_IN
            return 0
        }
        if binop_level(k) == 0
            return 0
        return k
    }

    sub op_level(ubyte op) -> ubyte {
        if op == OP_NOT_IN
            return 5
        return binop_level(op)
    }

    sub parse_expression() -> ^^ast.Node {
        return parse_binary(1)
    }

    sub parse_binary(ubyte minlevel) -> ^^ast.Node {
        ^^token.Token start = cur()
        ^^ast.Node left = parse_unary()
        if left == 0
            return 0
        repeat {
            ; 'as type' is a postfix at the lowest level: it applies to the operand chain
            ; to its left at the top level of an expression, but not inside a right operand.
            ; This is what the upstream grammar does, so "x as word - y" is "(x as word) - y"
            ; and "a + b as uword" is "(a + b) as uword".
            if kind() == token.T_KW_AS and minlevel <= 1 {
                advance()
                ^^ast.Node c = node_at(ast.N_CAST, start)
                c.a = left
                c.b = parse_type()
                left = c
                continue
            }
            ubyte op = binop_here()
            if op == 0
                break
            ubyte level = op_level(op)
            if level < minlevel
                break
            skip_eol()
            if op == OP_NOT_IN
                advance()
            advance()
            skip_eol()
            if op == token.T_KW_TO or op == token.T_KW_DOWNTO {
                ^^ast.Node r = node_at(ast.N_RANGE, start)
                r.op = op
                r.a = left
                r.b = parse_binary(level + 1)
                if accept(token.T_KW_STEP)
                    r.c = parse_binary(level + 1)
                left = r
            }
            else {
                ^^ast.Node b = node_at(ast.N_BINARY, start)
                b.op = op
                b.a = left
                b.b = parse_binary(level + 1)
                left = b
            }
        }
        return left
    }

    sub parse_unary() -> ^^ast.Node {
        ubyte k = kind()
        ^^ast.Node u
        if k == token.T_MINUS or k == token.T_PLUS or k == token.T_TILDE {
            u = node(ast.N_UNARY)
            u.op = k
            advance()
            u.a = parse_unary()
            return u
        }
        if k == token.T_KW_NOT {
            u = node(ast.N_UNARY)
            u.op = k
            advance()
            u.a = parse_binary(5)
            return u
        }
        return parse_postfix()
    }

    ; primary followed by [index], ^^, .field
    sub parse_postfix() -> ^^ast.Node {
        ^^token.Token start = cur()
        ^^ast.Node e = parse_primary()
        if e == 0
            return 0
        repeat {
            ubyte k = kind()
            if k == token.T_LBRACKET {
                advance()
                ^^ast.Node ix = node_at(ast.N_INDEX, start)
                ix.a = e
                ix.b = parse_expression()
                if accept(token.T_COMMA) {
                    ^^ast.Node second = parse_expression()
                    if ix.b != 0
                        ix.b.next = second
                }
                void expect(token.T_RBRACKET, "']' after the index")
                e = ix
            }
            else if k == token.T_CARETCARET {
                advance()
                ^^ast.Node d = node_at(ast.N_DEREF, start)
                d.a = e
                e = d
            }
            else if k == token.T_DOT and is_ident_kind(kind_at(1)) {
                advance()
                ^^ast.Node f = node_at(ast.N_FIELD, start)
                f.a = e
                f.name = take_ident("field name")
                e = f
            }
            else
                break
        }
        return e
    }

    sub parse_primary() -> ^^ast.Node {
        ^^token.Token t = cur()
        ubyte k = t.kind
        ^^ast.Node n
        if k == token.T_INT {
            n = node(ast.N_INT)
            n.value = t.value
            n.name = strtab.intern(t.text, t.len)
            advance()
            return n
        }
        if k == token.T_FLOAT {
            n = node(ast.N_FLOAT)
            n.name = t.text
            advance()
            return n
        }
        if k == token.T_STRING or k == token.T_CHAR
            return parse_string_literal(0)
        if k == token.T_KW_TRUE or k == token.T_KW_FALSE {
            n = node(ast.N_BOOL)
            if k == token.T_KW_TRUE
                n.value = 1
            advance()
            return n
        }
        if k == token.T_LBRACKET
            return parse_array_literal()
        if k == token.T_LPAREN {
            advance()
            skip_eol()
            n = parse_expression()
            skip_eol()
            void expect(token.T_RPAREN, "')'")
            return n
        }
        if k == token.T_KW_SIZEOF {
            n = node(ast.N_SIZEOF)
            advance()
            void expect(token.T_LPAREN, "'(' after sizeof")
            if is_basetype(kind()) or kind() == token.T_CARETCARET
                n.a = parse_type()
            else if kind() >= token.T_AMP and kind() <= token.T_AMPLT
                n.a = parse_addressof()
            else {
                ^^ast.Node id = node(ast.N_IDENT)
                id.name = take_dotted("type or variable name")
                n.a = id
            }
            void expect(token.T_RPAREN, "')' after the sizeof argument")
            return n
        }
        if k == token.T_IDENT and kind_at(1) == token.T_LPAREN and strings.compare(cur().text, "offsetof") == 0 {
            ; offsetof(Struct.field): a sizeof node with op 1; its argument is a path, not an expression
            n = node(ast.N_SIZEOF)
            n.op = 1
            advance()
            advance()
            ^^ast.Node field = node(ast.N_IDENT)
            field.name = take_dotted("struct field")
            n.a = field
            void expect(token.T_RPAREN, "')' after the offsetof argument")
            return n
        }
        if k >= token.T_AMP and k <= token.T_AMPLT
            return parse_addressof()
        if k == token.T_AT {
            n = node(ast.N_MEMREAD)
            advance()
            void expect(token.T_LPAREN, "'(' after @")
            n.a = parse_expression()
            void expect(token.T_RPAREN, "')' after the address")
            return n
        }
        if k == token.T_KW_IF {
            n = node(ast.N_IFEXPR)
            advance()
            n.a = parse_expression()
            skip_eol()
            void accept(token.T_KW_THEN)
            skip_eol()
            if kind() == token.T_KW_ELSE and n.a != 0 and n.a.kind == ast.N_BINARY {
                ; "if a < b -1 else 1": without "then", the condition took the value's
                ; sign for a subtraction.  The last + or - on its right side is the sign.
                ^^ast.Node parent = 0
                ^^ast.Node last = n.a
                ^^ast.Node cut = 0
                ^^ast.Node cutparent = 0
                while last != 0 and last.kind == ast.N_BINARY {
                    if last.op == token.T_MINUS or last.op == token.T_PLUS {
                        cut = last
                        cutparent = parent
                    }
                    parent = last
                    last = last.b
                }
                if cut != 0 {
                    ^^ast.Node value = node(ast.N_UNARY)
                    value.op = cut.op
                    value.a = cut.b
                    if cutparent == 0
                        n.a = cut.a
                    else
                        cutparent.b = cut.a
                    n.b = value
                }
                else
                    n.b = parse_expression()
            }
            else
                n.b = parse_expression()
            skip_eol()
            void expect(token.T_KW_ELSE, "'else' in the if expression")
            skip_eol()
            n.c = parse_expression()
            return n
        }
        if is_branch_kw(k) {
            n = node(ast.N_BRANCHEXPR)
            n.op = k
            advance()
            void accept(token.T_KW_THEN)
            n.b = parse_expression()
            skip_eol()
            void expect(token.T_KW_ELSE, "'else' in the condition expression")
            skip_eol()
            n.c = parse_expression()
            return n
        }
        if k == token.T_CARETCARET {
            ; ^^Type : [values]
            n = node(ast.N_STRUCTINIT)
            n.flags |= ast.F_POINTER
            advance()
            n.name = take_dotted("struct type name")
            void expect(token.T_COLON, "':' after the struct type")
            parse_struct_values(n)
            return n
        }
        if is_ident_kind(k) {
            ; encoded literal: iso:"text"
            if kind_at(1) == token.T_COLON and (kind_at(2) == token.T_STRING or kind_at(2) == token.T_CHAR) {
                ^^ast.Node enc = node(ast.N_IDENT)
                enc.name = t.text
                advance()
                advance()
                return parse_string_literal(enc)
            }
            ^^ubyte name = take_dotted("name")
            if kind() == token.T_LPAREN {
                n = node_at(ast.N_CALL, t)
                ^^ast.Node callee = node_at(ast.N_IDENT, t)
                callee.name = name
                n.a = callee
                advance()
                n.b = parse_arguments()
                void expect(token.T_RPAREN, "')' after the arguments")
                return n
            }
            if kind() == token.T_COLON and kind_at(1) == token.T_LBRACKET {
                n = node_at(ast.N_STRUCTINIT, t)
                n.name = name
                advance()
                parse_struct_values(n)
                return n
            }
            n = node_at(ast.N_IDENT, t)
            n.name = name
            return n
        }
        error("expression expected")
        return 0
    }

    sub parse_string_literal(^^ast.Node encoding) -> ^^ast.Node {
        ^^token.Token t = cur()
        ^^ast.Node n
        if t.kind == token.T_STRING
            n = node(ast.N_STR)
        else
            n = node(ast.N_CHAR)
        n.name = t.text
        n.a = encoding
        if encoding != 0 {
            ; the literal starts at its prefix, as upstream reports it
            n.line = encoding.line
            n.col = encoding.col
        }
        advance()
        return n
    }

    sub parse_addressof() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_ADDROF)
        n.op = kind()
        advance()
        ^^ast.Node id = node(ast.N_IDENT)
        id.name = take_dotted("variable name")
        n.a = id
        if accept(token.T_LBRACKET) {
            n.b = parse_expression()
            void expect(token.T_RBRACKET, "']' after the index")
        }
        return n
    }

    ; expressions separated by commas, up to ')' (not consumed); newlines allowed
    sub parse_arguments() -> ^^ast.Node {
        ^^ast.Node head = 0
        ^^ast.Node tail = 0
        skip_eol()
        while kind() != token.T_RPAREN and kind() != token.T_EOF {
            ^^ast.Node e = parse_expression()
            if e == 0
                break
            if head == 0
                head = e
            tail = ast.link(tail, e)
            skip_eol()
            if not accept(token.T_COMMA)
                break
            skip_eol()
        }
        skip_eol()
        return head
    }

    sub parse_array_literal() -> ^^ast.Node {
        ^^ast.Node n = node(ast.N_ARRAYLIT)
        advance()
        if accept(token.T_RBRACKET) {
            n.flags |= ast.F_EMPTYARRAY
            return n
        }
        n.a = parse_list_values()
        void expect(token.T_RBRACKET, "']' at the end of the array")
        return n
    }

    ; values up to ']' (not consumed): commas, newlines and a trailing comma allowed
    sub parse_list_values() -> ^^ast.Node {
        ^^ast.Node head = 0
        ^^ast.Node tail = 0
        skip_eol()
        while kind() != token.T_RBRACKET and kind() != token.T_EOF {
            ^^ast.Node e = parse_expression()
            if e == 0
                break
            if head == 0
                head = e
            tail = ast.link(tail, e)
            skip_eol()
            if not accept(token.T_COMMA)
                break
            skip_eol()
        }
        skip_eol()
        return head
    }

    ; [values] or [name=value, ...] after "Type :"
    sub parse_struct_values(^^ast.Node n) {
        if not expect(token.T_LBRACKET, "'[' after the struct type")
            return
        skip_eol()
        if at_ident() and kind_at(1) == token.T_ASSIGN {
            n.flags |= ast.F_NAMED
            ^^ast.Node tail = 0
            while kind() != token.T_RBRACKET and kind() != token.T_EOF {
                ^^ast.Node f = node(ast.N_NAMEDFIELD)
                f.name = take_ident("field name")
                void expect(token.T_ASSIGN, "'=' after the field name")
                f.a = parse_expression()
                if n.a == 0
                    n.a = f
                tail = ast.link(tail, f)
                skip_eol()
                if not accept(token.T_COMMA)
                    break
                skip_eol()
            }
            skip_eol()
        }
        else
            n.a = parse_list_values()
        void expect(token.T_RBRACKET, "']' at the end of the struct values")
    }
}
