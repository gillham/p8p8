; Struct variables: what upstream refuses.

%zeropage basicsafe

main {
    struct Point {
        ubyte x
        uword y
    }
    Point g = [1, 2]
    ^^Point gp
    Point[2] pts

    sub take(^^Point p) {
        p.x++
    }

    sub start() {
        Point p
        Point q = [3, 4]
        Point fine = pts[1]                 ; fine: a copy
        p = q                               ; fine
        gp^^ = p                            ; fine
        pts[0] = p                          ; fine
        take(&&p)                           ; fine
        p = 5                               ; error: not a struct
        p = [1, 2]                          ; error: field values only where it is declared
        p = Point:[1, 2]                    ; error
        p = gp^^                            ; error
        if p == q                           ; error (two)
            cx16.r1L++
        Point three = [1, 2, 3]             ; error: a value for each field or for none
        Point number = 5                    ; error
        Point boolean = [true, 2]           ; error
        Point fraction = [1, 2.5]           ; error
        Point text = ["a", 2]               ; error
        take(p)                             ; error: by its address only
        cx16.r0L = p.x + q.x + g.x + fine.x + three.x + number.x + boolean.x + fraction.x + text.x
    }
}
