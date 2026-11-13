; The %encoding directive sets the default encoding of the module; a prefix
; still overrides it.

%encoding sc

main {
    sub start() {
        str a = "Hello\n"
        str b = iso:"Hello\n"
        ubyte c = 'a'
        ubyte d = petscii:'a'
        a[0] = b[0]
        c = d
    }
}
