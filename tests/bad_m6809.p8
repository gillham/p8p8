; What the checker says of the registers in the declaration of a routine in assembly
; on a 6809 machine: A and B hold a byte, D (which is A and B), X, Y and U a word.
main {
    asmsub pair(uword first @AY) {
        %asm {{
            rts
        }}
    }

    asmsub wide(uword value @A) -> ubyte @X {
        %asm {{
            rts
        }}
    }

    asmsub overlap(uword first @D, ubyte second @B) clobbers(U, Q) {
        %asm {{
            rts
        }}
    }

    asmsub fine(uword first @X, uword second @U, ubyte third @A, ubyte fourth @B, bool flag @Pc) clobbers(Y) -> uword @D, bool @Pc {
        %asm {{
            rts
        }}
    }

    sub start() {
    }
}
