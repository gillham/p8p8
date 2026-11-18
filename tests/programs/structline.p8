%import textio
%zeropage basicsafe

; struct fields that share a line
main {
    struct Point { uword x  uword y }
    struct Mixed { ubyte kind  word delta
        bool on }
    Point[3] points
    sub start() {
        points[0].x = 1
        points[2].y = 4000
        ^^Mixed m = 20000
        m.kind = 7
        m.delta = -300
        m.on = true
        txt.print_uw(points[0].x + points[2].y)
        txt.spc()
        txt.print_w(m.delta + m.kind)
        txt.print_bool(m.on)
        txt.print_ub(sizeof(Point) + sizeof(Mixed))
        txt.nl()
    }
}
