; The text screen of the atarist target (textio on the VT-52 console): the size that
; the mode has, the cursor, colours as the mode has them, inverse text, a character
; put at a place, a line that is longer than the screen is wide.
; make stscreen looks at the screen's memory afterwards (tools/stscreen.py).
%import textio

main {
    sub start() {
        txt.cls()
        txt.print_ub(txt.width())
        txt.chrout('x')
        txt.print_ub(txt.height())
        txt.spc()
        txt.print_ub(txt.colors())
        txt.nl()
        ; what the mode makes of the sixteen colours
        ubyte c
        for c in 0 to 15 {
            txt.print_ub(txt.mode_color(c))
            txt.spc()
        }
        txt.nl()
        txt.plot(5, 4)
        txt.print("at 5,4")
        txt.plot(0, 6)
        txt.color(1)
        txt.print("colour 1 ")
        txt.color(2)
        txt.print("colour 2 ")
        txt.color(15)
        txt.print("colour 15")
        txt.nl()
        txt.rvs_on()
        txt.print("inverse")
        txt.rvs_off()
        txt.print(" normal\n")
        txt.color2(0, 15)
        txt.print("white on black")
        txt.color2(15, 0)
        txt.nl()
        txt.setchr(20, 10, '*')
        txt.setchr(21, 10, 1)
        txt.plot(0, 12)
        txt.print("0123456789")
        txt.column(4)
        txt.print("col")
        txt.nl()
        ; 45 characters: where the screen has 40 columns the line goes on in the next one
        for c in 0 to 44
            txt.chrout('a' + c % 26)
        txt.nl()
        txt.print("end\n")
        ; the characters themselves in the last rows: tools/stscreen.py knows them from there
        txt.plot(0, 25 - (94 / txt.width() + 1))
        for c in 32 to 126
            tos.rawout(c)
    }
}
