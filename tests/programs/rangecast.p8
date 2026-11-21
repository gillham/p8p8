; a cast at the end of a range belongs to the end value
%import textio
%zeropage basicsafe
main {
    sub start() {
        ubyte ub = 3
        uword uw = 5
        ub += cx16.r2L
        uw += cx16.r3
        long n
        long total
        for n in 0 to uw as long {
            total += n
        }
        txt.print_l(total)
        txt.nl()
        for n in 1 to uw + ub as long step 2 {
            total += n
        }
        txt.print_l(total)
        txt.nl()
        uword w
        for w in uw downto ub {
            total += w
        }
        txt.print_l(total)
        txt.nl()
    }
}
