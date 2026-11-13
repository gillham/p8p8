; palette.set_color for entries above 127: the library computes the address with
; index * $0002, a word calculation.  Commander X16 only.  Compared with upstream by make emucmp.

%import textio
%import palette
%zeropage basicsafe
main {
    sub show(ubyte index) {
        txt.print_uwhex(cx16.vpeek(1, $fa00 + index * (2 as uword) + 1) * (256 as uword) + cx16.vpeek(1, $fa00 + index * (2 as uword)), true)
        txt.spc()
    }
    sub start() {
        ubyte d
        for d in 128 to 128+23
            palette.set_color(d, $024)
        show(128)
        show(140)
        show(151)
        show(152)
        palette.set_color(200, $abc)
        show(200)
        d = 3
        palette.set_color(d + 128, $123)
        show(131)
        txt.nl()
    }
}
