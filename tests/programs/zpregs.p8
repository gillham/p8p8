%import textio
; the virtual registers are in the zero page: assembly can use them as pointers
main {
    ubyte[4] @shared data = [10, 20, 30, 40]
    enum Color { RED, GREEN = 5, BLUE }
    sub start() {
        cx16.r0 = &data
        cx16.r7 = &data + 1
        ubyte @shared a
        ubyte @shared b
        %asm {{
            ldy  #2
            lda  (cx16.r0),y
            sta  p8v_a
            lda  (cx16.r7),y
            clc
            adc  #p8c_Color_BLUE
            sta  p8v_b
        }}
        txt.print_ub(a)
        txt.spc()
        txt.print_ub(b)
        txt.spc()
        rsave()
        cx16.r3 = 12345
        rrestore()
        txt.print_uw(cx16.r3)
        txt.spc()
        txt.nl()
    }
}
