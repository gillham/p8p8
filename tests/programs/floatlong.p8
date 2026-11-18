%import textio
%import floats
%zeropage basicsafe

; floats and longs converted into each other, and a float that a subroutine
; returns next to another value
main {
    uword @shared counter = 11
    float @shared ratio = 1.5

    sub pair() -> uword, float {
        return counter, ratio * 4.0
    }

    sub triple(ubyte n) -> float, ubyte, uword {
        return n as float / 4.0, n + 1, n * $0101
    }

    sub start() {
        long big = 123456
        float f = big as float
        floats.print(f)
        txt.spc()
        f = f * 2.0 + 0.75
        big = f as long
        txt.print_l(big)
        txt.spc()
        big = -70000
        f = big as float
        floats.print(f / 7.0)
        txt.spc()
        f = -98765.4
        big = f as long
        txt.print_l(big)
        txt.nl()
        uword a
        float b
        a, b = pair()
        txt.print_uw(a)
        txt.spc()
        floats.print(b)
        txt.spc()
        ubyte c
        b, c, a = triple(10)
        floats.print(b)
        txt.spc()
        txt.print_ub(c)
        txt.spc()
        txt.print_uw(a)
        txt.nl()
    }
}
