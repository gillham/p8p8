%import textio
%import math
%import strings

; what upstream works out when it compiles: the math library's functions of
; constants; and a loop's own variable used before the loop
main {
    const ubyte S1 = math.sin8u(64)
    const ubyte S2 = math.cos8u(10)
    const byte S3 = math.sin8(200)
    const byte S4 = math.cos8(100)
    const ubyte S5 = math.sinr8u(45)
    const ubyte S6 = math.cosr8u(100)
    const byte S7 = math.sinr8(130)
    const byte S8 = math.cosr8(60)
    const ubyte L1 = math.log2(64)
    const ubyte L2 = math.log2w(5000)
    const ubyte D1 = math.diff(10, 250)
    const uword D2 = math.diffw(40000, 100)
    const bool DIGIT = strings.isdigit('7')
    %assert math.sin8u(0) == 128
    ubyte[S1 / 50] table

    sub start() {
        txt.print_ub(S1)
        txt.spc()
        txt.print_ub(S2)
        txt.spc()
        txt.print_b(S3)
        txt.spc()
        txt.print_b(S4)
        txt.spc()
        txt.print_ub(S5)
        txt.spc()
        txt.print_ub(S6)
        txt.spc()
        txt.print_b(S7)
        txt.spc()
        txt.print_b(S8)
        txt.nl()
        txt.print_ub(L1)
        txt.spc()
        txt.print_ub(L2)
        txt.spc()
        txt.print_ub(D1)
        txt.spc()
        txt.print_uw(D2)
        txt.spc()
        txt.print_bool(DIGIT)
        txt.spc()
        txt.print_ub(len(table))
        txt.nl()

        i = 3
        txt.print_ub(i)
        for i in 0 to 5 {
            txt.print_ub(i)
        }
        txt.nl()
    }
}
