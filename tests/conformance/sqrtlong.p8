; Conformance: the square root of a long.  The emulator suites leave this one out: built for
; the 6502 by the reference compiler it prints other numbers (768 for the root of
; 1000000), which the virtual machine and the host do not.
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


    sub root(long l) {
        uword r = sqrt(l)
        u(r)
    }

    sub start() {
        root(1000000)
        root(65536)
        root(16)
        root(250000)
        root(15)
        root(2000000000)
        root(1)
        txt.nl()
    }
}
