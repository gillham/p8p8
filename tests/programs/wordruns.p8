%import textio
%zeropage basicsafe

; Runs of word arithmetic on variables, the kind that the 65816 does in its
; 16-bit accumulator: every operation with a variable, a number and another
; result as its operand; values that have to wait while another is worked
; out; a variable that is changed while an earlier copy of it is still used;
; shifts by one, by eight and more, and by fifteen; and comparisons at the end.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

main {
    uword a
    uword b
    uword c
    uword d
    uword e
    word s
    word t

    sub u(uword v) {
        txt.print_uw(v)
        txt.spc()
    }

    sub yn(bool v) {
        if v
            txt.chrout('y')
        else
            txt.chrout('n')
    }

    ; (values the compiler cannot know)
    sub setup(uword first, uword second) {
        a = first
        b = second
        c = first + second + 26977
        s = 0 - (second as word) - 556
        t = (second as word) - 579
    }

    sub sums() {
        d = a + b
        e = d - c
        u(d)
        u(e)
        d = (a + b) - (c - b)
        u(d)
        d = (a - b) + (c + 1000) - (a & 255)
        u(d)
        d = a
        d += b
        d -= 77
        d += d
        u(d)
        e = c - d
        e -= a
        u(e)
        txt.nl()
    }

    sub bits() {
        d = (a & c) | (b ^ $5555)
        u(d)
        d = (a | b) & (c ^ a)
        u(d)
        d = ~a
        e = b ^ $ffff
        u(d)
        u(e)
        d = a
        d &= $0ff0
        d |= b
        d ^= c
        u(d)
        txt.nl()
    }

    sub shifts() {
        d = a << 1
        e = c >> 1
        u(d)
        u(e)
        d = (a << 3) + (c >> 4)
        u(d)
        d = (b << 8) | (c >> 8)
        u(d)
        d = (b << 9) ^ (c >> 11)
        u(d)
        d = (c << 1) | (c >> 15)
        u(d)
        d = c
        d <<= 1
        d >>= 1
        u(d)
        txt.nl()
    }

    sub waiting() {
        ; the earlier values are still needed when the later ones are worked out
        d = (a + b) ^ ((c - a) | (b + 5))
        u(d)
        d = ((a - 1) & (b + 1)) + ((c + 2) ^ (a - 3))
        u(d)
        ; a copy of a variable, then the variable changes, then the copy is used
        e = a
        a = a + b
        d = a - e
        u(d)
        u(a)
        e = b
        b += 1
        b += e
        u(b)
        setup(12345, 678)
        txt.nl()
    }

    sub signed() {
        word x = s + t
        word y = s - t
        txt.print_w(x)
        txt.spc()
        txt.print_w(y)
        txt.spc()
        x = -s
        x += t
        txt.print_w(x)
        txt.spc()
        txt.nl()
    }

    sub compares() {
        yn(a + b == 13023)
        yn(a + b != 13023)
        yn(a - b < c)
        yn(c - a > a)
        yn(a + c >= b)
        yn((a ^ b) <= 100)
        yn(s + t < 0)
        yn(s - t > -2000)
        d = 0
        uword i
        for i in 0 to 999 {
            d += i ^ (i >> 2)
            if d > 60000
                d -= 60000
        }
        txt.spc()
        u(d)
        txt.nl()
    }

    sub start() {
        setup(12345, 678)
        sums()
        bits()
        shifts()
        waiting()
        signed()
        compares()
    }
}
