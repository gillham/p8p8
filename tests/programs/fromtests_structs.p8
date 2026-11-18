%import textio
%zeropage basicsafe

; More from upstream's unit tests, around structs: an array field with values,
; fields given by name (the others 0), pointer[i]^^, a field reached by an alias,
; an array of the addresses of a label, a subroutine and a block.
main {
    struct Node {
        ubyte a
        bool flag
        ubyte[5] letters
        word number
    }
    struct Enemy { ubyte hp  ubyte x  ubyte y  ubyte frame }
    struct Pair { uword first  ubyte second }

    ^^Pair @shared pairs = $0600

    sub start() {
somewhere:
        ^^Node k = [1, true, [65, 66, 67, 68, 0], 9999]
        txt.print_ub(k.a)
        txt.print_bool(k.flag)
        txt.chrout(k.letters[1])
        txt.chrout(k.letters[3])
        txt.print_w(k.number)
        txt.spc()
        ^^Enemy e = ^^Enemy:[hp=100, y=7]
        txt.print_ub(e.hp)
        txt.print_ub(e.x)
        txt.print_ub(e.y)
        txt.print_ub(e.frame)
        txt.spc()
        pairs[0]^^.first = 1111
        pairs[2]^^.first = 3333
        pairs[2]^^.second = 44
        txt.print_uw(pairs[2].first + pairs[0].first)
        txt.print_ub(pairs[2]^^.second)
        txt.spc()
        alias p = pairs
        p.second = 5
        alias o = other
        o.node.first = 600
        txt.print_ub(pairs.second)
        txt.print_uw(other.node.first)
        txt.spc()
        uword[] addresses = [somewhere, start, main]
        txt.print_bool(addresses[0] == &somewhere)
        txt.print_bool(addresses[1] == &start)
        txt.print_bool(addresses[2] == &main)
        txt.nl()
    }
}

other {
    ^^main.Pair @shared node = $0700
}
