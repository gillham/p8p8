%import textio
%zeropage basicsafe

; a word times itself, signed and unsigned, small and large
main {
    sub start() {
        word[] values = [0, 1, -1, 7, -13, 180, -181, 255, -255, 256, -256, 257, 1000, -1000, 32767, -32768]
        ubyte k
        for k in 0 to len(values) - 1 {
            word v = values[k]
            uword sq = v * v as uword
            txt.print_uw(sq)
            txt.spc()
            uword u = v as uword
            uword usq = u * u
            txt.print_uw(usq)
            txt.nl()
        }
    }
}
