; What a code generator may and may not assume over a call: a subroutine's own
; variables stay as they were, unless something else names them, or the subroutine
; runs again inside the call.  Also loops with the test at the end, comparisons with
; constants whose low byte is zero, constants added to addresses, counters, and a
; comparison stored from both of its arms.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

main {
    ubyte[20] buffer
    uword calls

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

    sub width() -> ubyte {
        calls++
        return 40
    }

    sub length() -> uword {
        calls++
        return 1000
    }

    ; own variables that are read again after calls
    sub row_of(uword position, uword start) -> uword {
        uword offset = position - start
        uword rows = offset / width()
        if rows != 0 and offset == rows * width() and position >= length()
            rows--
        return start + rows * width()
    }

    ; a variable of another subroutine, changed by name
    sub meddle() {
        main.victim.kept = 99
        main.victim.wide += 1000
    }

    sub victim(ubyte v) -> uword {
        ubyte kept = v
        uword wide = v * $0100
        meddle()
        return wide + kept
    }

    ; a subroutine that runs again inside its own call
    sub again(ubyte n) -> ubyte {
        ubyte mine = n
        if n > 0
            void again(n - 1)
        return mine
    }

    ; and one that does so by way of another
    sub ping(ubyte n) -> ubyte {
        ubyte here = n + 100
        if n > 0
            void pong(n - 1)
        return here
    }

    sub pong(ubyte n) -> ubyte {
        ubyte there = n + 50
        if n > 0
            void ping(n - 1)
        return there
    }

    ; a subroutine inside another, which changes the outer one's variable
    sub outer(ubyte v) -> ubyte {
        ubyte level = v
        inner()
        return level

        sub inner() {
            level += 7
        }
    }

    ; a parameter that is read after a call
    sub scaled(ubyte factor, uword base) -> uword {
        uword first = base + width()
        uword second = base * factor
        return first + second + factor
    }

    sub loops() {
        ; while: no round at all, some rounds, break and continue
        ubyte n = 0
        uword k = 9000
        while k < 8192 {
            n++
            k += 1000
        }
        show(n)
        k = 0
        while k < 8192 {
            n++
            k += 1000
        }
        show(n)
        show(k)
        ubyte i = 0
        ubyte total = 0
        while i < 20 {
            i++
            if i & 1 == 0
                continue
            if i > 11
                break
            total += i
        }
        show(total)
        show(i)
        ; one inside another, with a counter that counts down
        uword cells = 0
        ubyte y = 0
        while y < 5 {
            ubyte x = 3
            while x != 0 {
                x--
                cells += y
            }
            y++
        }
        show(cells)
        uword crc = $ffff
        repeat 8 {
            if crc & $8000 != 0
                crc = (crc << 1) ^ $1021
            else
                crc <<= 1
        }
        show(crc)
        txt.nl()
    }

    sub limits() {
        ; constants with a low byte of zero, on both sides of them
        uword[] edges = [0, $00ff, $0100, $0101, $1fff, $2000, $2001, $ffff]
        ubyte e
        for e in 0 to len(edges) - 1 {
            uword w = edges[e]
            showb(w < $2000)
            showb(w >= $2000)
            showb(w < $0100)
            showb(w > $0100)
            showb(w <= $2000)
            showb(w == $2000)
            txt.chrout(' ')
        }
        txt.nl()
        word[] signed = [-32768, -257, -256, -1, 0, 255, 256, 257, 32767]
        for e in 0 to len(signed) - 1 {
            word s = signed[e]
            showb(s < $0100)
            showb(s >= $0100)
            showb(s < -256)
            showb(s >= -256)
            txt.chrout(' ')
        }
        txt.nl()
    }

    sub addresses() {
        const ubyte WIDTH = 6
        ubyte k
        for k in 0 to len(buffer) - 1
            buffer[k] = k + 'a'
        ^^ubyte p = &buffer + WIDTH - 1
        txt.chrout(p[0])
        p = &buffer + WIDTH - 1 - width() / 20
        txt.chrout(p[0])
        p = &buffer + WIDTH + 3
        txt.chrout(p[0])
        p = &buffer + 10 - 4 - 6
        showb(p == &buffer)
        ubyte small = 100
        small = small + 60 - 10 + 5
        show(small)
        uword big = 50000
        big = big + 600 - 1 - 599
        show(big)
        big = big + 6 - 7
        show(big)
        big = big - 1 + 1
        show(big)
        txt.nl()
    }

    sub arms() {
        ubyte bits
        for bits in 0 to 7 {
            bool one = bits & 1 == 0
            bool two = bits & 2 != 0
            bool three = bits < 4
            showb(one)
            showb(two)
            showb(three)
            showb(one and two or three)
            txt.chrout(' ')
        }
        txt.nl()
    }

    sub start() {
        show(row_of(1000, 600))
        show(row_of(1010, 600))
        show(row_of(700, 600))
        show(calls)
        txt.nl()
        show(victim(3))
        show(again(4))
        show(ping(3))
        show(pong(2))
        show(outer(10))
        show(scaled(3, 500))
        txt.nl()
        loops()
        limits()
        addresses()
        arms()
    }
}
