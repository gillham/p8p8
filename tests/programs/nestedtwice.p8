%import textio
%zeropage basicsafe

; A subroutine declared in a subroutine that is itself declared in one: it is
; called from its parent, uses the variables of both outer ones, and has
; parameters and a variable of its own.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

main {
    sub outer(uword base) -> uword {
        uword total = base
        middle(3)
        middle(5)
        return total

        sub middle(ubyte times) {
            ubyte round
            for round in 1 to times
                total += inner(round, times)

            sub inner(ubyte a, ubyte b) -> uword {
                uword product = a * (b as uword)
                return product + base
            }
        }
    }

    sub start() {
        txt.print_uw(outer(100))
        txt.spc()
        txt.print_uw(outer(7))
        txt.nl()
    }
}
