%import textio
%zeropage basicsafe

; a string for an array of bytes in a struct, and blocks of memory() as the
; values of an array and of a struct's field
main {
    struct Node {
        ubyte kind
        ubyte[4] name
        bool flag
    }
    struct Holder { uword where  ubyte count }
    const uword block1 = memory("block1", 10, 0)
    uword[] blocks = [memory("block1", 10, 0), memory("block2", 20, 0), block1]

    sub start() {
        ^^Node n = [1, "abc", true]
        ^^Node full = [2, "wxyz", false]
        txt.print_ub(n.kind)
        txt.chrout(n.name[0])
        txt.chrout(n.name[2])
        txt.print_ub(n.name[3])
        txt.print_bool(n.flag)
        txt.chrout(full.name[3])
        txt.print_bool(full.flag)
        txt.spc()
        ^^Holder h = [block1, 7]
        txt.print_bool(h.where == block1)
        txt.print_bool(blocks[0] == block1)
        txt.print_bool(blocks[2] == block1)
        txt.print_bool(blocks[1] != block1)
        txt.print_ub(h.count)
        txt.nl()
    }
}
