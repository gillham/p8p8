; Conformance: the other ways to branch: chains of else if, if as an expression, on .. goto
; and on .. call, unroll, loops over arrays and strings.
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


    ubyte[] values = [3, 1, 4, 1, 5]
    word[] deltas = [-10, 20, -30]
    ubyte which

    sub one() {
        u(1)
    }
    sub two() {
        u(2)
    }
    sub three() {
        u(3)
    }

    sub chain(word v) {
        if v < -100
            u(1)
        else if v < 0
            u(2)
        else if v == 0
            u(3)
        else if v < 100 {
            u(4)
        } else {
            u(5)
        }
        ; if as a value, nested, and as an argument
        ubyte kind = if v < 0 1 else 2
        u(kind)
        u(if v == 0 10 else if v > 50 20 else 30)
        word size = if v < 0 then -v else v
        s(size)
    }

    sub jumps(ubyte v) {
        on v goto (first, second, third) else {
            u(99)
            goto done
        }
    first:
        u(10)
        goto done
    second:
        u(20)
        goto done
    third:
        u(30)
    done:
        on v call (one, two, three)
        on v call (three, two) else u(88)
    }

    sub unrolled(ubyte v) {
        ubyte n = v
        unroll 4 n += v
        u(n)
        unroll 3 {
            n--
            n ^= 1
        }
        u(n)
    }

    sub iterating(ubyte limit) {
        ubyte sum = 0
        ubyte each
        for each in values {
            if each > limit
                continue
            sum += each
        }
        u(sum)
        word total = 0
        word d
        for d in deltas
            total += d
        s(total)
        ubyte letters = 0
        for each in "hello world" {
            if each == ' '
                break
            letters++
        }
        u(letters)
        ; a loop that does not run, and one that runs once
        sum = 0
        for each in limit to limit - 1
            sum++
        for each in limit to limit
            sum += 10
        u(sum)
        ; the loop variable after the loop
        for each in 1 to limit {
            if each == 3
                break
        }
        u(each)
        ; counting down to zero, and words
        uword w
        uword wsum = 0
        for w in 1000 downto 0 step -250
            wsum += w
        u(wsum)
        long big = 0
        repeat limit as uword * 100
            big += 1000
        txt.print_l(big)
        item(12)
        ; while and until with a condition that is false at once
        which = 0
        while which > limit
            which++
        do {
            which += 2
        } until which > 0
        u(which)
    }

    sub start() {
        chain(-500)
        chain(-5)
        chain(0)
        line()
        chain(50)
        chain(500)
        line()
        jumps(0)
        jumps(1)
        jumps(2)
        jumps(7)
        line()
        unrolled(5)
        line()
        iterating(3)
        iterating(4)
        txt.nl()
    }
}
