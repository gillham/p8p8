%import textio
%import math

; constants: bits of signed numbers have no sign, a long written past its
; range wraps, and the direction between two points
main {
    const long WRAPPED = -2147483649
    const byte CA = -1
    const byte CB = -15
    const word CW = -15
    const ubyte EAST = math.atan2(0, 0, 10, 0)
    const ubyte DOWN = math.atan2(0, 0, 0, 10)

    sub start() {
        txt.print_l(WRAPPED)
        txt.spc()
        txt.print_ub(CA & CB)
        txt.spc()
        txt.print_ub(CA | CB)
        txt.spc()
        txt.print_ub(CA ^ CB)
        txt.spc()
        txt.print_uw(CW & -1)
        txt.spc()
        txt.print_uw(CW | 3)
        txt.spc()
        txt.print_b(CA << 2)
        txt.spc()
        txt.print_b(CB >> 1)
        txt.nl()
        txt.print_ub(EAST)
        txt.spc()
        txt.print_ub(DOWN)
        txt.spc()
        txt.print_ub(math.atan2(10, 10, 0, 10))
        txt.spc()
        txt.print_ub(math.atan2(100, 100, 101, 99))
        txt.spc()
        txt.print_ub(math.atan2(3, 200, 3, 10))
        txt.nl()
    }
}
