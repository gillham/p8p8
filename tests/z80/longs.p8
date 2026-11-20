; Longs and signed division, for the Z80 code generator: arithmetic, logic, shifts and
; compares of longs, signed division and remainder of bytes, words and longs.
; Compared with the host by make z80cmp.

%import textio
main {
    sub show(long v) {
        txt.print_l(v)
        txt.spc()
    }
    sub start() {
        long a = 123456789
        long b = -1000
        long c = a + b
        show(c)
        show(a - b)
        show(a * 3)
        show(b * b)
        show(a / b)
        show(a % 1000)
        show(-a / 7)
        show(-a % 7)
        show(a & $ff00ff)
        show(a | 1)
        show(a ^ -1)
        show(-a)
        show(a << 3)
        show(b >> 2)
        txt.nl()
        if a > b txt.print("gt ")
        if b < a txt.print("lt ")
        if a == a txt.print("eq ")
        if b >= 0 txt.print("WRONG ")
        if b <= -1000 txt.print("le ")
        c = 70000
        while c > 69990 {
            c--
        }
        show(c)
        c++
        show(c)
        txt.nl()
        byte sb = -100
        word sw = -30000
        txt.print_b(sb / 7)
        txt.spc()
        txt.print_b(sb % 7)
        txt.spc()
        txt.print_w(sw / 7)
        txt.spc()
        txt.print_w(sw % 7)
        txt.spc()
        txt.print_w(sw / -7)
        txt.spc()
        sw /= 3
        txt.print_w(sw)
        txt.spc()
        txt.print_b(sgn(sw))
        txt.print_b(sgn(a))
        txt.print_b(sgn(sb - sb))
        txt.nl()
        uword uw = $8001
        rol2(uw)
        txt.print_uwhex(uw, true)
        ror2(uw)
        txt.print_uwhex(uw, true)
        uw >>= 3
        txt.print_uwhex(uw, true)
        txt.nl()
    }
}
