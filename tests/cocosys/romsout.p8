; A program with the ROMs switched out (the coco2ram target): the clock and a wait, which
; come through the target's own interrupt routine, and the memory where the ROMs were,
; $8000 to $feff, as plain memory.
%import textio
main {
    sub start() {
        uword before = sys.ticks()
        sys.wait(30)
        uword after = sys.ticks()
        txt.print_bool(after - before >= 29 and after - before <= 33)
        txt.spc()
        ; the upper memory, as plain memory
        uword k
        uword wrong = 0
        for k in $8000 to $feff
            @(k) = lsb(k) ^ msb(k)
        sys.wait(5)
        for k in $8000 to $feff {
            if @(k) != lsb(k) ^ msb(k)
                wrong++
        }
        txt.print_uw(wrong)
        txt.spc()
        txt.print_bool(sys.ticks() - after > 5)
        txt.nl()
    }
}
