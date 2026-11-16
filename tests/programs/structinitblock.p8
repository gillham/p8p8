%import textio

; A pointer to a struct that is given an instance where it is declared, in a
; block and in a subroutine: with values, and with none ([]: all fields zero,
; and room of its own, so that two of them do not share their fields).
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

main {
    struct Point {
        uword x
        ubyte y
        long z
    }

    ^^Point empty1 = []
    ^^Point empty2 = []
    ^^Point filled = [100, 20, 300000]

    sub show(^^Point p) {
        txt.print_uw(p.x)
        txt.spc()
        txt.print_ub(p.y)
        txt.spc()
        txt.print_l(p.z)
        txt.nl()
    }

    sub start() {
        ^^Point local = []
        show(empty1)
        show(filled)
        empty1.x = 11
        empty1.z = 123456
        empty2.y = 22
        local.x = 33
        show(empty1)
        show(empty2)
        show(local)
        txt.print_bool(empty1 != empty2 and empty2 != local)
        txt.nl()
    }
}
