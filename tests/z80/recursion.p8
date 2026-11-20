; Subroutines that call themselves, for the Z80 code generator: their variables are fixed
; memory, which a call that can come back saves on the stack.  Compared with the host by
; make z80cmp.

%import textio
main {
    sub out_dec(ubyte value) {
        if value >= 10
            out_dec(value / 10)
        txt.chrout('0' + value % 10)
    }
    sub fact(ubyte n) -> uword {
        if n <= 1
            return 1
        return fact(n - 1) * n
    }
    sub fib(ubyte n) -> uword {
        if n < 2
            return n
        return fib(n - 1) + fib(n - 2)
    }
    sub start() {
        out_dec(207)
        txt.spc()
        out_dec(5)
        txt.spc()
        txt.print_uw(fact(8))
        txt.spc()
        txt.print_uw(fib(15))
        txt.nl()
    }
}
