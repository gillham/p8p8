; The screen routines of the TRS-80 targets: a character put on the screen and read
; back, the cursor moved and asked for.  On the Model 4 these are Z80 assembly in the
; library (supervisor calls); on the Model I and III they are the screen's memory.
; make trs80screen runs it on the three machines; it must print "X 10 5 ok".

%import textio

main {
    sub start() {
        txt.setchr(5, 3, 'X')
        ubyte seen = txt.getchr(5, 3)
        txt.plot(10, 5)
        ubyte col = txt.get_column()
        ubyte row = txt.get_row()
        txt.plot(0, 8)
        txt.chrout(seen)
        txt.spc()
        txt.print_ub(col)
        txt.spc()
        txt.print_ub(row)
        txt.column(20)
        if txt.get_column() == 20
            txt.print(" ok")
        txt.nl()
    }
}
