; A float cast to an integer loses its fraction: it is not rounded.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%import floats
main {
    sub show(float f) {
        txt.print_ub(f as ubyte)
        txt.spc()
        txt.print_uw(f as uword)
        txt.spc()
        txt.print_w(-f as word)
        txt.spc()
        txt.print_b(-f as byte)
        txt.nl()
    }
    sub start() {
        show(2.7)
        show(2.5)
        show(3.5)
        show(99.99)
    }
}
