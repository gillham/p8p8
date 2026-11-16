%import textio
%import floats

; What the IR of a 68000 program has that others do not: the target's options,
; register slots for D0-D7, A0-A6 and FP0-FP7 on calls of assembly routines,
; and several return values in D0.. and FP0.., the first stored last and FP0
; after all others.

main {
    sub divide(uword a, uword b) -> uword, ubyte {
        return a / b, lsb(a % b)
    }

    sub mixed(ubyte n) -> float, uword, float, ubyte {
        return n as float * 1.5, n as uword * 100, 2.25 + n as float, n + 1
    }

    sub passed(ubyte n) -> float, uword, float, ubyte {
        return mixed(n)
    }

    sub start() {
        uword q
        ubyte r
        float f1
        float f2
        q, r = divide(1000, 7)
        f1, q, f2, r = passed(6)
        txt.print_uw(q)
        txt.chrout(r)
        txt.print_uw(f1 + f2 as uword)
    }
}
