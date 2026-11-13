; The lexer: turns the text of one source file into an array of tokens.
; Newlines are tokens (EOL), since they end statements; a run of newlines,
; blank lines and comment lines gives a single EOL.  Identifiers and most
; literals are interned, so equal spellings share one pointer and keywords
; are recognised by the kind stored on their interned entry.

%import mem
%import strtab
%import buf
%import source
%import token
%import diag

lexer {
    %option ignore_unused

    struct Tokens {
        ^^token.Token items
        ^^source.File file
        long count
        long cap
    }

    ; lexing state for the current file
    ^^ubyte src = 0
    long pos = 0
    long end = 0
    long line_start = 0
    uword line = 1
    ^^source.File file = 0
    ^^Tokens result = 0
    bool keywords_ready = false

    ; statistics
    long total_tokens = 0
    long total_lines = 0

    sub init_keywords() {
        ubyte i = 0
        while i < len(token.keywords) {
            ^^strtab.Sym s = strtab.intern_sym(token.keywords[i], buf.cstr_len(token.keywords[i]) as uword)
            s.kind = token.T_KW_FIRST + i
            i++
        }
        keywords_ready = true
    }

    ; Tokenizes the whole file.  Errors are reported through diag; lexing continues after them.
    sub tokenize(^^source.File f) -> ^^Tokens {
        if not keywords_ready
            init_keywords()
        file = f
        src = f.text
        pos = 0
        end = f.len
        line = 1
        line_start = 0
        result = mem.alloc(sizeof(Tokens))
        result.file = f
        result.cap = f.len / 6 + 32         ; the corpus averages one token per 7 bytes: a little over avoids regrowing
        result.items = mem.alloc(result.cap * sizeof(token.Token))
        result.count = 0
        while pos < end
            scan_token()
        void add(token.T_EOF, 0, 0, pos)
        f.lines = line
        total_tokens += result.count
        total_lines += line
        return result
    }

    ; Appends a token that starts at source position start.
    sub add(ubyte kind, ^^ubyte text, uword length, long start) -> ^^token.Token {
        if result.count >= result.cap {
            long newcap = result.cap * 2
            result.items = mem.grow(result.items, result.cap * sizeof(token.Token), newcap * sizeof(token.Token))
            result.cap = newcap
        }
        ^^token.Token t = result.items + result.count
        result.count++
        t.kind = kind
        t.text = text
        t.len = length
        t.value = 0
        t.line = line
        t.col = (start - line_start + 1) as uword
        return t
    }

    sub error(str message) {
        diag.error_at(file, line, (pos - line_start + 1) as uword, message)
    }

    sub is_letter(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= $80
    }

    sub is_digit(ubyte c) -> bool {
        return c >= '0' and c <= '9'
    }

    sub is_hex_digit(ubyte c) -> bool {
        return is_digit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')
    }

    sub is_ident_char(ubyte c) -> bool {
        return is_letter(c) or is_digit(c) or c == '_'
    }

    ; the byte at pos+offset, or 0 past the end
    sub look(long offset) -> ubyte {
        long p = pos + offset
        if p >= end
            return 0
        return src[p]
    }

    sub newline() {
        line++
        line_start = pos
    }

    sub scan_token() {
        ubyte c = src[pos]
        long start = pos
        if c == ' ' or c == '\t' or c == '\r' {
            pos++
            return
        }
        if c == '\n' {
            add_eol(start)
            pos++
            newline()
            return
        }
        if c == ';' {
            skip_line_comment()
            return
        }
        if c == '/' and look(1) == '*' {
            skip_block_comment()
            return
        }
        if is_letter(c) or c == '_' {
            scan_identifier()
            return
        }
        if is_digit(c) {
            scan_number()
            return
        }
        if c == '.' and is_digit(look(1)) {
            scan_float()
            return
        }
        if c == '$' {
            scan_hex()
            return
        }
        if c == '%' {
            ubyte n = look(1)
            if n == '0' or n == '1' {
                scan_binary()
                return
            }
            ; %name is a directive only where a statement can start; after
            ; an operand it is the remainder operator, as in a%b
            bool at_statement = true
            if result.count != 0 {
                ^^token.Token previous = result.items + (result.count - 1)
                at_statement = previous.kind == token.T_EOL or previous.kind == token.T_LBRACE or previous.kind == token.T_RBRACE
            }
            if not at_statement {
                ; except for inline code after a statement head: "unroll 2 %asm {{"
                if (n == 'a' and look(2) == 's' and look(3) == 'm' and not is_ident_char(look(4))) or (n == 'i' and look(2) == 'r' and not is_ident_char(look(3)))
                    at_statement = true
            }
            if is_letter(n) and at_statement {
                pos++
                long namestart = pos
                while is_ident_char(look(0))
                    pos++
                void add(token.T_DIRECTIVE, strtab.intern(src + namestart, (pos - namestart) as uword), (pos - namestart) as uword, start)
                return
            }
        }
        if c == '"' {
            scan_string()
            return
        }
        if c == '\'' {
            scan_char()
            return
        }
        if c == '{' and look(1) == '{' {
            scan_asm_block()
            return
        }
        if c == '@' {
            ubyte tagc = look(1)
            if (tagc >= 'a' and tagc <= 'z') or is_digit(tagc) {
                pos++
                long tagstart = pos
                while (look(0) >= 'a' and look(0) <= 'z') or is_digit(look(0))
                    pos++
                void add(token.T_TAG, strtab.intern(src + tagstart, (pos - tagstart) as uword), (pos - tagstart) as uword, start)
                return
            }
        }
        scan_punct()
    }

    ; One EOL token for any run of line ends and comment lines.
    sub add_eol(long start) {
        if result.count > 0 {
            ^^token.Token last = result.items + (result.count - 1)
            if last.kind == token.T_EOL
                return
        }
        void add(token.T_EOL, 0, 0, start)
    }

    sub skip_line_comment() {
        while pos < end and src[pos] != '\n'
            pos++
    }

    sub skip_block_comment() {
        ; nested block comments are allowed
        uword depth = 0
        repeat {
            if pos >= end {
                error("unterminated block comment")
                return
            }
            ubyte c = src[pos]
            if c == '/' and look(1) == '*' {
                depth++
                pos += 2
            }
            else if c == '*' and look(1) == '/' {
                depth--
                pos += 2
                if depth == 0
                    return
            }
            else {
                if c == '\n' {
                    pos++
                    newline()
                }
                else
                    pos++
            }
        }
    }

    sub scan_identifier() {
        long start = pos
        pos++
        repeat {
            ubyte c = look(0)
            if is_ident_char(c)
                pos++
            else if c == ':' and look(1) == ':' and is_letter(look(2))
                pos += 2
            else
                break
        }
        uword length = (pos - start) as uword
        ^^strtab.Sym s = strtab.intern_sym(src + start, length)
        ubyte kind = token.T_IDENT
        if s.kind != 0
            kind = s.kind
        void add(kind, s.text, length, start)
    }

    ; decimal integer, or a float when a '.' or exponent follows
    sub scan_number() {
        long start = pos
        quad value = 0
        ubyte c
        repeat {
            c = look(0)
            if is_digit(c) {
                value = value * 10 + (c - '0')
                pos++
            }
            else if c == '_'
                pos++
            else
                break
        }
        if c == '.' or c == 'e' or c == 'E' {
            pos = start
            scan_float()
            return
        }
        ^^token.Token t = add(token.T_INT, src + start, (pos - start) as uword, start)
        t.value = value
    }

    ; the float's spelling is kept as text; its value is computed later
    sub scan_float() {
        long start = pos
        while is_digit(look(0)) or look(0) == '_'
            pos++
        if look(0) == '.' {
            pos++
            while is_digit(look(0)) or look(0) == '_'
                pos++
        }
        if look(0) == 'e' or look(0) == 'E' {
            ubyte n = look(1)
            if is_digit(n) or ((n == '+' or n == '-') and is_digit(look(2))) {
                pos += 2
                while is_digit(look(0)) or look(0) == '_'
                    pos++
            }
        }
        uword length = (pos - start) as uword
        void add(token.T_FLOAT, strtab.intern(src + start, length), length, start)
    }

    sub scan_hex() {
        long start = pos
        pos++
        if not is_hex_digit(look(0)) {
            error("hexadecimal digit expected after $")
            void add(token.T_INT, src + start, 1, start)
            return
        }
        quad value = 0
        repeat {
            ubyte c = look(0)
            if is_digit(c)
                value = (value << 4) | (c - '0')
            else if c >= 'a' and c <= 'f'
                value = (value << 4) | (c - 'a' + 10)
            else if c >= 'A' and c <= 'F'
                value = (value << 4) | (c - 'A' + 10)
            else if c != '_'
                break
            pos++
        }
        ^^token.Token t = add(token.T_INT, src + start, (pos - start) as uword, start)
        t.value = value
    }

    sub scan_binary() {
        long start = pos
        pos++
        quad value = 0
        repeat {
            ubyte c = look(0)
            if c == '0' or c == '1'
                value = (value << 1) | (c - '0')
            else if c != '_'
                break
            pos++
        }
        ^^token.Token t = add(token.T_INT, src + start, (pos - start) as uword, start)
        t.value = value
    }

    ; the text between the quotes, escapes still undecoded
    sub scan_string() {
        long start = pos
        pos++
        long textstart = pos
        repeat {
            ubyte c = look(0)
            if c == '"'
                break
            if c == 0 or c == '\n' or c == '\r' {
                error("unterminated string")
                break
            }
            if c == '\\'
                pos++
            pos++
        }
        uword length = (pos - textstart) as uword
        void add(token.T_STRING, strtab.intern(src + textstart, length), length, start)
        if look(0) == '"'
            pos++
    }

    sub scan_char() {
        long start = pos
        pos++
        long textstart = pos
        ubyte c = look(0)
        if c == '\\' {
            pos++
            c = look(0)
            if c == 'x'
                pos += 3
            else if c == 'u'
                pos += 5
            else
                pos++
        }
        else if c == 0 or c == '\n' or c == '\'' {
            error("character expected in character literal")
        }
        else {
            pos++
            ; a multi-byte UTF-8 character: take its continuation bytes too
            while look(0) >= $80 and look(0) < $c0
                pos++
        }
        if pos > end
            pos = end
        uword length = (pos - textstart) as uword
        void add(token.T_CHAR, strtab.intern(src + textstart, length), length, start)
        if look(0) == '\''
            pos++
        else
            error("closing quote expected after character literal")
    }

    ; the raw text between {{ and }}, pointing into the source
    sub scan_asm_block() {
        long start = pos
        uword startline = line
        long startcol = pos - line_start + 1
        pos += 2
        long textstart = pos
        repeat {
            if pos >= end {
                error("unterminated {{ block")
                break
            }
            ubyte c = src[pos]
            if c == '}' and look(1) == '}'
                break
            if c == '\n' {
                pos++
                newline()
            }
            else
                pos++
        }
        long length = pos - textstart
        ; a block can be longer than len holds, so its length is in value
        ^^token.Token t = add(token.T_ASMBLOCK, src + textstart, 0, start)
        t.value = length
        t.line = startline          ; the block spans lines: position it where it starts
        t.col = startcol as uword
        if pos < end
            pos += 2
    }

    sub scan_punct() {
        long start = pos
        ubyte c = src[pos]
        ubyte n = look(1)
        ubyte kind = 0
        ubyte size = 1
        when c {
            '(' -> kind = token.T_LPAREN
            ')' -> kind = token.T_RPAREN
            '[' -> kind = token.T_LBRACKET
            ']' -> kind = token.T_RBRACKET
            '{' -> kind = token.T_LBRACE
            '}' -> kind = token.T_RBRACE
            ',' -> kind = token.T_COMMA
            '.' -> kind = token.T_DOT
            ':' -> kind = token.T_COLON
            '~' -> kind = token.T_TILDE
            '@' -> kind = token.T_AT
            '=' -> {
                kind = token.T_ASSIGN
                if n == '=' {
                    kind = token.T_EQ
                    size = 2
                }
            }
            '!' -> {
                kind = token.T_BANG
                if n == '=' {
                    kind = token.T_NE
                    size = 2
                }
            }
            '+' -> {
                kind = token.T_PLUS
                if n == '=' {
                    kind = token.T_PLUSEQ
                    size = 2
                }
                else if n == '+' {
                    kind = token.T_PLUSPLUS
                    size = 2
                }
            }
            '-' -> {
                kind = token.T_MINUS
                if n == '=' {
                    kind = token.T_MINUSEQ
                    size = 2
                }
                else if n == '-' {
                    kind = token.T_MINUSMINUS
                    size = 2
                }
                else if n == '>' {
                    kind = token.T_ARROW
                    size = 2
                }
            }
            '*' -> {
                kind = token.T_STAR
                if n == '=' {
                    kind = token.T_STAREQ
                    size = 2
                }
            }
            '/' -> {
                kind = token.T_SLASH
                if n == '=' {
                    kind = token.T_SLASHEQ
                    size = 2
                }
            }
            '%' -> {
                kind = token.T_PERCENT
                if n == '=' {
                    kind = token.T_PERCENTEQ
                    size = 2
                }
            }
            '&' -> {
                kind = token.T_AMP
                if n == '&' {
                    kind = token.T_AMPAMP
                    size = 2
                }
                else if n == '>' {
                    kind = token.T_AMPGT
                    size = 2
                }
                else if n == '<' {
                    kind = token.T_AMPLT
                    size = 2
                }
                else if n == '=' {
                    kind = token.T_AMPEQ
                    size = 2
                }
            }
            '|' -> {
                kind = token.T_PIPE
                if n == '=' {
                    kind = token.T_PIPEEQ
                    size = 2
                }
            }
            '^' -> {
                kind = token.T_CARET
                if n == '^' {
                    kind = token.T_CARETCARET
                    size = 2
                }
                else if n == '=' {
                    kind = token.T_CARETEQ
                    size = 2
                }
            }
            '<' -> {
                kind = token.T_LT
                if n == '=' {
                    kind = token.T_LE
                    size = 2
                }
                else if n == '<' {
                    kind = token.T_SHL
                    size = 2
                    if look(2) == '=' {
                        kind = token.T_SHLEQ
                        size = 3
                    }
                }
            }
            '>' -> {
                kind = token.T_GT
                if n == '=' {
                    kind = token.T_GE
                    size = 2
                }
                else if n == '>' {
                    kind = token.T_SHR
                    size = 2
                    if look(2) == '=' {
                        kind = token.T_SHREQ
                        size = 3
                    }
                }
            }
            else -> {
                error("unexpected character")
                pos++
                return
            }
        }
        pos += size
        void add(kind, 0, size, start)
    }

    sub stats() {
        out.puts("lexer: ")
        out.putl(total_lines)
        out.puts(" lines, ")
        out.putl(total_tokens)
        out.puts(" tokens, ")
        out.putl(sizeof(token.Token))
        out.puts(" bytes per token")
        out.nl()
    }

    ; Prints one token per line: line:col kind text
    sub dump(^^Tokens toks) {
        long i = 0
        while i < toks.count {
            ^^token.Token t = toks.items + i
            out.putl(t.line)
            out.putc(':')
            out.putl(t.col)
            out.putc(' ')
            ubyte kind = t.kind
            if token.is_keyword(kind) {
                out.puts("KW ")
                out.puts(t.text)
            }
            else {
                out.puts(token.names[kind])
                if kind == token.T_INT {
                    out.putc(' ')
                    out.put_bytes(t.text, t.len)
                    out.puts(" = ")
                    out.putq(t.value)
                }
                else if kind == token.T_ASMBLOCK {
                    out.puts(" (")
                    out.putq(t.value)
                    out.puts(" bytes)")
                }
                else if t.text != 0 {
                    out.putc(' ')
                    out.put_bytes(t.text, t.len)
                }
            }
            out.nl()
            i++
        }
    }
}
