%import textio
%zeropage basicsafe

; Overlays beside data in banks of the program's own (make overlaycheck, the X16 only):
; a call into an overlay leaves the bank that was chosen as it was.
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
        cx16.rambank(1)
        txt.nl()
    }
}

work {
    %overlay 1
    sub double(ubyte v) -> ubyte {
        return v * 2
    }
}
