; The -encoding option sets the encoding of literals without a prefix, in place of
; the target's own; a prefix and a module's %encoding still say otherwise.
; (make test compiles this for the c64 with -encoding iso.)

main {
    sub start() {
        str a = "Hello {x}\n"
        str b = petscii:"Hello"
        ubyte c = 'a'
        ubyte d = sc:'a'
        a[0] = b[0]
        c = d
    }
}
