%import textio

; far memory at an address the program works out: a long variable or expression in
; @(), in peek and poke, with an index, and the address of a far variable as a long
main {
    &ubyte[16] fararray = $40400
    &uword farword = $40420
    long @shared base = $40400
    long @shared other = $40500

    sub start() {
        ubyte i
        for i in 0 to 15
            @(base + i) = i * 5
        txt.print_ub(fararray[3])
        txt.spc()
        txt.print_ub(@(base + 4))
        txt.spc()
        txt.print_ub(base[5])
        txt.spc()
        ubyte @shared k = 6
        txt.print_ub(base[k])
        txt.spc()
        txt.print_ub(peek(base + 7))
        txt.nl()

        poke(other, 123)
        pokew(other + 2, 45678)
        pokel(other + 4, -123456)
        other[12] = 9
        k = 13
        other[k] = other[12] + 1
        @(other + 1) = @(other) + 1
        txt.print_ub(peek(other))
        txt.spc()
        txt.print_ub(@(other + 1))
        txt.spc()
        txt.print_uw(peekw(other + 2))
        txt.spc()
        txt.print_l(peekl(other + 4))
        txt.spc()
        txt.print_ub(other[13])
        txt.nl()

        ; the address of a far variable is a long
        long @shared where = &fararray
        txt.print_ulhex(where, true)
        txt.spc()
        where = &farword
        pokew(where, 4242)
        txt.print_uw(farword)
        txt.spc()
        where = &fararray[9]
        txt.print_ub(@(where))
        txt.spc()
        long walk = &fararray
        ubyte total = 0
        repeat 16 {
            total += @(walk)
            walk++
        }
        txt.print_ub(total)
        txt.nl()

        ; an address in the first 64 KB is one too
        long @shared nearby = &i
        i = 77
        txt.print_ub(@(nearby))
        txt.nl()
    }
}
