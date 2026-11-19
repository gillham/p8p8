%import textio
main {
    sub start() {
        const long maxxx = 65536
        uword amount = 0
        repeat maxxx {
            amount++
        }
        txt.print_uw(amount)
        txt.spc()
        long n = 0
        repeat 70000 {
            n++
        }
        txt.print_l(n)
        txt.spc()
        n = 0
        repeat 300 {
            n++
        }
        txt.print_l(n)
        txt.nl()
    }
}
