%import textio
%import floats
%zeropage basicsafe

; variables that are asked into the zero page (@zp, @requirezp), kept out of it
; (@nozp), of every kind: they behave as anywhere else, and an array there is
; cleared at the start like any other
main {
    uword @requirezp pointer1 = $3000
    word @zp counter = 9999
    byte @nozp plain = -5
    ubyte[6] @requirezp bytes
    long @requirezp big = 123456
    float @zp ratio = 1.5

    sub scale(ubyte @zp factor, uword @requirezp value) -> uword {
        return value * factor
    }

    sub start() {
        ubyte k
        for k in 0 to 5 {
            txt.print_ub(bytes[k])
            bytes[k] = k * 3
        }
        txt.spc()
        for k in 0 to 5 {
            txt.print_ub(bytes[k])
            txt.spc()
        }
        txt.nl()
        pointer1 += 2
        counter -= 10000
        plain++
        big += 1000000
        txt.print_uwhex(pointer1, true)
        txt.spc()
        txt.print_w(counter)
        txt.spc()
        txt.print_b(plain)
        txt.spc()
        txt.print_l(big)
        txt.spc()
        txt.print_uw(scale(7, 1000))
        txt.spc()
        ratio = ratio * 4.0 + 0.25
        floats.print(ratio)
        txt.nl()
        ; in the zero page they are where they were asked to be
        txt.print_bool(&pointer1 < 256)
        txt.print_bool(&bytes < 256)
        txt.print_bool(&big < 256)
        txt.print_bool(&plain >= 256)
        txt.nl()
    }
}
