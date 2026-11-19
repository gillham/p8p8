%import textio
main {
    long @shared a = 1000000
    long @shared b = 7
    long @shared n = -1000000
    long @shared m = -7
    sub start() {
        txt.print_l(a / b)
        txt.spc()
        txt.print_l(n / b)
        txt.spc()
        txt.print_l(a / m)
        txt.spc()
        txt.print_l(n / m)
        txt.spc()
        txt.print_l(a / 1000)
        txt.spc()
        txt.print_l(n / 3)
        txt.nl()
        long c = 2000000000
        c /= 1024
        txt.print_l(c)
        txt.spc()
        c = a
        c /= b
        c *= b
        txt.print_l(a - c)
        txt.spc()
        txt.print_l(b / a)
        txt.spc()
        txt.print_l(a / a)
        txt.spc()
        txt.print_l(n / 1)
        txt.spc()
        txt.print_l(a / -1)
        txt.nl()
    }
}
