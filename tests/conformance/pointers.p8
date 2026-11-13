; Conformance: typed pointers and structs: following, arithmetic that counts in elements,
; fields of every size, pointers in structs and in arrays, and every form of address-of.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.
; (At most 24 lines of 40 characters: the C64 comparison is of one screen.)

%import textio
%zeropage basicsafe

main {
    ubyte col

    sub item(ubyte width) {
        col += width
        if col >= 36 {
            txt.nl()
            col = 0
        }
        else
            txt.spc()
    }

    sub u(uword v) {
        txt.print_uw(v)
        item(6)
    }

    sub s(word v) {
        txt.print_w(v)
        item(7)
    }

    ; a truth value as one letter, six to a group
    sub t(bool v) {
        if v
            txt.chrout('y')
        else
            txt.chrout('n')
        col++
        if col % 6 == 0
            item(1)
    }

    sub line() {
        if col != 0
            txt.nl()
        col = 0
    }


    struct Node {
        ubyte id
        word value
        ^^Node next
        bool live
    }

    ubyte[64] heap
    ubyte[] bytes = [10, 20, 30, 40, 50]
    uword[] @nosplit words = [1000, 2000, 3000, 4000]
    word[] @nosplit swords = [-5, 5, -500]
    uword plain = 12345
    ^^Node[3] table

    sub scalars(ubyte i) {
        ^^ubyte bp = &bytes
        u(bp^^)
        u(bp[i])
        bp += 2
        u(bp^^)
        bp++
        u(bp[0])
        bp -= i
        u(bp^^)
        ^^uword wp = &words
        u(wp^^)
        u(wp[i])
        wp += i
        u(wp^^)
        wp++
        u(wp^^)
        wp--
        wp--
        u(wp[0])
        ^^word sp = &swords
        s(sp[2])
        sp += 1
        s(sp^^)
        ; through a pointer to a plain variable, and writing through it
        ^^uword pp = &plain
        pp^^ += 1
        u(plain)
        pp^^ = pp^^ * 2
        u(pp^^)
        ; pointers compared and subtracted
        ^^ubyte first = &bytes
        ^^ubyte last = &bytes[4]
        t(first < last)
        t(first == &bytes[0])
        t(last != first)
        u((last - first) as uword)
    }

    sub nodes(ubyte base) {
        ^^Node a = &heap as ^^Node
        ^^Node b = a + 1
        ^^Node c = b + 1
        a.id = base
        a.value = -1000
        a.next = b
        a.live = true
        b.id = base + 1
        b.value = 2000
        b.next = c
        b.live = false
        c.id = base + 2
        c.value = -3
        c.next = 0
        c.live = true
        u(a.id)
        s(a.value)
        u(a.next.id)
        s(a.next.value)
        u(a.next.next.id)
        s(a.next.next.value)
        t(a.live)
        t(a.next.live)
        t(a.next.next.next == 0)
        ; walking the list
        word total = 0
        ubyte count = 0
        ^^Node n = a
        while n != 0 {
            total += n.value
            count++
            n = n.next
        }
        s(total)
        u(count)
        ; fields updated through the pointer, and through a pointer in an array
        b.value += 500
        b.id <<= 1
        s(b.value)
        u(b.id)
        table[0] = a
        table[1] = c
        table[2] = b
        u(table[1].id)
        s(table[2].value)
        table[0].value = 77
        s(a.value)
        ; the address of a field is a pointer to its type
        ^^word vp = &b.value
        vp^^ = -9
        s(b.value)
        ^^ubyte ip = &c.id
        ip^^ += 100
        u(c.id)
        u(sizeof(Node) * 0 + (c as uword) - (a as uword) - 2 * sizeof(Node))
    }

    sub start() {
        scalars(1)
        line()
        nodes(5)
        txt.nl()
    }
}
