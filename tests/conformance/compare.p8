; Conformance: comparisons of every integer type, signed and unsigned, as conditions and
; as values, and the logical operators.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.
; (At most 24 lines of 40 characters: the C64 comparison is of one screen.)

%import textio
%zeropage basicsafe

main {
    ubyte col

    sub item(ubyte width) {
        col += width
        if col >= 36 {
            txt.nl()
            col = 0
        }
        else
            txt.spc()
    }

    sub u(uword v) {
        txt.print_uw(v)
        item(6)
    }

    sub s(word v) {
        txt.print_w(v)
        item(7)
    }

    ; a truth value as one letter, six to a group
    sub t(bool v) {
        if v
            txt.chrout('y')
        else
            txt.chrout('n')
        col++
        if col % 6 == 0
            item(1)
    }

    sub line() {
        if col != 0
            txt.nl()
        col = 0
    }

    sub ubytes(ubyte a, ubyte b) {
        t(a == b)
        t(a != b)
        t(a < b)
        t(a <= b)
        t(a > b)
        t(a >= b)
    }

    sub sbytes(byte a, byte b) {
        t(a == b)
        t(a != b)
        t(a < b)
        t(a <= b)
        t(a > b)
        t(a >= b)
    }

    sub uwords(uword a, uword b) {
        t(a == b)
        t(a != b)
        t(a < b)
        t(a <= b)
        t(a > b)
        t(a >= b)
    }

    sub swords(word a, word b) {
        t(a == b)
        t(a != b)
        t(a < b)
        t(a <= b)
        t(a > b)
        t(a >= b)
    }

    sub longs(long a, long b) {
        t(a == b)
        t(a != b)
        t(a < b)
        t(a <= b)
        t(a > b)
        t(a >= b)
    }

    ; against zero and against constants, where a compiler has shorter ways
    sub constants(ubyte a, byte b, uword c, word d) {
        t(a == 0)
        t(a != 0)
        t(a > 0)
        t(a >= 128)
        t(a < 128)
        t(a <= 255)
        t(b == 0)
        t(b < 0)
        t(b >= 0)
        t(b > 0)
        t(b <= 0)
        t(b > -1)
        t(c == 0)
        t(c != 0)
        t(c >= 256)
        t(c < 256)
        t(c >= $8000)
        t(c > 255)
        t(d == 0)
        t(d < 0)
        t(d >= 0)
        t(d > 0)
        t(d <= 0)
        t(d < -256)
    }

    sub logic(bool p, bool q, ubyte n) {
        t(p and q)
        t(p or q)
        t(p xor q)
        t(not p)
        t(not p or q)
        t(not (p or q))
        t(p and n > 5)
        t(n > 5 and n < 10)
        t(n < 5 or n > 9)
        t(p == q)
        t(p != q)
        t((n & 1) == 0 xor p)
    }

    ; a comparison that decides a branch, with something done on both sides
    sub branches(word v) {
        ubyte marks = 0
        if v < 0
            marks |= 1
        else
            marks |= 2
        if v == 0
            marks |= 4
        if v > 100 or v < -100
            marks |= 8
        if v >= -1 and v <= 1
            marks |= 16
        if not (v == 5)
            marks |= 32
        u(marks)
    }

    sub start() {
        ubytes(5, 5)
        ubytes(5, 200)
        ubytes(200, 5)
        ubytes(0, 255)
        sbytes(-5, -5)
        sbytes(-5, 5)
        sbytes(5, -5)
        sbytes(-128, 127)
        sbytes(100, -100)
        line()
        uwords(1000, 1000)
        uwords(255, 256)
        uwords(40000, 300)
        uwords($00ff, $ff00)
        swords(-1000, -1000)
        swords(-1, 1)
        swords(1, -1)
        swords(-32768, 32767)
        swords(30000, -30000)
        swords(256, 255)
        line()
        longs(100000, 100000)
        longs(-100000, 100000)
        longs(65536, 65535)
        longs(-1, 0)
        line()
        constants(0, 0, 0, 0)
        constants(128, -128, 256, -257)
        constants(255, 127, 65535, 32767)
        constants(1, -1, 255, -1)
        line()
        logic(true, true, 7)
        logic(true, false, 3)
        logic(false, true, 10)
        logic(false, false, 12)
        line()
        branches(-200)
        branches(-1)
        branches(0)
        branches(1)
        branches(5)
        branches(101)
        txt.nl()
    }
}
