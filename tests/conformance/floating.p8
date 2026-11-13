; Conformance: floating point: arithmetic, comparisons, conversions to and from the integer
; types, arrays, parameters and results, and the library's functions.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.
; (At most 24 lines of 40 characters: the C64 comparison is of one screen.)

%import textio
%import floats
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


    float[] table = [1.5, -2.25, 100.0]
    float kept = 0.5

    sub f(float value) {
        floats.print(value)
        item(10)
    }

    sub arithmetic(float a, float b) {
        f(a + b)
        f(a - b)
        f(a * b)
        f(a / b)
        f(-a)
        f(a * 2 + b / 4 - 1)
        float c = a
        c += b
        c *= 2
        c -= 0.5
        c /= 4
        f(c)
        kept += a
        f(kept)
    }

    sub comparing(float a, float b) {
        t(a < b)
        t(a <= b)
        t(a > b)
        t(a >= b)
        t(a == b)
        t(a != b)
        t(a == 0)
        t(b > 0)
        if a < b
            u(1)
        else
            u(2)
        f(if a > b a else b)
    }

    sub converting(ubyte ub, byte sb, uword uw, word sw, float x) {
        float c = ub as float
        f(c)
        c = sb as float
        f(c)
        c = uw as float
        f(c)
        c = sw as float
        f(c)
        f(ub as float / 4)
        u(x as ubyte)
        u(x as uword)
        s(-x as word)
        s(-x as byte)
        u((x * 10) as uword)
        u((x * 400) as uword)
        u((x + 100) as ubyte)
        f(ub)
        f(sw)
    }

    sub functions(float x) {
        f(floats.floor(x))
        f(floats.ceil(x))
        f(floats.round(x))
        f(floats.floor(-x))
        f(abs(-x))
        f(sqrt(x * x))
        f(floats.pow(2.0, 10.0))
        f(floats.minf(x, 2.0))
        f(floats.maxf(x, 2.0))
        f(floats.clampf(x, 0.0, 1.0))
        f(floats.parse("12.25"))
        f(floats.parse("-0.5"))
    }

    sub arrays(ubyte i) {
        f(table[0])
        f(table[i])
        f(table[i + 1])
        table[i] = table[0] * 3
        table[0] += 1
        f(table[i])
        f(table[0])
        float sum = 0
        ubyte k
        for k in 0 to len(table) - 1
            sum += table[k]
        f(sum)
        u(len(table))
        u(sizeof(float) * 0 + 3)
    }

    sub halve(float value) -> float {
        return value / 2
    }

    sub start() {
        arithmetic(7.5, 2.5)
        line()
        arithmetic(-1.25, 0.5)
        line()
        comparing(1.5, 2.5)
        line()
        comparing(-3.0, -3.0)
        line()
        converting(200, -100, 50000, -30000, 123.75)
        line()
        functions(3.25)
        line()
        arrays(1)
        f(halve(halve(10.0)))
        txt.nl()
    }
}
