%import textio
%zeropage basicsafe

; an in-place operation on the byte or word at a computed address works the
; address out once
main {
    ubyte[16] cells
    uword calls

    sub addr(ubyte n) -> uword {
        calls++
        return &cells + n
    }

    sub start() {
        ubyte k
        for k in 0 to 15
            cells[k] = k
        @(addr(3)) |= 64
        @(addr(4)) += 10
        @(addr(5)) &= 4
        @(addr(6)) ^= 255
        @(addr(7)) -= 2
        @(addr(8)) <<= 2
        @(addr(9))++
        @(addr(10))--
        @(addr(11)) = @(addr(12)) + 1
        for k in 0 to 15 {
            txt.print_ub(cells[k])
            txt.spc()
        }
        txt.nl()
        txt.print_uw(calls)
        txt.nl()
    }
}
