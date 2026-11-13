; Conformance: assignments that update in place (+=, -=, *=, /=, %=, &=, |=, ^=, <<=, >>=, ++, --)
; on variables of every integer type, array elements, struct fields, and through pointers.
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


    ubyte[4] bytes = [10, 20, 30, 40]
    uword[4] words = [1000, 2000, 3000, 4000]
    word[3] signed = [-100, 0, 100]

    struct Pair {
        ubyte small
        uword large
    }

    ubyte[8] room

    sub variables(ubyte ub, byte sb, uword uw, word sw) {
        ub += 100
        u(ub)
        ub -= 201
        u(ub)
        ub *= 3
        u(ub)
        ub /= 7
        u(ub)
        ub %= 4
        u(ub)
        ub |= $a0
        ub &= $f1
        ub ^= $ff
        u(ub)
        ub <<= 2
        u(ub)
        ub >>= 3
        u(ub)
        ub++
        ub--
        ub--
        u(ub)
        sb -= 100
        s(sb)
        sb *= 2
        s(sb)
        sb /= 3
        s(sb)
        sb >>= 1
        s(sb)
        sb = -sb
        s(sb)
        uw += 30000
        u(uw)
        uw -= 30001
        u(uw)
        uw *= 3
        u(uw)
        uw /= 10
        u(uw)
        uw %= 1000
        u(uw)
        uw |= $8001
        uw &= $f00f
        uw ^= $ffff
        u(uw)
        uw <<= 4
        u(uw)
        uw >>= 7
        u(uw)
        uw++
        u(uw)
        sw -= 30000
        s(sw)
        sw *= 2
        s(sw)
        sw /= 7
        s(sw)
        sw >>= 2
        s(sw)
        sw--
        s(sw)
        ; a byte into a word, and a variable amount
        uw += ub
        uw -= ub
        uw += ub
        u(uw)
        ub = 3
        uw <<= ub
        u(uw)
        uw >>= ub
        u(uw)
    }

    sub elements(ubyte i) {
        bytes[i] += 5
        bytes[i + 1] -= 25
        bytes[0] *= 2
        bytes[3] >>= 1
        bytes[i]++
        bytes[i + 2]--
        u(bytes[0])
        u(bytes[1])
        u(bytes[2])
        u(bytes[3])
        words[i] += 500
        words[i + 1] -= 2500
        words[0] *= 3
        words[3] >>= 2
        words[i]++
        words[i + 2]--
        words[i] |= $8000
        u(words[0])
        u(words[1])
        u(words[2])
        u(words[3])
        signed[i] -= 50
        signed[2] *= -3
        signed[0]--
        s(signed[0])
        s(signed[1])
        s(signed[2])
    }

    sub pointers(ubyte i) {
        ^^Pair p = &room as ^^Pair
        p.small = 250
        p.large = 60000
        p.small += 10
        p.large += 10000
        p.small <<= 1
        p.large >>= 1
        p.small++
        p.large--
        u(p.small)
        u(p.large)
        ^^ubyte bp = &bytes
        bp[i] += 100
        bp[2] ^= $0f
        bp[i]++
        u(bp[1])
        u(bp[2])
        ^^uword wp = &words
        wp[i] += 11
        wp[0] -= 1
        u(wp[1])
        u(wp[0])
        @(&bytes + 3) += 7
        u(bytes[3])
    }

    sub start() {
        variables(150, 30, 40000, 20000)
        line()
        elements(1)
        line()
        pointers(1)
        txt.nl()
    }
}
