; The Atari's text screen: the routines of textio that write and read its memory,
; the cursor, inverse text, the clock.  What is on the screen is read back and
; printed, so the output says whether each one did what it should.
%import textio
%zeropage basicsafe

main {
    sub show(ubyte v) {
        txt.print_ub(v)
        txt.spc()
    }

    sub start() {
        ubyte col
        ubyte row
        ; the whole screen filled, and cleared
        txt.clear_screenchars('*')
        ubyte stars = 0
        for row in 0 to 23 {
            if txt.getchr(0, row) == '*' and txt.getchr(39, row) == '*'
                stars++
        }
        ; scrolling by hand: every row moves, the row that is left is as it was
        ; (before anything is printed, which would move too)
        ubyte[6] scrolled
        txt.setchr(7, 10, 'u')
        txt.setchr(7, 11, 'v')
        txt.scroll_up(false)
        scrolled[0] = txt.getchr(7, 9)
        scrolled[1] = txt.getchr(7, 10)
        txt.scroll_down(false)
        txt.scroll_down(false)
        scrolled[2] = txt.getchr(7, 11)
        scrolled[3] = txt.getchr(7, 12)
        txt.scroll_left(false)
        scrolled[4] = txt.getchr(6, 11)
        txt.scroll_right(false)
        txt.scroll_right(false)
        scrolled[5] = txt.getchr(8, 11)
        txt.clear_screen()
        uword screen = txt.rowaddress(0)
        show(stars)
        show(txt.getchr(20, 10))
        show(txt.width())
        show(txt.height())
        txt.nl()

        ; the rows are 40 bytes apart; the left margin is 0 while a program runs
        txt.print_uw(txt.rowaddress(1) - screen)
        txt.spc()
        txt.print_uw(txt.rowaddress(23) - screen)
        txt.spc()
        show(atari.LMARGN)
        show(txt.get_column())
        txt.nl()

        ; a character put on the screen is there as its screen code, and is read back
        txt.setchr(5, 3, 'A')
        txt.setchr(39, 23, 'z')
        txt.setchr(0, 20, '#')
        txt.setchr(1, 20, 'K' | 128)
        show(txt.getchr(5, 3))
        show(txt.getchr(39, 23))
        show(txt.getchr(0, 20))
        show(txt.getchr(1, 20))
        show(@(screen + 3*40 + 5))
        show(@(screen + 23*40 + 39))
        show(@(screen + 20*40))
        show(@(screen + 20*40 + 1))
        txt.setchr(0, 24, 'X')
        show(txt.getchr(0, 24))
        txt.nl()

        ; the cursor: where it is put is where the next character goes
        txt.plot(10, 12)
        col, row = txt.get_cursor()
        txt.chrout('Q')
        ubyte seen = txt.getchr(10, 12)
        ubyte after = txt.get_column()
        txt.column(20)
        ubyte moved = txt.get_column()
        txt.row(14)
        ubyte moved_row = txt.get_row()
        txt.plot(0, 3)
        show(col)
        show(row)
        show(seen)
        show(after)
        show(moved)
        show(moved_row)
        txt.nl()

        ; inverse text is the character with its high bit set
        txt.plot(30, 18)
        txt.rvs_on()
        txt.print("Rr7")
        txt.rvs_off()
        txt.print("Nn")
        txt.plot(0, 4)
        show(@(screen + 18*40 + 30))
        show(@(screen + 18*40 + 31))
        show(@(screen + 18*40 + 32))
        show(@(screen + 18*40 + 33))
        show(@(screen + 18*40 + 34))
        txt.nl()

        ; what scrolling by hand gave (done first, see above)
        txt.plot(0, 5)
        for col in 0 to 5
            show(scrolled[col])
        txt.nl()

        ; the clock counts; no key is waiting and BREAK was not pressed; the virtual
        ; registers started as 0 and are in page 6
        ubyte t0 = cbm.TIME_LO
        sys.wait(3)
        ubyte passed = cbm.TIME_LO - t0
        txt.print_bool(passed >= 3 and passed <= 5)
        txt.spc()
        show(cbm.GETIN2())
        txt.print_bool(cbm.STOP2())
        txt.spc()
        txt.print_uwhex(&cx16.r0, true)
        txt.spc()
        txt.print_uw(cx16.r5)
        txt.spc()
        show(sys.target)
        txt.nl()
    }
}
