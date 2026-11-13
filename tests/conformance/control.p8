; Conformance: loops, when, the if expression, goto, break and continue, and ranges that
; are empty, of one value, counted down, or stepped.
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

    sub ranges(ubyte lo, ubyte hi) {
        ubyte i
        ubyte n = 0
        for i in lo to hi
            n++
        u(n)
        n = 0
        for i in hi downto lo
            n += i
        u(n)
        n = 0
        for i in lo to hi step 3
            n += i
        u(n)
        n = 0
        for i in hi downto lo step -2
            n++
        u(n)
    }

    sub constant_ranges() {
        ubyte i
        uword total = 0
        for i in 0 to 255
            total += i
        u(total)
        total = 0
        for i in 255 downto 0
            total++
        u(total)
        uword w
        total = 0
        for w in 1000 to 1300 step 100
            total += w
        u(total)
        byte b
        word signed = 0
        for b in -3 to 3
            signed += b * 2
        s(signed)
        for b in 3 downto -3 step -3
            signed += b
        s(signed)
        ; over an array and over a string
        ubyte[] values = [10, 20, 30, 40]
        total = 0
        for i in values
            total += i
        u(total)
        total = 0
        for i in "abc"
            total += i - 'a' + 1
        u(total)
    }

    sub whiles(ubyte limit) {
        ubyte n = 0
        ubyte k = 0
        while k < limit {
            k += 3
            n++
        }
        u(n)
        n = 0
        do {
            n++
        } until n >= limit
        u(n)
        n = 0
        repeat limit {
            n += 2
        }
        u(n)
        n = 0
        repeat {
            n++
            if n == 9
                break
        }
        u(n)
        ; leaving and going round early, in loops inside each other
        uword hits = 0
        ubyte x
        ubyte y
        for y in 0 to 5 {
            if y == 4
                break
            for x in 0 to 5 {
                if x == y
                    continue
                if x > 3
                    break
                hits += x + y * 10
            }
        }
        u(hits)
    }

    sub choose(uword v) -> ubyte {
        when v {
            0 -> return 1
            1, 2, 3 -> return 2
            10 to 20 -> return 3
            300 -> return 4
            65535 -> return 5
            else -> return 0
        }
    }

    sub choose_signed(byte v) -> ubyte {
        when v {
            -128 -> return 1
            -1 -> return 2
            0 -> return 3
            1 to 5 -> return 4
            127 -> return 5
            else -> return 0
        }
    }

    sub ifexpr(word v) {
        word bigger = if v > 10  v  else  10
        s(bigger)
        ubyte sign = if v < 0  1  else  if v == 0  0  else  2
        u(sign)
        ; as an argument and in arithmetic
        u((if v == 3  100  else  200) + 1)
    }

    sub jumps(ubyte n) -> ubyte {
        ubyte count = 0
    again:
        count++
        if count < n
            goto again
        if count == 3
            goto three
        return count
    three:
        return 33
    }

    sub start() {
        ranges(3, 9)
        ranges(9, 3)
        ranges(5, 5)
        ranges(0, 0)
        line()
        constant_ranges()
        line()
        whiles(10)
        whiles(1)
        line()
        u(choose(0))
        u(choose(2))
        u(choose(10))
        u(choose(20))
        u(choose(21))
        u(choose(300))
        u(choose(65535))
        u(choose_signed(-128))
        u(choose_signed(-1))
        u(choose_signed(0))
        u(choose_signed(3))
        u(choose_signed(127))
        u(choose_signed(-2))
        line()
        ifexpr(-5)
        ifexpr(0)
        ifexpr(3)
        ifexpr(50)
        line()
        u(jumps(1))
        u(jumps(3))
        u(jumps(7))
        txt.nl()
    }
}
