; The signed remainder of bytes and words: the sign is the first operand's.
%import textio
%zeropage basicsafe
main {
    word[] ws = [-32767, -30000, -17, -5, -1, 0, 1, 5, 17, 300, 32767]
    byte[] bs = [-127, -100, -17, -5, -1, 0, 1, 5, 17, 100, 127]
    sub start() {
        ubyte i, j
        for i in 0 to 10 {
            for j in 0 to 10 {
                if ws[j] != 0 {
                    txt.print_w(ws[i] % ws[j])
                    txt.spc()
                }
                if bs[j] != 0 {
                    txt.print_b(bs[i] % bs[j])
                    txt.spc()
                }
            }
            txt.print_w(ws[i] % 7)
            txt.spc()
            txt.print_w(ws[i] % -300)
            txt.spc()
            txt.print_b(bs[i] % 7)
            txt.spc()
            txt.print_b(bs[i] % -9)
            txt.nl()
        }
    }
}
