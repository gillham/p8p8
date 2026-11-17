%import textio
%zeropage basicsafe

; Multiplication by constants that are neither a power of two nor one of the
; library's small ones: words and bytes, values that carry into the high byte
; and that overflow, a constant with many bits set, and a signed number.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

main {
    sub words(uword w) {
        txt.print_uw(w * 37)
        txt.spc()
        txt.print_uw(w * 130)
        txt.spc()
        txt.print_uw(w * 257)
        txt.spc()
        txt.print_uw(w * 1000)
        txt.spc()
        txt.print_uw(w * 4097)
        txt.spc()
        txt.print_uw(w * 255)
        txt.spc()
        txt.print_uw(w * 43691)
        txt.nl()
    }

    sub bytes(ubyte b) {
        txt.print_ub(b * 17)
        txt.spc()
        txt.print_ub(b * 34)
        txt.spc()
        txt.print_ub(b * 129)
        txt.spc()
        txt.print_uw((b as uword) * 37)
        txt.spc()
        txt.print_uw((b as uword) * 300)
        txt.nl()
    }

    sub signed(word s) {
        txt.print_w(s * 37)
        txt.spc()
        txt.print_w(s * -37)
        txt.spc()
        txt.print_w(s * 130)
        txt.nl()
    }

    sub start() {
        words(0)
        words(1)
        words(7)
        words(1234)
        words(65535)
        bytes(0)
        bytes(3)
        bytes(200)
        signed(5)
        signed(-5)
        signed(-300)
    }
}
