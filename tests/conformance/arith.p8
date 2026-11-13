; Conformance: integer arithmetic and conversions, for every integer type, with values
; that come from variables (so that nothing is folded away) and at the edges of each type.
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

    sub l(long v) {
        txt.print_l(v)
        item(12)
    }

    ; (the values come in as parameters: a variable that is never written would be
    ; a constant to upstream, and the arithmetic would be done by the compiler)
    sub bytes(ubyte a, ubyte b, ubyte c, byte m, byte n, byte k) {
        u(a + b)            ; wraps in a byte
        u(a - b - b - c)    ; below zero
        u(a * c)
        u(a / c)
        u(a % c)
        u(c - a)
        u(a << 1)
        u(a >> 3)
        u(a & b)
        u(a | c)
        u(a ^ b)
        u(~a)
        s(m + n)
        s(m - n)            ; wraps
        s(m * 2)            ; wraps
        s(m / k)
        s(m / 7)
        s(n / k)
        s(-m)
        s(m >> 2)           ; keeps the sign
        s(k << 2)
        u(abs(m))
    }

    sub words(uword a, uword b, uword c, word m, word n, word k) {
        u(a + b)
        u(b - a)
        u(c * c)
        u(a / c)
        u(a % c)
        u(a << 3)
        u(a >> 5)
        u(a & $0ff0)
        u(b | $8001)
        u(a ^ b)
        u(~a)
        s(m + n)
        s(m - n)
        s(k * 5)
        s(m / k)
        s(n / k)
        s(m / 7)
        s(-m)
        s(m >> 4)
        s(k << 4)
        u(abs(k))
    }

    sub longs(long a, long b, long c) {
        l(a + b)
        l(b - a)
        l(a * c)
        l(a / c)
        l(b / c)
        l(a << 4)
        l(b >> 3)
        l(a & $ffff)
        l(-b)
    }

    sub conversions(ubyte ub, byte sb, uword uw, word sw, long lg) {
        ; a narrower value in a wider one
        u(ub as uword)
        s(sb as word)
        u(sb as ubyte)
        u(sb as uword)
        l(sb as long)
        l(uw as long)
        l(sw as long)
        ; a wider value cut down
        u(uw as ubyte)
        s(uw as word)
        u(lg as uword)
        u(lg as ubyte)
        s(sw as byte)
        ; bytes that are multiplied into a word
        uword product = ub * 3
        u(product)
        product = (ub as uword) * 3
        u(product)
        uword mixed = uw + ub
        u(mixed)
        word smixed = sw + sb
        s(smixed)
        smixed = sw * sb
        s(smixed)
    }

    sub start() {
        bytes(200, 100, 7, -100, 50, -7)
        words(50000, 20000, 300, -20000, 15000, -300)
        longs(100000, -70000, 1000)
        conversions(200, -3, 40000, -2, 70000)
        txt.nl()
    }
}
