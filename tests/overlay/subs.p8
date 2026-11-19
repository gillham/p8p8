%import textio
%zeropage basicsafe

; Single subroutines in overlays (make overlaycheck): subroutines of main with %overlay,
; which call each other, main's other subroutines and one that is declared inside them;
; a block in an overlay with one subroutine in another; their variables in main memory.
main {
    uword counter
    str greeting = "hello"

    sub start() {
        txt.print(greeting)
        txt.spc()
        txt.print_uw(triple(14))
        txt.spc()
        txt.print_uw(with_inner(5))
        txt.spc()
        report()
        txt.spc()
        txt.print_uw(tools.scale(6))
        txt.spc()
        txt.print_uw(tools.elsewhere(6))
        txt.spc()
        txt.print_uw(counter)
        txt.nl()
    }

    sub plain(uword v) -> uword {
        counter++
        return v + 1
    }

    sub triple(uword v) -> uword {
        %overlay 1
        counter++
        return plain(v) * 3 - 3
    }

    sub with_inner(uword v) -> uword {
        %overlay 2
        uword local = v * 10

        sub inner(uword w) -> uword {
            return w + local
        }

        counter++
        return inner(1) + triple(1)
    }

    sub report() {
        %overlay 2
        txt.print("report ")
        txt.print_uw(with_inner(0))
    }
}

tools {
    %overlay 1

    sub scale(uword v) -> uword {
        return main.triple(v) + elsewhere(1)
    }

    sub elsewhere(uword v) -> uword {
        %overlay 3
        main.counter += 100
        return v * 2
    }
}
