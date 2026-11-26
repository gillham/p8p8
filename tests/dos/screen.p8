; The text screen's routines on MS-DOS.  The test's output is redirected, so what is
; printed "to the screen" here is printed with the screen switched on by hand, and
; then read back from the screen's cells.
%import textio

main {
    asmsub to_screen(bool on @AL) {
        %asm {{
            mov  [p8dos_screen], al
            ret
        }}
    }

    sub show_row(ubyte row, ubyte count) {
        ubyte col
        for col in 0 to count - 1
            txt.chrout(txt.getchr(col, row))
        txt.nl()
    }

    sub start() {
        ubyte col, row
        txt.print_ub(txt.width())
        txt.chrout('x')
        txt.print_ub(txt.height())
        txt.nl()

        txt.clear_screen()
        col, row = txt.get_cursor()
        txt.print_ub(col)
        txt.spc()
        txt.print_ub(row)
        txt.nl()

        to_screen(true)
        txt.print("first line\nsecond ")
        txt.color(txt.YELLOW)
        txt.print("yellow")
        txt.color2(txt.WHITE, txt.BLUE)
        txt.print(" blue\n")
        txt.color2(txt.LIGHT_GRAY, txt.BLACK)
        txt.rvs_on()
        txt.print("rev")
        txt.rvs_off()
        txt.print("erse")
        col, row = txt.get_cursor()
        txt.plot(10, 5)
        txt.print("at 10,5")
        txt.column(30)
        txt.chrout('!')
        to_screen(false)

        txt.print_ub(col)
        txt.spc()
        txt.print_ub(row)
        txt.nl()
        show_row(0, 12)
        show_row(1, 20)
        show_row(2, 9)
        show_row(5, 32)
        txt.print_ubhex(txt.getclr(0, 1), true)
        txt.spc()
        txt.print_ubhex(txt.getclr(7, 1), true)
        txt.spc()
        txt.print_ubhex(txt.getclr(14, 1), true)
        txt.spc()
        txt.print_ubhex(txt.getclr(0, 2), true)
        txt.spc()
        txt.print_ubhex(txt.getclr(3, 2), true)
        txt.nl()
        txt.print_ub(txt.get_column())
        txt.spc()
        txt.print_ub(txt.get_row())
        txt.nl()

        txt.setchr(3, 8, 'A')
        txt.setcc(4, 8, 'B', $1e)
        txt.setclr(3, 8, $4f)
        txt.chrout(txt.getchr(3, 8))
        txt.chrout(txt.getchr(4, 8))
        txt.spc()
        txt.print_ubhex(txt.getclr(3, 8), true)
        txt.spc()
        txt.print_ubhex(txt.getclr(4, 8), true)
        txt.nl()

        txt.scroll_up()
        show_row(0, 20)
        show_row(4, 18)
        txt.scroll_down()
        show_row(1, 20)

        txt.fill_screen('#', $2f)
        txt.chrout(txt.getchr(0, 0))
        txt.chrout(txt.getchr(txt.width() - 1, txt.height() - 1))
        txt.spc()
        txt.print_ubhex(txt.getclr(40, 12), true)
        txt.nl()
        txt.clear_screenchars('.')
        txt.chrout(txt.getchr(79, 24))
        txt.spc()
        txt.print_ubhex(txt.getclr(79, 24), true)
        txt.nl()
        txt.clear_screen()
        txt.print_ub(txt.getchr(5, 5))
        txt.spc()
        txt.print_ubhex(txt.getclr(5, 5), true)
        txt.nl()
    }
}
