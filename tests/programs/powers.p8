; Multiplication, division and remainder by powers of two (shifts and masks in a
; code generator), next to the same with other numbers and with variables.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

main {
    sub show(uword v) {
        txt.print_uw(v)
        txt.chrout(' ')
    }

    sub start() {
        ; (as parameters, so that no compiler works the results out itself)
        run(201, 51234, 1234567, 2, 16, -100, -20000)
    }

    sub run(ubyte b, uword w, long l, ubyte two, uword sixteen, byte sb, word sw) {
        show(b * 2)
        show(b * 4)
        show(b * 128)
        show(b * 3)
        show(b * two)
        show(w * 2)
        show(w * 8)
        show(w * 256)
        show(w * 4096)
        show(w * 10)
        show(w * sixteen)
        txt.nl()
        show(b / 2)
        show(b / 16)
        show(b / 128)
        show(b / 7)
        show(b / two)
        show(w / 2)
        show(w / 256)
        show(w / 32768)
        show(w / 1000)
        show(w / sixteen)
        txt.nl()
        show(b % 2)
        show(b % 16)
        show(b % 128)
        show(b % 7)
        show(w % 2)
        show(w % 256)
        show(w % 1024)
        show(w % 32768)
        show(w % 1000)
        show(w % sixteen)
        txt.nl()
        txt.print_l(l * 2)
        txt.chrout(' ')
        txt.print_l(l * 1024)
        txt.chrout(' ')
        txt.print_l(l * 3)
        txt.chrout(' ')
        txt.print_b(sb / 4)
        txt.chrout(' ')
        txt.print_w(sw / 16)
        txt.chrout(' ')
        txt.print_w(sw * 2)
        txt.chrout(' ')
        txt.print_b(sb * 1)
        txt.nl()
    }
}
