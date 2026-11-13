; Locals without an initial value are zero when the subroutine is entered, and only
; then: one declared in a loop keeps its value from round to round, one whose
; declaration is passed by is zero all the same, and a @dirty one keeps what it had.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
main {
    sub inloop() {
        repeat 3 {
            ubyte c
            c++
            txt.print_ub(c)
            txt.spc()
        }
        txt.nl()
    }
    sub bypass(bool flag) {
        if flag {
            ubyte seen
            seen = 5
        }
        txt.print_ub(seen)
        txt.spc()
        seen = 9
    }
    sub dirty() -> ubyte {
        ubyte @dirty n
        n++
        return n
    }
    sub keep(bool first) {
        if first {
            uword kept = 4242
        }
        txt.print_uw(kept)
        txt.spc()
    }
    sub start() {
        inloop()
        inloop()
        bypass(false)
        bypass(true)
        bypass(false)
        txt.nl()
        txt.print_ub(dirty())
        txt.spc()
        txt.print_ub(dirty())
        txt.spc()
        txt.print_ub(dirty())
        txt.nl()
        keep(true)
        keep(false)
        txt.nl()
    }
}
