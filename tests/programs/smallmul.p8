; Multiplication by the small constants a library may have routines for, by other
; constants, and of a word by a byte.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

main {
    sub show(uword v) {
        txt.print_uw(v)
        txt.chrout(' ')
    }

    sub run(ubyte b, uword w, ubyte n) {
        show(b * 3)
        show(b * 5)
        show(b * 6)
        show(b * 7)
        show(b * 9)
        show(b * 10)
        show(b * 11)
        show(b * 12)
        show(b * 13)
        show(b * 14)
        show(b * 15)
        show(b * 20)
        show(b * 25)
        show(b * 17)
        txt.nl()
        show(w * 3)
        show(w * 5)
        show(w * 6)
        show(w * 7)
        show(w * 9)
        show(w * 10)
        show(w * 12)
        show(w * 15)
        show(w * 20)
        show(w * 25)
        show(w * 40)
        show(w * 50)
        show(w * 80)
        show(w * 100)
        show(w * 11)
        txt.nl()
        show(w * (n as uword))
        show((b as uword) * (n as uword))
        show((n as uword) * w)
        uword big = 300
        show(w * big)
        txt.nl()
    }

    sub start() {
        run(7, 1234, 201)
        run(255, 65535, 255)
    }
}
