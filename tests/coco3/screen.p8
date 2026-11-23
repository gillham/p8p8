; The Color Computer 3's 80 and 40 column screens (the coco3 target's textio): text goes
; into the screen's memory block, which make coco3screen reads out of XRoar's snapshot.
%import textio

main {
    sub start() {
        ubyte k
        txt.set_width(80)
        txt.print("Hello, 80 columns: small letters too\n")
        txt.print_ub(txt.width())
        txt.spc()
        txt.print_ub(txt.height())
        txt.nl()
        ; a line of exactly 80 characters, which the next one follows on its own line
        for k in 0 to 79
            txt.chrout('0' + k % 10)
        txt.print("after the full line\n")
        txt.plot(70, 10)
        txt.print("at 70,10")
        txt.setchr(79, 23, '#')
        txt.setchr(0, 12, 'X')
        txt.plot(0, 5)
        txt.chrout(txt.getchr(0, 12))
        txt.chrout(txt.getchr(79, 23))
        txt.print_ub(txt.get_column())
        txt.chrout(',')
        txt.print_ub(txt.get_row())
        txt.print(" back")
        txt.chrout(8)
        txt.chrout(8)
        txt.chrout('!')
        ; past the last line: the screen moves up
        txt.plot(0, 22)
        txt.print("line 22\n")
        txt.print("line 23\n")
        txt.print("the last line")
    }
}
