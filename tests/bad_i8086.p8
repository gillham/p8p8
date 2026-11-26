; What the checker says of the registers in the declaration of a routine in assembly
; on an 8086 machine: AL, AH, BL, BH, CL, CH, DL and DH hold a byte; AX, BX, CX and DX
; (each of which is two of those), SI, DI and BP a word.
main {
    asmsub other(uword first @AY) {
        %asm {{
            ret
        }}
    }

    asmsub wide(uword value @AL) -> ubyte @SI {
        %asm {{
            ret
        }}
    }

    asmsub overlap(uword first @AX, ubyte second @AH) clobbers(DI, SP) {
        %asm {{
            ret
        }}
    }

    asmsub fine(uword first @BX, uword second @SI, ubyte third @AL, ubyte fourth @AH, bool flag @Pc) clobbers(DI) -> uword @AX, bool @Pc {
        %asm {{
            ret
        }}
    }

    sub start() {
    }
}
