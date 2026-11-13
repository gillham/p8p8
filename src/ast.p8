; The abstract syntax tree.  One Node struct serves every construct: its
; kind says what it is and what the child slots a, b, c, d hold, which is
; documented with each kind constant below.  Lists are chains through
; next.  Node kinds are N_*, operators and type names reuse token kinds.

%import mem
%import buf
%import out
%import token
%import types

ast {
    %option ignore_unused

    struct Node {
        ^^Node next         ; next node in the same list
        ^^Node a            ; child slots, see the kind
        ^^Node b
        ^^Node c
        ^^Node d
        ^^ubyte name        ; interned text, or 0
        pointer extra       ; free for later stages (symbol, type) or raw text
        quad value          ; literal value, length, or 0
        uword line
        uword col
        uword type          ; type id (types.p8) of an expression or declaration, 0 = not known
        ubyte kind
        ubyte op            ; operator or type keyword token kind, or 0
        ubyte flags
        ubyte file          ; source file index
    }

    const ubyte N_MODULE = 0        ; a=elements (directives and blocks)
    const ubyte N_DIRECTIVE = 1        ; name=directive name; a=argument list; flags F_BANG for %name!
    const ubyte N_BLOCK = 2        ; name; a=statements; b=address expression or 0
    const ubyte N_VARDECL = 3        ; op=declaration kind (T_KW_CONST, T_AMP for memory mapped, else 0); a=type; b=initializer or 0; c=name list of IDENT; d=TAG list; flags private/public
    const ubyte N_TAG = 4        ; name=tag without the @
    const ubyte N_TYPE = 5        ; op=base type keyword kind, or T_IDENT with name=struct type name; a=array dimension list (INT/expr) or empty-array marker; flags F_POINTER, F_EMPTYARRAY
    const ubyte N_SUB = 6        ; name; a=PARAM list; b=return TYPE list; c=body statements; flags private/public/inline
    const ubyte N_PARAM = 7        ; name; a=type; b=register IDENT or 0
    const ubyte N_ASMSUB = 8        ; name; a=PARAM list (with registers); b=return TYPE list each with register in a child IDENT; c=body statements; d=clobber IDENT list; flags
    const ubyte N_EXTSUB = 9        ; name; a=PARAM list; b=return TYPE list; c=address expression or 0 (then it is a C routine); d=bank (INT or IDENT) or 0; and the clobber list hangs off the first return type
    const ubyte N_STRUCT = 10        ; name; a=field VARDECL list
    const ubyte N_UNION = 11        ; name; a=field VARDECL list
    const ubyte N_ENUM = 12        ; name; a=ENUMMEMBER list
    const ubyte N_ENUMMEMBER = 13        ; name; a=value expression or 0
    const ubyte N_ALIAS = 14        ; name; a=target: IDENT or TYPE
    const ubyte N_LABEL = 15        ; name
    const ubyte N_ASM = 16        ; name=asm or ir; b=the block text pointer stored in extra, value=its length
    const ubyte N_ASSIGN = 17        ; a=target list (one or more); b=value: expression, TUPLE, or a chained ASSIGN
    const ubyte N_AUGASSIGN = 18        ; op=operator token kind (T_PLUSEQ ...); a=target; b=expression
    const ubyte N_INCDEC = 19        ; op=T_PLUSPLUS or T_MINUSMINUS; a=target
    const ubyte N_CALLSTMT = 20        ; a=CALL expression; flags F_VOID
    const ubyte N_IF = 21        ; a=condition; b=then statements; c=else statements
    const ubyte N_BRANCH = 22        ; op=condition keyword kind (T_KW_IF_CS ...); b=then statements; c=else statements
    const ubyte N_RETURN = 23        ; a=value list
    const ubyte N_FOR = 24        ; a=loop variable IDENT; b=iterable expression; c=body; d=type (for a declared loop variable) or 0; extra fields: see FOROPT
    const ubyte N_FOROPT = 25        ; op=T_KW_VIA, T_KW_UNTIL or T_KW_STEP; a=expression or IDENT; the list hangs off the FOR node's TYPE slot d as a chain after the type
    const ubyte N_WHILE = 26        ; a=condition; b=body
    const ubyte N_UNTIL = 27        ; a=body; b=condition
    const ubyte N_REPEAT = 28        ; a=count expression or 0; b=body
    const ubyte N_UNROLL = 29        ; a=count expression; b=body
    const ubyte N_WHEN = 30        ; a=expression; b=CHOICE list
    const ubyte N_CHOICE = 31        ; a=value list, or 0 for else; b=statements
    const ubyte N_BREAK = 32
    const ubyte N_CONTINUE = 33
    const ubyte N_GOTO = 34        ; a=target expression
    const ubyte N_DEFER = 35        ; a=statements
    const ubyte N_SWAP = 36        ; a=first target; b=second target
    const ubyte N_ONGOTO = 37        ; op=T_KW_GOTO or T_KW_CALL; a=index expression; b=target IDENT list; c=else statements
    const ubyte N_INT = 38        ; value; name=spelling in the source
    const ubyte N_FLOAT = 39        ; name=spelling
    const ubyte N_STR = 40        ; name=raw text between the quotes; a=encoding IDENT or 0
    const ubyte N_CHAR = 41        ; name=raw text between the quotes; a=encoding IDENT or 0
    const ubyte N_BOOL = 42        ; value 0 or 1
    const ubyte N_ARRAYLIT = 43        ; a=element list; flags F_EMPTYARRAY for []
    const ubyte N_IDENT = 44        ; name=dotted identifier as written
    const ubyte N_INDEX = 45        ; a=base expression; b=index expression list (1 or 2)
    const ubyte N_DEREF = 46        ; a=pointer expression (the ^^ postfix)
    const ubyte N_FIELD = 47        ; name=field; a=base expression (the . postfix after a non-identifier)
    const ubyte N_BINARY = 48        ; op=operator token kind; a=left; b=right
    const ubyte N_UNARY = 49        ; op=operator token kind (T_MINUS, T_PLUS, T_TILDE, T_KW_NOT); a=operand
    const ubyte N_RANGE = 50        ; op=T_KW_TO or T_KW_DOWNTO; a=from; b=to; c=step or 0
    const ubyte N_CALL = 51        ; a=callee IDENT; b=argument list
    const ubyte N_CAST = 52        ; a=expression; b=TYPE
    const ubyte N_ADDROF = 53        ; op=T_AMP, T_AMPAMP, T_AMPLT or T_AMPGT; a=IDENT; b=index expression or 0
    const ubyte N_MEMREAD = 54        ; a=address expression (@(...))
    const ubyte N_SIZEOF = 55        ; a=TYPE, IDENT or ADDROF
    const ubyte N_IFEXPR = 56        ; a=condition; b=then value; c=else value
    const ubyte N_BRANCHEXPR = 57        ; op=condition keyword kind; b=then value; c=else value
    const ubyte N_STRUCTINIT = 58        ; name=struct type name; a=positional value list or NAMEDFIELD list; flags F_POINTER when written with ^^, F_NAMED
    const ubyte N_NAMEDFIELD = 59        ; name; a=value
    const ubyte N_TUPLE = 60        ; a=expression list
    const ubyte N_VOID = 61        ; the void assignment target
    const ubyte N_REMOVED = 62      ; a subroutine that a merged block replaced: nothing
    const ubyte N_COUNT = 63

    const ubyte F_PRIVATE = 1
    const ubyte F_PUBLIC = 2
    const ubyte F_INLINE = 4
    const ubyte F_POINTER = 8
    const ubyte F_VOID = 16
    const ubyte F_EMPTYARRAY = 32
    const ubyte F_BANG = 64
    const ubyte F_NAMED = 128

    str[] names = ["MODULE", "DIRECTIVE", "BLOCK", "VARDECL", "TAG", "TYPE", "SUB", "PARAM", "ASMSUB", "EXTSUB", "STRUCT", "UNION", "ENUM", "ENUMMEMBER", "ALIAS", "LABEL", "ASM", "ASSIGN", "AUGASSIGN", "INCDEC", "CALLSTMT", "IF", "BRANCH", "RETURN", "FOR", "FOROPT", "WHILE", "UNTIL", "REPEAT", "UNROLL", "WHEN", "CHOICE", "BREAK", "CONTINUE", "GOTO", "DEFER", "SWAP", "ONGOTO", "INT", "FLOAT", "STR", "CHAR", "BOOL", "ARRAYLIT", "IDENT", "INDEX", "DEREF", "FIELD", "BINARY", "UNARY", "RANGE", "CALL", "CAST", "ADDROF", "MEMREAD", "SIZEOF", "IFEXPR", "BRANCHEXPR", "STRUCTINIT", "NAMEDFIELD", "TUPLE", "VOID", "REMOVED"]

    long count = 0
    bool show_positions = true
    bool show_types = false

    sub new(ubyte kind, ^^token.Token t, ubyte file) -> ^^Node {
        ^^Node n = mem.alloc(sizeof(Node))
        n.kind = kind
        n.line = t.line
        n.col = t.col
        n.file = file
        count++
        return n
    }

    ; Links n after tail (when there is one) and returns n as the new tail.
    sub link(^^Node tail, ^^Node n) -> ^^Node {
        if tail != 0
            tail.next = n
        return n
    }

    sub list_length(^^Node n) -> long {
        long total = 0
        while n != 0 {
            total++
            n = n.next
        }
        return total
    }

    ; Prints the name of an operator or type keyword token kind.
    sub put_opname(ubyte kind) {
        if kind == 255
            out.puts("not in")
        else if token.is_keyword(kind)
            out.puts(token.keywords[kind - token.T_KW_FIRST])
        else
            out.puts(token.names[kind])
    }

    ; Dumps the tree below n, one node per line, children indented under their slot letter.
    sub dump(^^Node n, ubyte indent) {
        dump_list(n, indent, ' ')
    }

    sub dump_list(^^Node n, ubyte indent, ubyte slot) {
        while n != 0 {
            dump_node(n, indent, slot)
            n = n.next
        }
    }

    sub dump_node(^^Node n, ubyte indent, ubyte slot) {
        repeat indent
            out.puts("  ")
        if slot != ' ' {
            out.putc(slot)
            out.puts(": ")
        }
        out.puts(names[n.kind])
        if n.op != 0 {
            out.puts(" op=")
            put_opname(n.op)
        }
        if n.name != 0 {
            out.putc(' ')
            out.puts(n.name)
        }
        if n.kind == N_INT or n.kind == N_BOOL or n.kind == N_ASM {
            out.puts(" value=")
            out.putq(n.value)
        }
        if show_types and n.extra != 0 {
            if n.kind == N_CHAR {
                out.puts(" value=")
                out.putq(n.value)
            }
            else if n.kind == N_STR {
                ; the decoded bytes in hex
                out.puts(" bytes=")
                ^^ubyte bytes = n.extra
                long i = 0
                while i < n.value {
                    out.putc(buf.hex_digit(bytes[i] >> 4))
                    out.putc(buf.hex_digit(bytes[i] & 15))
                    i++
                }
            }
        }
        if n.flags != 0 {
            out.puts(" flags=")
            out.putl(n.flags)
        }
        if show_types and n.type != 0 {
            out.puts(" : ")
            types.put_name(n.type)
        }
        if show_positions {
            out.puts(" (")
            out.putl(n.line)
            out.putc(':')
            out.putl(n.col)
            out.putc(')')
        }
        out.nl()
        dump_list(n.a, indent + 1, 'a')
        dump_list(n.b, indent + 1, 'b')
        dump_list(n.c, indent + 1, 'c')
        dump_list(n.d, indent + 1, 'd')
    }

    sub stats() {
        out.puts("ast: ")
        out.putl(count)
        out.puts(" nodes, ")
        out.putl(sizeof(Node))
        out.puts(" bytes per node")
        out.nl()
    }
}
