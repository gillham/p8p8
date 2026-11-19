%import textio
%zeropage basicsafe

; Overlays and 16-bit code (make overlaycheck, also with -cpu 65816): word arithmetic on
; variables in an overlay, in the main program around the calls, and in a loop that
; calls into an overlay.
main {
    uword @shared seed = 12345

    sub start() {
        uword a = 1000
        uword b = 77
        uword c
        ubyte i
        for i in 1 to 20 {
            c = a + b
            a = c - 3
            b = mix.step(a, b) + c
            a ^= b
        }
        txt.print_uw(a)
        txt.spc()
        txt.print_uw(b)
        txt.spc()
        txt.print_uw(mix.total)
        txt.spc()
        txt.print_uw(mix.fill(500))
        txt.nl()
    }
}

mix {
    %overlay 1

    uword total
    uword[16] table

    sub step(uword x, uword y) -> uword {
        uword t = x + y
        t += main.seed
        t = t << 1
        t -= y
        total += t & $0fff
        main.seed = main.seed + t + 1
        return t ^ x
    }

    sub fill(uword start) -> uword {
        uword sum = 0
        uword v = start
        ubyte k
        for k in 0 to 15 {
            table[k] = v + other.offset(k)
            v += 3
            sum += table[k]
        }
        return sum
    }
}

other {
    %overlay 2

    sub offset(ubyte k) -> uword {
        uword w = k
        w = w * 2 + 1
        return w
    }
}
