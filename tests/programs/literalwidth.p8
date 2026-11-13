; A number written with the digits of a word is a word: $0002 and %0000000000000010
; make a byte multiplication a word one, $02 does not.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe
main {
    sub start() {
        ubyte b = 199
        b++
        txt.print_uw(b * $0002)
        txt.spc()
        txt.print_uw(b * $002)
        txt.spc()
        txt.print_uw(b * $02)
        txt.spc()
        txt.print_uw(b * %0000000000000010)
        txt.spc()
        txt.print_uw(b * %000000010)
        txt.spc()
        txt.print_uw(b * 0002)
        txt.spc()
        txt.print_l(b * $00000002)
        txt.spc()
        txt.print_l(b * $00002)
        txt.spc()
        txt.print_uw($0001 + b + b)
        txt.nl()
    }
}
