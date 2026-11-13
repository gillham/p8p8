; Conformance: subroutines: arguments of every type and number, results, several results,
; subroutines inside subroutines, early returns, defer, and calls as arguments of calls.
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


    sub one(ubyte a) -> ubyte {
        return a + 1
    }

    sub two(ubyte a, ubyte b) -> uword {
        return a * $0100 + b
    }

    sub three(uword a, ubyte b, word c) -> word {
        return (a as word) - b + c
    }

    sub many(ubyte a, uword b, byte c, word d, bool e, long f) -> long {
        long total = f
        total += a
        total += b
        total += c
        total += d
        if e
            total = -total
        return total
    }

    sub pair(uword v) -> ubyte, ubyte {
        return msb(v), lsb(v)
    }

    sub triple(ubyte v) -> uword, bool, byte {
        return v * 1000, v > 5, v as byte - 10
    }

    sub passes_on(uword v) -> ubyte, ubyte {
        return pair(v + 1)
    }

    sub flag(ubyte v) -> bool {
        if v == 0
            return false
        if v > 100
            return true
        return v & 1 == 1
    }

    sub outer(ubyte v) -> uword {
        uword sum = inner(v) + inner(v + 1)
        return sum

        sub inner(ubyte x) -> uword {
            return x * 10 + v
        }
    }

    uword trail

    sub deferred(ubyte v) -> ubyte {
        defer trail = trail * 10 + 1
        defer trail = trail * 10 + 2
        if v == 0
            return 9
        trail = trail * 10 + 3
        return v
    }

    sub nothing() {
        trail += 5
    }

    sub start() {
        u(one(41))
        u(one(255))
        u(two(3, 4))
        s(three(100, 50, -200))
        txt.print_l(many(1, 2, -3, -4, false, 100000))
        item(12)
        txt.print_l(many(1, 2, -3, -4, true, 100000))
        item(12)
        line()
        ubyte hi
        ubyte lo
        hi, lo = pair($1234)
        u(hi)
        u(lo)
        hi, lo = passes_on($12ff)
        u(hi)
        u(lo)
        uword big
        bool yes
        byte small
        big, yes, small = triple(7)
        u(big)
        t(yes)
        s(small)
        big, yes, small = triple(2)
        u(big)
        t(yes)
        s(small)
        ; one result dropped
        hi, void = pair($abcd)
        u(hi)
        line()
        t(flag(0))
        t(flag(200))
        t(flag(7))
        t(flag(8))
        ; calls as arguments, and a result used in a condition
        u(one(one(one(1))))
        u(two(one(1), one(2)))
        if flag(one(6))
            u(111)
        else
            u(222)
        u(outer(3))
        line()
        trail = 0
        u(deferred(4))
        u(trail)
        trail = 0
        u(deferred(0))
        u(trail)
        nothing()
        void one(3)
        u(trail)
        txt.nl()
    }
}
