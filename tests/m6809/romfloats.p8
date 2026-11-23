; Floats on a 6809 machine whose BASIC has them (the Color Computers): arithmetic, the
; conversions from and to whole numbers, the compares, the functions, a number read
; from a text.  The host prints the same numbers with more digits.
%import textio
%import floats
main {
    float @shared a = 3.5
    float @shared b = -1.25
    float[3] values = [1.5, 2.25, 100.0]
    sub show(float value) {
        txt.print_f(value)
        txt.spc()
    }
    sub start() {
        ubyte k
        uword @shared w = 40000
        long @shared big = -123456
        show(a + b)
        show(a - b)
        show(a * b)
        show(a / b)
        show(-a)
        txt.nl()
        for k in 0 to 2
            show(values[k] * 2.0)
        show(w as float)
        show(big as float)
        show(200 as float)
        txt.nl()
        txt.print_w((a * 100.0) as word)
        txt.spc()
        txt.print_w((b * 100.0) as word)
        txt.spc()
        txt.print_ub(a as ubyte)
        txt.spc()
        txt.print_l((big as float * 2.0) as long)
        txt.spc()
        txt.print_bool(a > b)
        txt.print_bool(a < b)
        txt.print_bool(a == 3.5)
        txt.nl()
        show(sqrt(16.0))
        show(floats.sin(1.0))
        show(floats.cos(1.0))
        show(floats.floor(-2.5))
        show(floats.ceil(-2.5))
        show(floats.round(2.6))
        txt.nl()
        show(floats.pow(2.0, 10.0))
        show(floats.ln(10.0))
        show(floats.log2(8.0))
        show(floats.atan(1.0))
        show(floats.parse("12.5e2"))
        show(abs(b))
        txt.nl()
    }
}
