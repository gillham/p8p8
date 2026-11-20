%import textio
%zeropage basicsafe

; An interrupt handler in an overlay is refused (make overlaycheck): an interrupt comes
; whatever is in the window.  The first is given to the library's routine, the second
; stored in the vector; the third is in the main program, and fine.
%overlay 1, main.ticker, main.blinker

main {
    ubyte ticks

    sub start() {
        sys.set_irq(&ticker)
        cbm.CINV = &blinker
        sys.set_irq(&steady)
        txt.print_ub(ticks)
    }

    sub ticker() -> bool {
        ticks++
        return true
    }

    sub blinker() {
        ticks += 2
    }

    sub steady() -> bool {
        ticks += 3
        return true
    }
}
