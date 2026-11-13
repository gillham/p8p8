; String and character literal decoding: escapes, UTF-8 and every encoding
; prefix.  The expected bytes were taken from what prog8c-llvm emits for the
; same literals on llvm64 (its default encoding is ISO-8859-15).

main {
    sub start() {
        str a = "Hi\n\x41é€|\"\'\\\t\r"
        str b = petscii:"Hi\n^_{}|\\ Ab\r"
        str c = sc:"Hi\nAb"
        str d = iso5:"Жx"
        str e = iso16:"zażółć"
        str f = cp437:"☺░é¶"
        str g = kata:"ｱガが♥¥\\~"
        str h = iso:"missing: Ж"
        ubyte i = 'x'
        ubyte j = petscii:'A'
        ubyte k = '\x7f'
        ubyte l = sc:'a'
        ubyte m = 'é'
        a[0] = b[0]
        a[1] = c[0]
        a[2] = d[0]
        a[3] = e[0]
        a[4] = f[0]
        a[5] = g[0]
        a[6] = h[0]
        i = j
        k = l
        i = k
        m = i
    }
}
