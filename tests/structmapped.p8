; a struct variable at a fixed address
%import textio
%zeropage basicsafe

main {
    struct Point {
        ubyte x
        uword y
    }
    &Point p = $c000
    ^^Point[1] ptrs = [&&p]
    Point copy

    sub start() {
        p.x = 42
        p.y = 5000
        txt.print_ub(p.x)
        txt.spc()
        txt.print_uw(p.y)
        txt.spc()
        txt.print_ub(@($c000))
        txt.spc()
        txt.print_uw(peekw($c001))
        txt.nl()
        ptrs[0].x = 7
        txt.print_ub(p.x)
        txt.spc()
        copy = p
        copy.y++
        txt.print_uw(copy.y)
        txt.spc()
        p = copy
        txt.print_uw(p.y)
        txt.spc()
        ^^Point q = &&p
        q.y += 10
        txt.print_uw(p.y)
        txt.nl()
    }
}
