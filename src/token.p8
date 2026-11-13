; Token kinds and the Token struct.  Generated once by hand-maintained lists;
; keep the names table in token_names() in the same order as the constants.

token {
    %option ignore_unused

    struct Token {
        ^^ubyte text        ; interned text (identifiers, strings, floats, tags, directives) or source pointer (asm blocks, integers)
        quad value          ; integer literal value
        uword len           ; length of text
        uword line
        uword col
        ubyte kind
    }

    const ubyte T_EOF = 0
    const ubyte T_EOL = 1
    const ubyte T_IDENT = 2
    const ubyte T_INT = 3
    const ubyte T_FLOAT = 4
    const ubyte T_STRING = 5
    const ubyte T_CHAR = 6
    const ubyte T_ASMBLOCK = 7
    const ubyte T_TAG = 8
    const ubyte T_DIRECTIVE = 9

    ; punctuation and operators
    const ubyte T_PUNCT_FIRST = 10
    const ubyte T_LPAREN = 10        ; (
    const ubyte T_RPAREN = 11        ; )
    const ubyte T_LBRACKET = 12        ; [
    const ubyte T_RBRACKET = 13        ; ]
    const ubyte T_LBRACE = 14        ; {
    const ubyte T_RBRACE = 15        ; }
    const ubyte T_COMMA = 16        ; ,
    const ubyte T_DOT = 17        ; .
    const ubyte T_COLON = 18        ; :
    const ubyte T_ASSIGN = 19        ; =
    const ubyte T_PLUS = 20        ; +
    const ubyte T_MINUS = 21        ; -
    const ubyte T_STAR = 22        ; *
    const ubyte T_SLASH = 23        ; /
    const ubyte T_PERCENT = 24        ; %
    const ubyte T_AMP = 25        ; &
    const ubyte T_AMPAMP = 26        ; &&
    const ubyte T_AMPGT = 27        ; &>
    const ubyte T_AMPLT = 28        ; &<
    const ubyte T_PIPE = 29        ; |
    const ubyte T_CARET = 30        ; ^
    const ubyte T_CARETCARET = 31        ; ^^
    const ubyte T_TILDE = 32        ; ~
    const ubyte T_LT = 33        ; <
    const ubyte T_GT = 34        ; >
    const ubyte T_LE = 35        ; <=
    const ubyte T_GE = 36        ; >=
    const ubyte T_EQ = 37        ; ==
    const ubyte T_NE = 38        ; !=
    const ubyte T_SHL = 39        ; <<
    const ubyte T_SHR = 40        ; >>
    const ubyte T_ARROW = 41        ; ->
    const ubyte T_PLUSEQ = 42        ; +=
    const ubyte T_MINUSEQ = 43        ; -=
    const ubyte T_STAREQ = 44        ; *=
    const ubyte T_SLASHEQ = 45        ; /=
    const ubyte T_PERCENTEQ = 46        ; %=
    const ubyte T_AMPEQ = 47        ; &=
    const ubyte T_PIPEEQ = 48        ; |=
    const ubyte T_CARETEQ = 49        ; ^=
    const ubyte T_SHLEQ = 50        ; <<=
    const ubyte T_SHREQ = 51        ; >>=
    const ubyte T_PLUSPLUS = 52        ; ++
    const ubyte T_MINUSMINUS = 53        ; --
    const ubyte T_BANG = 54        ; !
    const ubyte T_AT = 55        ; @

    ; keywords; those marked * may also be used as identifiers
    const ubyte T_KW_FIRST = 56
    const ubyte T_KW_IF = 56
    const ubyte T_KW_ELSE = 57
    const ubyte T_KW_WHILE = 58
    const ubyte T_KW_FOR = 59
    const ubyte T_KW_IN = 60
    const ubyte T_KW_RETURN = 61
    const ubyte T_KW_BREAK = 62
    const ubyte T_KW_CONTINUE = 63
    const ubyte T_KW_DEFER = 64
    const ubyte T_KW_WHEN = 65
    const ubyte T_KW_SWAP = 66
    const ubyte T_KW_ALIAS = 67
    const ubyte T_KW_CONST = 68
    const ubyte T_KW_SUB = 69
    const ubyte T_KW_ASMSUB = 70
    const ubyte T_KW_EXTSUB = 71
    const ubyte T_KW_CLOBBERS = 72
    const ubyte T_KW_REPEAT = 73
    const ubyte T_KW_UNROLL = 74
    const ubyte T_KW_DO = 75
    const ubyte T_KW_UNTIL = 76
    const ubyte T_KW_GOTO = 77
    const ubyte T_KW_VOID = 78
    const ubyte T_KW_STRUCT = 79
    const ubyte T_KW_UNION = 80
    const ubyte T_KW_ENUM = 81
    const ubyte T_KW_INLINE = 82        ; also an identifier
    const ubyte T_KW_PUBLIC = 83
    const ubyte T_KW_PRIVATE = 84        ; also an identifier
    const ubyte T_KW_ON = 85        ; also an identifier
    const ubyte T_KW_CALL = 86        ; also an identifier
    const ubyte T_KW_STEP = 87        ; also an identifier
    const ubyte T_KW_VIA = 88
    const ubyte T_KW_THEN = 89
    const ubyte T_KW_POINTER = 90        ; also an identifier
    const ubyte T_KW_SIZEOF = 91
    const ubyte T_KW_TO = 92
    const ubyte T_KW_DOWNTO = 93
    const ubyte T_KW_NOT = 94
    const ubyte T_KW_AND = 95
    const ubyte T_KW_OR = 96
    const ubyte T_KW_XOR = 97
    const ubyte T_KW_AS = 98
    const ubyte T_KW_TRUE = 99
    const ubyte T_KW_FALSE = 100
    const ubyte T_KW_UBYTE = 101
    const ubyte T_KW_BYTE = 102
    const ubyte T_KW_UWORD = 103
    const ubyte T_KW_WORD = 104
    const ubyte T_KW_LONG = 105
    const ubyte T_KW_QUAD = 106
    const ubyte T_KW_UQUAD = 107
    const ubyte T_KW_FLOAT = 108
    const ubyte T_KW_STR = 109
    const ubyte T_KW_BOOL = 110
    const ubyte T_KW_IF_CS = 111
    const ubyte T_KW_IF_CC = 112
    const ubyte T_KW_IF_EQ = 113
    const ubyte T_KW_IF_Z = 114
    const ubyte T_KW_IF_NE = 115
    const ubyte T_KW_IF_NZ = 116
    const ubyte T_KW_IF_PL = 117
    const ubyte T_KW_IF_POS = 118
    const ubyte T_KW_IF_MI = 119
    const ubyte T_KW_IF_NEG = 120
    const ubyte T_KW_IF_VS = 121
    const ubyte T_KW_IF_VC = 122
    const ubyte T_COUNT = 123

    ; Names of the basic kinds and the punctuation, for dumps.
    str[] names = ["EOF", "EOL", "IDENT", "INT", "FLOAT", "STRING", "CHAR", "ASMBLOCK", "TAG", "DIRECTIVE", "(", ")", "[", "]", "{", "}", ",", ".", ":", "=", "+", "-", "*", "/", "%", "&", "&&", "&>", "&<", "|", "^", "^^", "~", "<", ">", "<=", ">=", "==", "!=", "<<", ">>", "->", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "++", "--", "!", "@"]

    ; The keyword spellings, in kind order from T_KW_FIRST.
    str[] keywords = ["if", "else", "while", "for", "in", "return", "break", "continue", "defer", "when", "swap", "alias", "const", "sub", "asmsub", "extsub", "clobbers", "repeat", "unroll", "do", "until", "goto", "void", "struct", "union", "enum", "inline", "public", "private", "on", "call", "step", "via", "then", "pointer", "sizeof", "to", "downto", "not", "and", "or", "xor", "as", "true", "false", "ubyte", "byte", "uword", "word", "long", "quad", "uquad", "float", "str", "bool", "if_cs", "if_cc", "if_eq", "if_z", "if_ne", "if_nz", "if_pl", "if_pos", "if_mi", "if_neg", "if_vs", "if_vc"]

    ; True for a keyword kind that the grammar also accepts as an identifier.
    sub is_identifier_keyword(ubyte kind) -> bool {
        return kind == T_KW_INLINE or kind == T_KW_PRIVATE or kind == T_KW_ON or kind == T_KW_CALL or kind == T_KW_STEP or kind == T_KW_POINTER
    }

    sub is_keyword(ubyte kind) -> bool {
        return kind >= T_KW_FIRST and kind < T_COUNT
    }

    sub is_punct(ubyte kind) -> bool {
        return kind >= T_PUNCT_FIRST and kind < T_KW_FIRST
    }
}
