; Conformance: the builtin functions on every type they take, with values the compiler
; cannot know.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.
; (At most 24 lines of 40 characters: the C64 comparison is of one screen.)

%import textio
%zeropage basicsafe

main {
    ubyte col

    sub item(ubyte width) {
        col += width
        if col >= 36 {
            txt.nl()
            col = 0
        }
        else
            txt.spc()
    }

    sub u(uword v) {
        txt.print_uw(v)
        item(6)
    }

    sub s(word v) {
        txt.print_w(v)
        item(7)
    }

    ; a truth value as one letter, six to a group
    sub t(bool v) {
        if v
            txt.chrout('y')
        else
            txt.chrout('n')
        col++
        if col % 6 == 0
            item(1)
    }

    sub line() {
        if col != 0
            txt.nl()
        col = 0
    }


    sub parts(uword w, long l) {
        u(lsb(w))
        u(msb(w))
        u(lsb(l))
        u(msb(l))
        u(lsw(l))
        u(msw(l))
        u(mkword(lsb(w), msb(w)))
        txt.print_l(mklong2(lsw(l), msw(l)))
        item(12)
        txt.print_l(mklong(1, 2, 3, 4))
        item(12)
    }

    sub signs(byte b, word w, long l) {
        u(abs(b))
        u(abs(w))
        txt.print_l(abs(l))
        item(12)
        s(sgn(b))
        s(sgn(w))
        s(sgn(l))
        s(sgn(b + 100))
        s(sgn(w - w))
    }

    sub limits(ubyte a, ubyte b, word x, word y) {
        u(min(a, b))
        u(max(a, b))
        s(min(x, y))
        s(max(x, y))
        u(clamp(a, 10, 20))
        u(clamp(b, 10, 20))
        s(clamp(x, -5, 5))
        s(clamp(y, -5, 5))
    }

    sub roots(ubyte a, uword w) {
        u(sqrt(a))
        u(sqrt(w))
        ubyte q
        ubyte r
        q, r = divmod(a, 7)
        u(q)
        u(r)
        uword wq
        uword wr
        wq, wr = divmod(w, 1000)
        u(wq)
        u(wr)
    }

    sub rotating(ubyte a, uword w) {
        ubyte x = a
        sys.clear_carry()
        rol(x)
        u(x)
        sys.set_carry()
        rol(x)
        u(x)
        sys.clear_carry()
        ror(x)
        u(x)
        x = a
        rol2(x)
        u(x)
        ror2(x)
        ror2(x)
        u(x)
        uword y = w
        sys.set_carry()
        ror(y)
        u(y)
        rol2(y)
        rol2(y)
        u(y)
        ror2(y)
        u(y)
    }

    ubyte[16] area

    sub peeking(uword w) {
        ^^ubyte buffer = &area
        pokew(buffer, w)
        u(peek(buffer))
        u(peek(buffer + 1))
        u(peekw(buffer))
        poke(buffer + 2, lsb(w) + 1)
        u(@(buffer + 2))
        @(buffer + 3) = 7
        u(peekw(buffer + 2))
        pokel(buffer + 4, 123456789)
        txt.print_l(peekl(buffer + 4))
        item(12)
        pokebool(buffer + 8, true)
        t(peekbool(buffer + 8))
        u(peek(buffer + 8))
    }

    sub swapping(ubyte a, ubyte b, uword x, uword y) {
        swap(a, b)
        u(a)
        u(b)
        swap(x, y)
        u(x)
        u(y)
        u(sizeof(ubyte))
        u(sizeof(word))
        u(sizeof(long))
        u(sizeof(bool))
    }

    sub start() {
        parts($a1b2, $12345678)
        line()
        signs(-100, -30000, -100000)
        signs(100, 30000, 100000)
        signs(0, 0, 0)
        line()
        limits(5, 200, -100, 3)
        limits(15, 12, 2, 100)
        line()
        roots(200, 50000)
        roots(9, 999)
        line()
        rotating($81, $8001)
        line()
        peeking($34a5)
        line()
        swapping(1, 2, 1000, 2000)
        txt.nl()
    }
}
