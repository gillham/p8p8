%import textio
%zeropage basicsafe

; Several return values: every value is computed before any is put in its
; place, also when one of them divides or calls.

main {
    ubyte counter

    sub next() -> ubyte {
        counter++
        return counter
    }

    sub divide(uword a, uword b) -> uword, ubyte {
        return a / b, lsb(a % b)
    }

    sub three(uword a) -> uword, uword, ubyte {
        return a * 3, a / 3, lsb(a) & 15
    }

    sub calls() -> ubyte, ubyte, ubyte {
        return next(), next(), next()
    }

    sub start() {
        uword q
        uword w
        ubyte r
        ubyte b1
        ubyte b2
        ubyte b3

        q, r = divide(1000, 7)
        txt.print_uw(q)
        txt.spc()
        txt.print_ub(r)
        txt.nl()

        q, w, r = three(1234)
        txt.print_uw(q)
        txt.spc()
        txt.print_uw(w)
        txt.spc()
        txt.print_ub(r)
        txt.nl()

        b1, b2, b3 = calls()
        ; (which call comes first differs between upstream's targets: only the sum is printed)
        txt.print_ub(b1 + b2 + b3)
        txt.spc()
        txt.print_ub(counter)
        txt.nl()
    }
}
