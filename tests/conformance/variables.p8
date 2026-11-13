; Conformance: variables and names: initial values and where they are set again, constants,
; scopes, memory-mapped variables, zero-initialized locals, aliases and enums.
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


    const ubyte LIMIT = 10
    const uword BASE = $c000 + LIMIT * 2
    const long BIG = 100000 * 3
    const bool YES = LIMIT > 5
    ubyte counter = 5
    uword total
    word below = -1
    ubyte a1, a2, a3 = 7

    enum Color {
        RED,
        GREEN,
        BLUE = 10,
        WHITE
    }

    alias show = other.report
    alias far = other.distance

    sub constants(ubyte v) {
        u(LIMIT)
        u(BASE)
        txt.print_l(BIG)
        item(12)
        t(YES)
        u(v + LIMIT)
        u(BASE + v)
        u(other.SIZE)
        u(other.SIZE * LIMIT)
        const ubyte LOCAL = LIMIT / 2
        u(LOCAL)
    }

    sub locals(ubyte v) -> ubyte {
        ; set again on every call
        ubyte fresh = 3
        ; zero on every call
        ubyte empty
        uword wide
        bool flag
        fresh += v
        empty += v
        wide += v
        u(fresh)
        u(empty)
        u(wide)
        t(flag)
        flag = true
        ; kept from call to call: a block's variable
        counter += v
        total += counter
        return counter
    }

    sub scopes(ubyte v) {
        ubyte counter = v           ; hides the block's
        counter++
        u(counter)
        u(main.counter)
        u(other.counter)
        other.counter += v
        u(other.counter)
        other.bump()
        u(other.counter)
        u(other.inner.depth)
        other.inner.depth = v
        u(other.inner.twice())
        show(v)
        far = 1234
        u(other.distance)
        u(a1)
        u(a2)
        u(a3)
        s(below)
    }

    sub enums(ubyte v) {
        u(Color::RED)
        u(Color::GREEN)
        u(Color::BLUE)
        u(Color::WHITE)
        ubyte c = Color::WHITE
        t(c == v)
        when v {
            Color::RED -> u(1)
            Color::WHITE -> u(2)
            else -> u(3)
        }
    }

    sub start() {
        constants(3)
        line()
        u(locals(1))
        u(locals(2))
        u(locals(3))
        u(total)
        line()
        scopes(20)
        line()
        enums(11)
        txt.nl()
    }
}

other {
    const ubyte SIZE = 25
    ubyte counter = 100
    uword distance

    sub report(ubyte v) {
        main.u(v + SIZE)
    }

    sub bump() {
        counter++
    }

    sub inner() {
        ubyte depth = 4
        sub twice() -> ubyte {
            return depth * 2
        }
    }
}
