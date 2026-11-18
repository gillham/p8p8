%import textio

; builtins and loop forms from upstream's documentation: pokemon, setlsb and
; setmsb, memory() naming a block declared elsewhere, a linked list walk that
; stops at a node and one whose variable is not declared
main {
    struct Node {
        ubyte value
        ^^Node next
    }
    ubyte[4] cells

    sub start() {
        ^^Node n1 = [1, 0]
        ^^Node n2 = [2, 0]
        ^^Node n3 = [3, 0]
        ^^Node last = [99, 0]
        n1.next = n2
        n2.next = n3
        n3.next = last
        for p in n1 via .next
            txt.print_ub(p.value)
        txt.spc()
        ^^Node node
        for node in n1 via .next until last
            txt.print_ub(node.value)
        txt.spc()
        for q in n1 via .next until n3
            txt.print_ub(q.value)
        txt.nl()

        cells[0] = 77
        ubyte old = pokemon(&cells, 99)
        txt.print_ub(old)
        txt.spc()
        txt.print_ub(cells[0])
        txt.nl()

        uword @shared w = $1234
        long @shared l = $11223344
        setlsb(w, $55)
        setmsb(w, $66)
        setlsb(l, $77)
        setmsb(l, $88)
        txt.print_uwhex(w, true)
        txt.spc()
        txt.print_ulhex(l, true)
        txt.nl()

        pointer block1 = memory("blk", 500, 0)
        pointer block2 = memory("blk")
        txt.print_bool(block1 == block2)
        txt.nl()
    }
}
