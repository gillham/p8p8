; The Color Computer 3's memory beyond its 64 KB as data (the coco3 target's highram
; module): how much there is, bytes put there and got back at both ends and across
; the border of two blocks, one byte, a fill, moves that overlap and cross blocks in
; both directions, every block holding its own bytes, and the ROM's floats and the
; clock working after it.
%import textio
%import floats
%import highram

main {
    ubyte[300] buffer
    ubyte[300] back

    sub differ() -> uword {
        uword k
        uword wrong = 0
        for k in 0 to 299 {
            if back[k] != buffer[k]
                wrong++
        }
        sys.memset(back, 300, 0)
        return wrong
    }

    sub start() {
        uword k
        long size = highram.size()
        txt.print_bool(highram.present())
        txt.spc()
        txt.print_l(size)
        txt.nl()
        for k in 0 to 299
            buffer[k] = lsb(k * 5 + 3)
        ; at both ends, and across the border of the first two blocks
        highram.put(buffer, highram.START, 300)
        highram.put(buffer, size - 300, 300)
        highram.put(buffer, 8192 - 100, 300)
        highram.get(highram.START, back, 300)
        txt.print_uw(differ())
        highram.get(size - 300, back, 300)
        txt.print_uw(differ())
        highram.get(8192 - 100, back, 300)
        txt.print_uw(differ())
        txt.spc()
        highram.setbyte(20000, 123)
        txt.print_ub(highram.getbyte(20000))
        txt.spc()
        txt.print_ub(highram.getbyte(1))
        txt.spc()
        ; a fill across three blocks
        highram.setbyte(7999, 1)
        highram.setbyte(17000, 2)
        highram.fill(8000, 9000, 77)
        txt.print_ub(highram.getbyte(7999))
        txt.spc()
        txt.print_ub(highram.getbyte(8000))
        txt.print_ub(highram.getbyte(16999))
        txt.spc()
        txt.print_ub(highram.getbyte(17000))
        txt.nl()
        ; moves: up over itself, across a border; down over itself; a long way
        highram.put(buffer, 8100, 300)
        highram.move(8100, 8110, 300)
        highram.get(8110, back, 300)
        txt.print_uw(differ())
        highram.move(8110, 8103, 300)
        highram.get(8103, back, 300)
        txt.print_uw(differ())
        highram.move(8103, size - 9000, 300)
        highram.get(size - 9000, back, 300)
        txt.print_uw(differ())
        ; 20000 bytes moved up by 5000 and back
        highram.fill(0, 30000, 0)
        for k in 0 to 66
            highram.put(buffer, k * 300 as long, 300)
        highram.move(0, 5000, 20100)
        uword wrong = 0
        for k in 0 to 66 {
            highram.get(5000 + k * 300 as long, back, 300)
            wrong += differ()
        }
        highram.move(5000, 1, 20100)
        for k in 0 to 66 {
            highram.get(1 + k * 300 as long, back, 300)
            wrong += differ()
        }
        txt.print_uw(wrong)
        txt.nl()
        ; every block holds its own bytes: its number at its start, read back afterwards
        ubyte blocks = lsb(size >> 13)
        ubyte b
        for b in 0 to blocks - 1
            highram.setbyte((b as long) << 13, b ^ $5a)
        wrong = 0
        for b in 0 to blocks - 1 {
            if highram.getbyte((b as long) << 13) != b ^ $5a
                wrong++
        }
        txt.print_ub(blocks)
        txt.spc()
        txt.print_uw(wrong)
        txt.nl()
        ; BASIC's memory is back: a float through the ROM, and its clock runs
        txt.print_f(sqrt(2.0) * 2.0)
        txt.spc()
        uword before = sys.ticks()
        sys.wait(3)
        txt.print_bool(sys.ticks() != before)
        txt.nl()
    }
}
