%import textio
%zeropage basicsafe

; Overlays beside data in banks of the program's own (make overlaycheck, the X16 only):
; a call into an overlay leaves the bank that was chosen as it was, and code in an
; overlay goes on after it called a subroutine of the main program that left another
; bank in the window (the way a program reads its banked data).
main {
    sub start() {
        ; a byte in bank 5 and another in bank 6, at the same address
        cx16.rambank(5)
        @($a100) = 55
        cx16.rambank(6)
        @($a100) = 66
        cx16.rambank(5)
        ubyte answer = work.double(4)
        txt.print_ub(answer)
        txt.spc()
        txt.print_ub(cx16.getrambank())
        txt.spc()
        txt.print_ub(@($a100))
        cx16.rambank(6)
        txt.spc()
        txt.print_ub(@($a100))
        txt.spc()
        txt.print_uw(work.sum_of_banks())
        txt.spc()
        txt.print_ub(cx16.getrambank())
        cx16.rambank(1)
        txt.nl()
    }

    ; reads the program's data and leaves its bank in the window
    sub data_byte(ubyte bank) -> ubyte {
        cx16.rambank(bank)
        return @($a100)
    }

    asmsub data_byte_asm(ubyte bank @A) -> ubyte @A, bool @Pc {
        %asm {{
            sta  $00
            lda  $a100
            sec
            rts
        }}
    }
}

work {
    %overlay 1
    sub double(ubyte v) -> ubyte {
        return v * 2
    }

    sub sum_of_banks() -> uword {
        uword total = main.data_byte(5)
        total += main.data_byte(6)
        ubyte value
        bool flag
        value, flag = main.data_byte_asm(5)
        if flag
            total += value
        total += double(100)
        return total
    }
}
