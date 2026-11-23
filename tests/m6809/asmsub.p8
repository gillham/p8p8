; Routines in 6809 assembly (asmsub): what they take and return in the 6809's registers
; (A and B a byte, D, X, Y and U a word), in the carry and in the zero flag.
; For the 6809 only: tests/m6809/asmsub.out is what it must print.
%import textio
main {

    asmsub add3(ubyte value @B) -> ubyte @B {
        %asm {{
            addb  #3
            rts
        }}
    }

    asmsub sum(uword first @X, uword second @Y) -> uword @D {
        %asm {{
            pshs  y
            tfr  x,d
            addd  ,s++
            rts
        }}
    }

    asmsub carry_of(ubyte value @A, bool flag @Pc) -> bool @Pc, ubyte @B {
        %asm {{
            tfr  a,b
            rolb
            rts
        }}
    }

    asmsub is_zero(uword value @X) -> bool @Pz {
        %asm {{
            leax  ,x
            rts
        }}
    }

    inline asmsub twice(ubyte value @A) -> ubyte @A {
        %asm {{
            lsla
        }}
    }

    sub start() {
        ubyte @shared n = 7
        uword @shared w = 1000
        txt.print_ub(add3(n))
        txt.spc()
        txt.print_uw(sum(w, 234))
        txt.spc()
        bool c
        ubyte v
        c, v = carry_of($81, true)
        txt.print_bool(c)
        txt.spc()
        txt.print_ub(v)
        txt.spc()
        c, v = carry_of($01, false)
        txt.print_bool(c)
        txt.spc()
        txt.print_ub(v)
        txt.spc()
        txt.print_bool(is_zero(w))
        txt.print_bool(is_zero(w - 1000))
        txt.spc()
        txt.print_ub(twice(n))
        txt.nl()
    }
}
