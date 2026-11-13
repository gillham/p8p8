; Operands that a code generator may use where they are instead of by way of a
; temporary: an array element as the second operand, a word plus one as an argument,
; a constant with a zero low byte added, variables over a multiplication or division,
; a pointer that is followed after a call, and a flag set from both arms of a test.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

main {
    ubyte[] counts = [3, 60, 200, 255, 0, 7]
    uword[] words = [0, 254, 255, 256, $7fff, $fffe, $ffff]
    ubyte[16] storage
    uword factor = 300
    ubyte divisor = 7
    bool big

    sub show(uword v) {
        txt.print_uw(v)
        txt.chrout(' ')
    }

    sub showb(bool b) {
        if b
            txt.chrout('y')
        else
            txt.chrout('n')
    }

    sub pass(uword v) -> uword {
        return v
    }

    sub digits(uword value) -> ubyte {
        ubyte n = 1
        while value >= 10 {
            value /= 10
            n++
        }
        return n
    }

    sub elements() {
        ubyte s
        for s in 0 to len(counts) - 1 {
            ubyte shifted = s << 4
            ubyte sum = shifted + counts[s]
            show(sum)
            uword need = s * $0040
            showb(need < counts[s])
            showb(counts[s] >= 60)
            ubyte both = (s | 8) & counts[s]
            show(both)
            ubyte less = 250 - counts[s]
            show(less)
        }
        txt.nl()
    }

    sub plus_one() {
        ubyte k
        for k in 0 to len(words) - 1 {
            uword w = words[k]
            show(pass(w + 1))
            show(digits(w + 1))
            show(pass(pass(w) + 1))
            show(pass(words[k] + 1))
        }
        txt.nl()
    }

    sub high_constant() {
        ubyte page
        for page in 0 to 3 {
            uword address = $a000 + page * factor
            show(address)
            address = $0100 + pass(page) * 2
            show(address)
        }
        txt.nl()
    }

    sub over_arithmetic() {
        uword start = 1000
        uword size = 37
        ubyte id
        for id in 1 to 3 {
            uword place = start + id * size
            uword rest = (place + factor) / divisor
            uword left = (place + factor) % divisor
            show(place)
            show(rest)
            show(left)
            show(start + size)
        }
        txt.nl()
    }

    sub pointers() {
        ^^ubyte p = &storage
        ubyte k
        for k in 0 to 15
            p[k] = k * 3
        ^^ubyte q = p + 4
        show(q[0])
        show(pass(q[1]))
        show(q[2])
        q[3] = lsb(pass(77))
        show(q[3])
        ubyte n = 5
        show(p[n])
        p[n] = p[n] + 1
        show(storage[5])
        txt.nl()
    }

    sub flags() {
        ubyte key
        for key in 195 to 199 {
            big = key == 197
            bool small = key != 197
            bool zero = key < 197
            showb(big)
            showb(small)
            showb(zero)
            ubyte value = 9
            if key == 198
                value = 0
            else
                value = 1
            show(value)
            if key >= 198
                value = 5
            else
                value = 0
            show(value)
        }
        txt.nl()
    }

    ; bits set and cleared in a variable where it is (tsb and trb on the 65C02), with a
    ; constant byte that changes nothing, and with the result looked at afterwards
    sub bits() {
        ubyte k
        uword result = 0
        ubyte mask = $f0
        for k in 0 to 3 {
            result |= $0400
            result |= 1 << k
            mask &= %11011111
            mask |= k
            if mask & 3 == 3
                result &= $ff0f
            show(result)
            show(mask)
        }
        result &= $00ff
        show(result)
        mask |= $80
        if mask & $80 != 0
            show(mask | 1)
        ^^ubyte p = &storage
        p[0] = mask
        p[0] |= 8
        show(p[0])
        show(storage[0] & $0f)
        txt.nl()
    }

    sub near(ubyte x, ubyte y) -> ubyte {
        return x * 3 + y
    }

    ; results added up, and arguments one more and one less than a variable
    sub neighbours() {
        ubyte col = 10
        ubyte row = 20
        ubyte around = near(col - 1, row - 1) + near(col - 1, row) + near(col - 1, row + 1) + near(col, row - 1)
                + near(col, row + 1) + near(col + 1, row - 1) + near(col + 1, row) + near(col + 1, row + 1)
        show(around)
        show(near(col, row - 2))
        show(near((col & 3) + 1, row ^ 1))
        ubyte masked = near(col, row) & near(row, col)
        show(masked)
        txt.nl()
    }

    ; the virtual registers under their different names, as loop variable, and over
    ; stores into an array
    sub registers() {
        cx16.r0 = $1234
        cx16.r0L = $56
        show(cx16.r0)
        cx16.r0H++
        show(cx16.r0)
        cx16.r1s = -2
        show(cx16.r1L)
        show(cx16.r1H)
        cx16.r2 = 0
        for cx16.r1L in 0 to 5 {
            storage[cx16.r1L] = cx16.r1L * 2
            storage[cx16.r1L + 1] = 99
            cx16.r2 += storage[cx16.r1L]
        }
        show(cx16.r2)
        show(cx16.r1L)
        cx16.r3 = &storage as uword
        cx16.r4L = 3
        show(@(cx16.r3 + cx16.r4L))
        @(cx16.r3 + 1) = 7
        show(storage[1])
        txt.nl()
    }

    sub start() {
        neighbours()
        registers()
        bits()
        elements()
        plus_one()
        high_constant()
        over_arithmetic()
        pointers()
        flags()
    }
}
