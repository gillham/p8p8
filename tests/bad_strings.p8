; Literals that must be rejected: an unknown escape, a malformed \u escape,
; an unknown encoding prefix, a character the encoding does not have, a
; character literal that needs two bytes, and a bad %encoding directive.

%encoding klingon

main {
    sub start() {
        str a = "bad \q escape"
        str b = "short \u12 hex"
        str c = ebcdic:"text"
        str d = petscii:"ünïcödé"
        ubyte e = kata:'ガ'
        str f = atascii:"caf\u00e9"
        a[0] = b[0] + c[0] + d[0] + e + f[0]
    }
}
