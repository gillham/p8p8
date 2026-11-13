; Subroutines with several return values: bytes, words, a bool and a long together,
; a value that is skipped, and a subroutine that passes on the values of another.
; On the 6502 these travel in A/AY and the virtual registers.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

main {
    ubyte counter = 2

    sub pair(ubyte n) -> ubyte, uword {
        return counter + n, counter * (300 as uword)
    }

    sub triple() -> uword, ubyte, bool {
        return 1234, 56, true
    }

    sub five(ubyte n) -> uword, ubyte, bool, uword, long {
        if n == 0
            return 1, 2, false, 3, 4
        counter++
        return 1234 + n, counter, n == 5, 60000, 100000 + n
    }

    sub passing(ubyte n) -> ubyte, uword {
        return pair(n + 1)
    }

    sub start() {
        ubyte a
        uword b
        bool c
        uword d
        long e
        a, b = pair(5)
        txt.print_ub(a)
        txt.spc()
        txt.print_uw(b)
        txt.nl()
        b, a, c = triple()
        txt.print_uw(b)
        txt.spc()
        txt.print_ub(a)
        txt.spc()
        txt.print_bool(c)
        txt.nl()
        b, a, c, d, e = five(counter + 3)
        txt.print_uw(b)
        txt.spc()
        txt.print_ub(a)
        txt.spc()
        txt.print_bool(c)
        txt.spc()
        txt.print_uw(d)
        txt.spc()
        txt.print_l(e)
        txt.nl()
        b, void, c, d, e = five(0)
        txt.print_uw(b)
        txt.spc()
        txt.print_bool(c)
        txt.spc()
        txt.print_uw(d)
        txt.spc()
        txt.print_l(e)
        txt.nl()
        a, b = passing(10)
        txt.print_ub(a)
        txt.spc()
        txt.print_uw(b)
        txt.nl()
    }
}
