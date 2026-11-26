; The 8086's registers in the declaration of a routine in assembly, on MS-DOS.
%import textio

main {
    asmsub add3(ubyte value @AL) -> ubyte @AL {
        %asm {{
            add  al, 3
            ret
        }}
    }

    asmsub sum(uword a @AX, uword b @BX) -> uword @AX {
        %asm {{
            add  ax, bx
            ret
        }}
    }

    asmsub halves(uword value @DX) -> ubyte @DL, ubyte @DH {
        %asm {{
            ret
        }}
    }

    asmsub length(str text @SI) -> uword @CX {
        %asm {{
            xor  cx, cx
        main_length_next:
            lodsb
            test  al, al
            jz  main_length_end
            inc  cx
            jmp  main_length_next
        main_length_end:
            ret
        }}
    }

    asmsub is_odd(ubyte value @AL) -> bool @Pc {
        %asm {{
            shr  al, 1
            ret
        }}
    }

    asmsub with_carry(ubyte value @AL, bool carry @Pc) -> ubyte @AL {
        %asm {{
            adc  al, 0
            ret
        }}
    }

    asmsub dos_version() -> ubyte @AL, ubyte @AH {
        %asm {{
            mov  ah, 0x30
            int  0x21
            ret
        }}
    }

    inline asmsub three() -> ubyte @BL {
        %asm {{
            mov  bl, 3
        }}
    }

    sub start() {
        ubyte lo
        ubyte hi
        txt.print_ub(add3(4))
        txt.nl()
        txt.print_uw(sum(1000, 234))
        txt.nl()
        lo, hi = halves($1234)
        txt.print_ubhex(lo, true)
        txt.spc()
        txt.print_ubhex(hi, true)
        txt.nl()
        txt.print_uw(length("eleven char"))
        txt.nl()
        txt.print_bool(is_odd(7))
        txt.spc()
        txt.print_bool(is_odd(8))
        txt.nl()
        if is_odd(5)
            txt.print("odd\n")
        txt.print_ub(with_carry(10, true))
        txt.spc()
        txt.print_ub(with_carry(10, false))
        txt.nl()
        lo, hi = dos_version()
        txt.print_bool(lo >= 2)
        txt.nl()
        txt.print_ub(three())
        txt.nl()
    }
}
