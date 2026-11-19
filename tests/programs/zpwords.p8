%import textio

; words in the zero page counted up and down (inw and dew on the 45GS02)
main {
    uword @zp up = 254
    uword @zp down = 258
    uword @requirezp counter
    uword plain = 1000
    sub start() {
        repeat 4 {
            up++
            down--
            plain--
        }
        txt.print_uw(up)
        txt.spc()
        txt.print_uw(down)
        txt.spc()
        txt.print_uw(plain)
        txt.spc()
        up = 65534
        up++
        up++
        down = 1
        down--
        down--
        txt.print_uw(up)
        txt.spc()
        txt.print_uw(down)
        txt.nl()
        counter = 0
        uword n
        for n in 1 to 60000 {
            counter++
            counter++
            counter--
        }
        txt.print_uw(counter)
        txt.nl()
    }
}
