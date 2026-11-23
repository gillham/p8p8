; The coco3ram target: the program has memory blocks of its own where BASIC is.  That
; memory written and read back from sys.upperstart() on (the program's own variables
; are before it), with the clock's interrupts, a float through BASIC, the highram
; module (16 KB of a 128 KB machine are left for it) and the 80 column screen at work
; meanwhile.  make cocosys runs it in XRoar with 128 KB and with 512 KB.
%import textio
%import floats
%import highram
main {
    sub start() {
        uword k
        uword wrong = 0
        ; the program's own memory where BASIC is
        for k in sys.upperstart() to $fdff
            @(k) = lsb(k) ^ msb(k)
        uword before = sys.ticks()
        sys.wait(5)
        txt.print_bool(sys.ticks() != before)
        txt.print_f(sqrt(2.0) * 2.0)
        txt.nl()
        txt.print_l(highram.size())
        highram.setbyte(5, 99)
        highram.fill(100, 20000, 7)
        txt.spc()
        txt.print_ub(highram.getbyte(5))
        txt.print_ub(highram.getbyte(20099))
        txt.nl()
        for k in sys.upperstart() to $fdff {
            if @(k) != lsb(k) ^ msb(k)
                wrong++
        }
        txt.print_uw(wrong)
        txt.nl()
        txt.setchr(3, 3, 'x')
        txt.print_ub(txt.getchr(3, 3))
        txt.spc()
        txt.print_ub(txt.width())
        txt.spc()
        txt.print_bool(sys.upperstart() > $8000 and sys.upperstart() < $a000)
        txt.nl()
    }
}
