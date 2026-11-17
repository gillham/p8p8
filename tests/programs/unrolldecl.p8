%import textio
%zeropage basicsafe

; a variable declared in an unroll loop: declared once, given its value every time
main {
    sub start() {
        uword total = 0
        ubyte step = 3
        repeat 4 {
            unroll 3 {
                ubyte nibble = step & 15
                uword wide = nibble * $0101
                total += wide
                step += 5
            }
        }
        txt.print_uw(total)
        txt.spc()
        txt.print_ub(step)
        txt.nl()
    }
}
