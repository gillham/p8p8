%import textio
%zeropage basicsafe

; Overlays (make overlaycheck): blocks whose code is in banks of the Commander X16's high
; memory.  Calls into an overlay, between overlays and back into the main program;
; variables and strings of overlay blocks; a subroutine in an overlay through a pointer;
; the bank the program chose for its data is the same after a call.  On a machine
; without overlays the same program is built in one piece and prints the same.
main {
    ubyte @shared through_pointer

    sub start() {
        txt.print("main ")
        txt.print_ub(first.twice(21))
        txt.spc()
        txt.print_uw(second.sum(1000, 234))
        txt.spc()
        txt.print_ub(first.calls)
        txt.nl()

        ; values of every kind there and back
        txt.print_w(second.negate(-1234))
        txt.spc()
        txt.print_l(second.million(3))
        txt.spc()
        txt.print_bool(second.even(10))
        txt.spc()
        txt.print(first.title())
        txt.nl()

        ; a subroutine in an overlay through its address
        uword @shared routine = &first.mark
        void call(routine)
        txt.print_ub(through_pointer)
        txt.spc()

        ; many calls, the two overlays in turn
        uword total = 0
        ubyte i
        for i in 1 to 50 {
            total += first.twice(i)
            total += second.sum(i, 1) - 5
        }
        txt.print_uw(total)
        txt.spc()
        txt.print_ub(first.calls)
        txt.nl()
    }

    sub helper(ubyte v) -> ubyte {
        return v + 1
    }
}

first {
    %overlay 1

    ubyte calls
    str name = "first "
    str heading = "the title"

    sub twice(ubyte v) -> ubyte {
        calls++
        if calls < 3
            txt.print(name)
        return inner(v) * 2
    }

    sub inner(ubyte v) -> ubyte {
        return v
    }

    sub title() -> str {
        return heading
    }

    sub mark() {
        main.through_pointer = 77
    }
}

second {
    %overlay 2

    sub sum(uword a, uword b) -> uword {
        if a == 1000
            txt.print("second ")
        ; into the other overlay and into main from here
        return a + b + first.twice(main.helper(1))
    }

    sub negate(word w) -> word {
        return -w
    }

    sub million(long times) -> long {
        return times * 1000000
    }

    sub even(ubyte v) -> bool {
        return v & 1 == 0
    }
}
