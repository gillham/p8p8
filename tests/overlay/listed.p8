%import textio
%zeropage basicsafe

; The overlays of a program in one place (make overlaycheck): which blocks and which
; subroutines are in which overlay is said here, and nothing in the blocks themselves.
%overlay 1, sums, main.triple
%overlay 2, main.report

main {
    uword counter

    sub start() {
        txt.print("listed ")
        txt.print_uw(triple(14))
        txt.spc()
        txt.print_uw(sums.add(100, 23))
        txt.spc()
        report()
        txt.spc()
        txt.print_uw(counter)
        txt.nl()
    }

    sub triple(uword v) -> uword {
        counter++
        return v * 3
    }

    sub report() {
        counter++
        txt.print("report ")
        txt.print_uw(sums.add(triple(2), 1))
    }
}

sums {
    sub add(uword a, uword b) -> uword {
        main.counter++
        return a + b
    }
}
