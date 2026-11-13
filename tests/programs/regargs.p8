; Arguments of every shape: one byte, two bytes, one word, a pointer, three values,
; a long, mixed sizes; arguments that are calls themselves; a parameter passed on;
; and a pointer parameter that is followed and written through.
; (On the 6502 the first shapes travel in A and Y: see "arguments in registers" in
; src/gen6502.p8.)
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

main {
    ubyte[] bytes = [10, 20, 30, 40]
    uword[] @nosplit words = [1000, 2000, 3000]     ; (a pointer to words needs them together)

    sub one(ubyte a) -> ubyte {
        return a + 1
    }

    sub two(ubyte a, ubyte b) -> uword {
        return (a as uword) * 256 + b
    }

    sub wide(uword w) -> uword {
        return w + 3
    }

    sub three(ubyte a, ubyte b, ubyte c) -> ubyte {
        return a + b + c
    }

    sub mixed(ubyte a, uword w) -> uword {
        return w - a
    }

    sub big(long v) -> long {
        return v + 100000
    }

    sub through(^^ubyte p) -> ubyte {
        ubyte first = p[0]
        p[1] = first + p[2]
        p++
        return p[0]
    }

    sub passes_on(ubyte a) -> ubyte {
        ubyte kept = a
        return one(a) + one(kept)
    }

    sub sum_words(^^uword p, ubyte n) -> uword {
        uword total = 0
        ubyte step = 1
        repeat n {
            total += p[0]
            if n == 3
                p += 1
            else
                p += step
        }
        return total
    }

    sub show(uword v) {
        txt.print_uw(v)
        txt.chrout(' ')
    }

    sub start() {
        ubyte x = 5
        uword big_one = 60000
        show(one(x))
        show(one(255))      ; (0: the result is a ubyte)
        show(two(x, 7))
        show(two(one(x), one(one(x))))
        show(wide(big_one))
        show(wide(two(1, 2)))
        show(three(1, x, one(x)))
        show(mixed(x, big_one))
        show(mixed(one(x), wide(big_one)))
        txt.print_l(big(-5))
        txt.chrout(' ')
        show(through(&bytes))
        show(bytes[1])
        show(passes_on(x))
        show(sum_words(&words, 3))
        show(sum_words(&words + 2, 2))
        txt.nl()
    }
}
