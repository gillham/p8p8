; The upper 32 KB of a 64 KB Color Computer or Dragon 64 as data (the highram module):
; bytes put there and got back, at both ends; one byte; a fill; a move that overlaps;
; and the ROM's keys and floats working after it.  With 32 KB there is none.
%import textio
%import floats
%import highram

main {
    ubyte[300] buffer
    ubyte[300] back

    sub start() {
        uword k
        uword wrong = 0
        if not highram.present() {
            txt.print("no upper memory\n")
            return
        }
        txt.print("upper memory\n")
        for k in 0 to 299
            buffer[k] = lsb(k * 5 + 3)
        highram.put(buffer, highram.START, 300)
        highram.put(buffer, highram.START + highram.SIZE - 300, 300)
        highram.get(highram.START, back, 300)
        for k in 0 to 299 {
            if back[k] != buffer[k]
                wrong++
        }
        sys.memset(back, 300, 0)
        highram.get(highram.START + highram.SIZE - 300, back, 300)
        for k in 0 to 299 {
            if back[k] != buffer[k]
                wrong++
        }
        txt.print_uw(wrong)
        txt.spc()
        highram.setbyte($c000, 123)
        txt.print_ub(highram.getbyte($c000))
        txt.spc()
        txt.print_ub(highram.getbyte(highram.START + 1))
        txt.spc()
        highram.fill($9000, 1000, 77)
        txt.print_ub(highram.getbyte($9000))
        txt.print_ub(highram.getbyte($93e7))
        txt.spc()
        ; the 300 bytes at the start, moved 10 bytes up over themselves, and back down
        highram.move(highram.START, highram.START + 10, 300)
        highram.get(highram.START + 10, back, 300)
        wrong = 0
        for k in 0 to 299 {
            if back[k] != buffer[k]
                wrong++
        }
        highram.move(highram.START + 10, highram.START + 3, 300)
        highram.get(highram.START + 3, back, 300)
        for k in 0 to 299 {
            if back[k] != buffer[k]
                wrong++
        }
        txt.print_uw(wrong)
        txt.nl()
        ; the ROM is back: a float through it
        txt.print_f(sqrt(2.0) * 2.0)
        txt.nl()
    }
}
