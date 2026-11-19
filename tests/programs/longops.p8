%import textio
main {
    long @shared a = 100000
    long @shared b = 250000
    long @shared c
    sub start() {
        c = a + b
        txt.print_l(c)
        txt.spc()
        c = b - a
        txt.print_l(c)
        txt.spc()
        c = a & $ff00ff
        txt.print_l(c)
        txt.spc()
        c = a | b
        txt.print_l(c)
        txt.spc()
        c = a ^ b
        txt.print_l(c)
        txt.nl()
        c++
        txt.print_l(c)
        txt.spc()
        c--
        c--
        txt.print_l(c)
        txt.spc()
        c = -a
        txt.print_l(c)
        txt.spc()
        c = a << 3
        txt.print_l(c)
        txt.spc()
        c = b >> 2
        txt.print_l(c)
        txt.spc()
        c = -b
        c >>= 1
        txt.print_l(c)
        txt.nl()
        c = a
        c += 12345678
        c -= 5
        c += b
        c -= a
        txt.print_l(c)
        txt.spc()
        c = 0
        repeat 1000
            c += 1001
        txt.print_l(c)
        txt.nl()
    }
}
