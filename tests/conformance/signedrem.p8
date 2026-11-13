; Conformance: the remainder of signed numbers.  Upstream has it for the virtual machine and
; the host only ("remainder can only be used on unsigned integer operands on 6502
; target for now"), so the emulator suites skip this one.
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


    sub bytes(byte m, byte k) {
        s(m % 7)
        s(m % k)
        s(k % m)
        byte r = m
        r %= k
        s(r)
    }

    sub words(word m, word k) {
        s(m % 7)
        s(m % k)
        s(k % m)
        s(m % 1000)
        word r = m
        r %= k
        s(r)
    }

    sub start() {
        bytes(-100, 7)
        bytes(100, -7)
        bytes(-100, -7)
        line()
        words(-30000, 7)
        words(30000, -7)
        words(-30000, -1234)
        txt.nl()
    }
}
