; struct variables: instances declared directly, their fields, copies and addresses
%import textio
%zeropage basicsafe

main {
    struct Point {
        ubyte x
        uword y
    }
    struct Node {
        ^^Node next
        uword value
    }
    struct Holder {
        ^^Point pt
        uword extra
    }

    Point global_point = [7, 1000]
    Point empty
    Point named = Point:[x=3, y=300]
    Point typed = Point:[2, 200]
    Node first
    Node second
    Point p1
    Point p2
    ^^Point[2] ptrs = [&&p1, &&p2]
    Holder h = [&&p2, 99]
    Point[2] pts = [[10, 20], [30, 40]]

    sub show(uword a, uword b) {
        txt.print_uw(a)
        txt.spc()
        txt.print_uw(b)
        txt.nl()
    }

    sub show_at(^^Point p) {
        show(p.x, p.y)
    }

    sub counter() -> uword {
        ; an initializer is applied once: the variable keeps its value between calls
        Point state = [1, 100]
        state.x++
        state.y += 10
        return state.y + state.x
    }

    sub start() {
        Point local_point = [3, 3000]
        local_point.x = 9
        global_point.y = 66
        show(local_point.x, local_point.y)
        show(global_point.x, global_point.y)
        show(empty.x, empty.y)
        show(named.x, named.y)
        show(typed.x, typed.y)

        ; a chain of fields through a pointer in a struct variable
        first.next = &second
        second.value = 42
        txt.print_uw(first.next.value)
        txt.spc()
        first.next.value = 77
        txt.print_uw(second.value)
        txt.nl()

        ; a whole struct is copied by value
        empty = global_point
        empty.x = 99
        show(global_point.x, empty.x)
        show(empty.y, sizeof(empty))
        show(sizeof(local_point), sizeof(Point))

        ; a struct type of the subroutine's own
        struct Pair {
            uword left
            ubyte right
        }
        Pair pair = [100, 20]
        pair.left = 300
        pair.right++
        show(pair.left, pair.right)

        ; with elements of an array of structs
        Point tmp = pts[0]
        pts[0] = pts[1]
        pts[1] = tmp
        tmp = pts[0]
        pts[0].y = 999
        show(pts[0].x, pts[0].y)
        show(pts[1].x, pts[1].y)
        show(tmp.x, tmp.y)

        ; addresses of struct variables, in data and in code
        p1.x = 11
        p2.y = 222
        show(ptrs[0].x, ptrs[1].y)
        show(h.pt.y, h.extra)
        h.pt.x = 5
        show(p2.x, h.pt.x)
        ^^Point pp = &&local_point
        pp.y++
        show_at(pp)
        show_at(&&global_point)
        pp^^ = named
        show_at(&&local_point)

        show(counter(), counter())
    }
}
