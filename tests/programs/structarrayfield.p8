%import textio

; A struct with array fields, reached through a pointer: elements read and
; written with a constant and with a variable index, bytes, words and longs,
; and the field after the arrays.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

main {
    struct Map {
        uword rows
        ubyte[4] flags
        long[3] planes
        uword[2] pair
        ubyte last
    }

    ubyte[32] storage

    sub show(^^Map m, ubyte i) {
        txt.print_ub(m.flags[i])
        txt.spc()
        txt.print_l(m.planes[i])
        txt.spc()
        txt.print_uw(m.pair[i & 1])
        txt.spc()
        txt.print_ub(m.last)
        txt.nl()
    }

    sub start() {
        ^^Map m = &storage
        ubyte i
        m.rows = 7
        for i in 0 to 3
            m.flags[i] = i + 1
        for i in 0 to 2
            m.planes[i] = (i + 1) as long * 100000
        m.pair[0] = 500
        m.pair[1] = 600
        m.last = 9
        for i in 0 to 2
            show(m, i)
        m.planes[1] = 123456
        m.flags[3] = m.flags[0] + 40
        i = 2
        m.planes[i] += 5
        m.pair[1]++
        m.rows = m.pair[0] + m.flags[3]
        txt.print_l(m.planes[1])
        txt.spc()
        txt.print_l(m.planes[2])
        txt.spc()
        txt.print_ub(m.flags[3])
        txt.spc()
        txt.print_uw(m.pair[1])
        txt.spc()
        txt.print_uw(m.rows)
        txt.spc()
        txt.print_ub(sizeof(Map))
        txt.nl()
    }
}
