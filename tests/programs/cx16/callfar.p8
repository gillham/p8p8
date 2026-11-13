; The callfar and callfar2 builtins: a routine copied into RAM bank 4 is called with
; a constant and a variable bank and address.  Commander X16 only.
; Compared with upstream by make emucmp.

%import textio
%zeropage basicsafe

main {
    sub start() {
        ; a routine in RAM bank 4 at $A000: adds 1 to AY (sta/sty, inc, lda/ldy, rts)
        cx16.push_rambank(4)
        ubyte[] code = [$85, $02, $84, $03, $e6, $02, $d0, $02, $e6, $03, $a5, $02, $a4, $03, $60]
        sys.memcopy(code, $a000, len(code))
        cx16.pop_rambank()

        uword result = callfar(4, $a000, 1234)
        txt.print_uw(result)
        txt.spc()
        ubyte bank = 4
        uword address = $a000
        result = callfar(bank, address, 255)
        txt.print_uw(result)
        txt.spc()
        void callfar(4, $a000, 999)
        txt.print_uw(cx16.r0)
        txt.spc()
        txt.print_uw(callfar2(4, $a000, 7, 0, 3, false))
        txt.nl()
    }
}
