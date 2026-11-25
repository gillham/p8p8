; The Apple II's text screen: the routines of textio that write and read its memory,
; and the cursor.  What is on the screen is read back and printed, so the output says
; whether each one did what it should.
%import textio
%import strings
%zeropage basicsafe

main {
    sub show(ubyte v) {
        txt.print_ub(v)
        txt.spc()
    }

    sub start() {
        ; the rows are not in order in memory
        txt.print_uwhex(txt.rowaddress(0), true)
        txt.spc()
        txt.print_uwhex(txt.rowaddress(1), true)
        txt.spc()
        txt.print_uwhex(txt.rowaddress(8), true)
        txt.spc()
        txt.print_uwhex(txt.rowaddress(23), true)
        txt.nl()

        ; a character put on the screen is there with its high bit set, and is read back
        txt.setchr(5, 3, 'A')
        txt.setchr(39, 23, 'z')
        txt.setchr(0, 0, '#')
        show(txt.getchr(5, 3))
        show(txt.getchr(39, 23))
        show(txt.getchr(0, 0))
        show(@($0585))
        show(@($07f7))
        show(@($0400))
        txt.nl()

        ; the cursor: where it is put is where the next character goes
        ubyte col
        ubyte row
        col, row = txt.get_cursor()
        ubyte keptrow = row
        txt.plot(10, 12)
        col, row = txt.get_cursor()
        txt.setchr(10, 12, ' ')
        txt.chrout('Q')
        ubyte seen = txt.getchr(10, 12)
        ubyte after = txt.get_column()
        txt.column(20)
        ubyte moved = txt.get_column()
        txt.row(14)
        ubyte moved_row = txt.get_row()
        txt.plot(0, keptrow)
        show(col)
        show(row)
        show(seen)
        show(after)
        show(moved)
        show(moved_row)
        txt.nl()

        ; inverse text is the character without its two high bits
        txt.plot(30, 20)
        txt.rvs_on()
        txt.chrout('R')
        txt.rvs_off()
        txt.chrout('N')
        txt.plot(0, keptrow + 1)
        show(@(txt.rowaddress(20) + 30))
        show(@(txt.rowaddress(20) + 31))
        txt.nl()

        ; scrolling by hand: every row moves, the row that is left is as it was
        txt.setchr(7, 10, 'u')
        txt.setchr(7, 11, 'v')
        txt.scroll_up(false)
        show(txt.getchr(7, 9))
        show(txt.getchr(7, 10))
        txt.scroll_down(false)
        txt.scroll_down(false)
        show(txt.getchr(7, 11))
        show(txt.getchr(7, 12))
        txt.scroll_left(false)
        show(txt.getchr(6, 11))
        txt.scroll_right(false)
        txt.scroll_right(false)
        show(txt.getchr(8, 11))
        txt.nl()

        ; the whole screen filled
        txt.clear_screenchars('*')
        ubyte stars = 0
        for row in 0 to 23 {
            if txt.getchr(0, row) == '*' and txt.getchr(39, row) == '*'
                stars++
        }
        show(stars)
        show(@($0400))
        txt.clear_screen()
        show(txt.getchr(20, 10))
        col, row = txt.get_cursor()
        show(col)
        show(row)
        show(txt.width())
        show(txt.height())
        txt.nl()

        ; the virtual registers started as 0 and are outside the zero page
        ; (the keyboard is not read here: bobbin stops when its input has ended)
        txt.print_uwhex(&cx16.r0, true)
        txt.spc()
        txt.print_uw(cx16.r5)
        txt.spc()
        show(sys.target)
        txt.nl()
    }
}
