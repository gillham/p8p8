%import textio
%zeropage basicsafe

; Overlay numbers as constants (make overlaycheck): the list, a block and a subroutine
; name their overlay by a constant, so that moving an overlay is one number changed.
; (It uses the list and the directive inside a block both, to try them: p8c warns.)
%overlay banks.TEXTS, texts
%overlay banks.MATHS, main.cube

banks {
    const ubyte TEXTS = 2
    const ubyte MATHS = TEXTS + 1
    const ubyte EXTRA = 5
}

main {
    sub start() {
        txt.print("named ")
        texts.say()
        txt.print_uw(cube(7))
        txt.spc()
        txt.print_uw(more.twice(21))
        txt.spc()
        txt.print_ub(late(4))
        txt.nl()
    }

    sub cube(uword v) -> uword {
        return v * v * v
    }

    sub late(ubyte v) -> ubyte {
        %overlay banks.EXTRA
        return v + 1
    }
}

texts {
    sub say() {
        txt.print("constants ")
    }
}

more {
    %overlay banks.EXTRA
    sub twice(uword v) -> uword {
        return v * 2
    }
}
