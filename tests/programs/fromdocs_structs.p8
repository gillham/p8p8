%import textio
%zeropage basicsafe

; More from the documentation: pointer^^.field, the difference of two pointers
; in elements, the size of a string variable, an array of two-byte structs.
main {
    struct Enemy { ubyte xpos, ypos
                   uword health }
    ^^Enemy e1 = [1,2,300]
    uword[8] @nosplit ws
    struct Quad { uword a  uword b }
    struct Two { ubyte a  ubyte b }
    Two[4] squad = [[1,2],[3,4],[5,6],[7,8]]
    sub start() {
        txt.print_uw(e1^^.health)
        e1^^.health -= 10
        e1^^.xpos = 7
        txt.print_uw(e1.health)
        txt.print_ub(e1^^.xpos)
        txt.spc()
        ^^uword p1 = &ws
        ^^uword p2 = p1 + 3
        txt.print_ub(lsb(p2 - p1))
        ^^Quad q1 = &ws
        ^^Quad q2 = q1 + 2
        txt.print_ub(lsb(q2 - q1))
        txt.spc()
        str s1 = "hello"
        txt.print_ub(sizeof(s1))
        txt.spc()
        txt.print_ub(squad[2].a + squad[3].b)
        ^^Two second = &&squad[1]
        txt.print_ub(second.b)
        txt.nl()
    }
}
