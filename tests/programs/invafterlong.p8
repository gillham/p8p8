%import textio

; The complement of a byte and of a word right after arithmetic on a wider
; type (p8p8's LLVM back end took the width of the earlier result for it).
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

main {
    long total = 100000
    uword step = 300

    sub mask(ubyte n) -> ubyte {
        return 1 << n
    }

    sub start() {
        ubyte available = %11111100
        total = total * 3 + step
        available &= ~mask(3)
        txt.print_ub(available)
        txt.spc()
        total += total
        uword w = ~step
        txt.print_uw(w)
        txt.spc()
        total -= 7
        ubyte b = ~available
        txt.print_ub(b)
        txt.spc()
        txt.print_l(total)
        txt.nl()
    }
}
