; Struct instances copied as a whole between array elements and through pointers,
; in-place field updates, an array of instances local to a subroutine.
; Compared with upstream by make vmcmp and make nativecmp.

%import textio
%zeropage basicsafe

main {
    struct Point {
        word x
        word y
        ubyte color
    }

    ubyte[64] backing
    Point[3] trail = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    sub show(^^Point p) {
        txt.print_w(p.x)
        txt.spc()
        txt.print_w(p.y)
        txt.spc()
        txt.print_ub(p.color)
        txt.nl()
    }

    sub start() {
        Point[4] local
        ubyte i
        ubyte j
        for i in 0 to 3 {
            local[i].x = i as word * -10
            local[i].y = i as word * 100
            local[i].color = i + 65
        }
        i = 1
        j = 3
        local[i] = local[j]
        local[j].x -= 1
        local[j].color++
        for i in 0 to 3
            show(&local[i])

        ^^Point p1 = &trail[0]
        ^^Point p2 = &trail[2]
        p1^^ = p2^^
        trail[2] = local[0]
        trail[1] = p1[2]
        p1[1].y = 77
        for i in 0 to 2
            show(&trail[i])

        ^^Point walker = &backing
        walker[2].x = 1234
        walker[2].color = 9
        walker^^ = walker[2]
        txt.print_ub(backing[4])
        txt.spc()
        txt.print_ub(backing[14])
        txt.spc()
        txt.print_w(walker.x)
        txt.spc()
        txt.print_ub(len(trail))
        txt.nl()
        i = 2
        txt.print_w(trail[i].y + local[i].y)
        txt.spc()
        txt.print_bool(trail[0].color == local[3].color)
        txt.nl()
    }
}
