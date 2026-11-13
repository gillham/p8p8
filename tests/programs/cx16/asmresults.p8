; An asmsub with several results, some in virtual registers, some skipped with void:
; the caller fetches each value after the call.  Also the mouse position routine, which
; is such an asmsub.  Commander X16 only.  Compared with upstream by make emucmp.

%import textio
%import math
%import palette
%zeropage basicsafe
main {
    asmsub three() -> ubyte @A, uword @R0, uword @R1, byte @Y {
        %asm {{
            lda  #<1234
            sta  cx16.r0
            lda  #>1234
            sta  cx16.r0+1
            lda  #<5678
            sta  cx16.r1
            lda  #>5678
            sta  cx16.r1+1
            lda  #77
            ldy  #9
            rts
        }}
    }
    sub start() {
        cx16.r0 = 1
        cx16.r1 = 2
        void, cx16.r0, cx16.r1, void = three()
        txt.print_uw(cx16.r0)
        txt.spc()
        txt.print_uw(cx16.r1)
        txt.nl()
        ubyte a
        uword w
        a, void, w, void = three()
        txt.print_ub(a)
        txt.spc()
        txt.print_uw(w)
        txt.nl()
        ubyte d = math.direction(128, 120, 200, 30)
        txt.print_ub(d)
        txt.spc()
        ubyte prev = 5
        txt.print_ub(prev + 128)
        txt.spc()
        ubyte n
        ubyte count
        for n in 128 to 128+23
            count++
        txt.print_ub(count)
        txt.nl()
        cx16.mouse_config2(1)
        void, cx16.r0, cx16.r1, void = cx16.mouse_pos()
        txt.print_uw(cx16.r0)
        txt.spc()
        txt.print_uw(cx16.r1)
        txt.nl()
    }
}
