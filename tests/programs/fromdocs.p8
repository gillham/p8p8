%import textio
%import floats
%zeropage basicsafe

; From a reading of upstream's documentation against p8p8: one value for several
; names, a loop from the last element to the first, zeros when a subroutine with
; several values ends without a return, wide enum members, an untyped constant's
; size, and a cast to bool of more than a byte.
main {
    enum Wide { A = 255, B, C = 70000, D }
    const UNTYPED = 5
    struct Node { ubyte value  ^^Node next }

    sub pick(ubyte id) -> ubyte, uword {
        when id {
            1 -> return 11, 1111
        }
    }

    sub start() {
        ubyte d, e, f = 42
        txt.print_ub(d)
        txt.print_ub(e)
        txt.print_ub(f)
        bool f1, f2 = true
        txt.print_bool(f1)
        txt.print_bool(f2)
        uword a, b, c = 1000
        txt.print_uw(a + b + c)
        ubyte @shared v = 3
        ubyte g, h = v + 1
        txt.print_ub(g)
        txt.print_ub(h)
        txt.nl()
        ubyte[] arr = [1, 2, 3]
        ubyte x
        for x in arr step -1
            txt.print_ub(x)
        for x in "hello" step -1
            txt.chrout(x)
        txt.nl()
        ubyte p1
        uword p2
        p1, p2 = pick(1)
        txt.print_ub(p1)
        txt.print_uw(p2)
        p1, p2 = pick(2)
        txt.print_ub(p1)
        txt.print_uw(p2)
        txt.nl()
        txt.print_uw(Wide::B)
        txt.spc()
        txt.print_l(Wide::D)
        txt.spc()
        txt.print_ub(sizeof(UNTYPED))
        txt.nl()
        uword @shared w = 256
        long @shared l = 65536
        float @shared fl = 0.5
        txt.print_bool(w as bool)
        txt.print_bool(l as bool)
        txt.print_bool(fl as bool)
        if w as bool
            txt.print("y")
        txt.nl()
    }
}
