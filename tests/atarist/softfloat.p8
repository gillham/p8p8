; Floats without an FPU (the 68000 machines: m68k_softfloat.asm and floats_soft.p8 of
; the library): the arithmetic, the conversions, the functions over a range of
; numbers, text to float and back.  tests/atarist/softfloat.out is what the Atari ST
; prints (make stcmp); the numbers are right to six or seven digits.
%import textio
%import floats
main {
    sub show(float f) {
        txt.print_f(f)
        txt.spc()
    }
    sub start() {
        float a = 3.5
        float b = -1.25
        show(a + b)
        show(a - b)
        show(a * b)
        show(a / b)
        show(sqrt(2.0))
        txt.nl()
        show(floats.sin(1.0))
        show(floats.cos(1.0))
        show(floats.tan(0.5))
        show(floats.atan(1.0) * 4)
        show(floats.ln(10.0))
        show(floats.log2(1024.0))
        show(floats.pow(2.0, 0.5))
        txt.nl()
        show(floats.floor(-2.5))
        show(floats.ceil(-2.5))
        show(floats.round(2.5))
        show(floats.parse("-123.456e2"))
        show(floats.PI)
        ubyte k = 7
        show(k as float / 2)
        txt.print_w((a * 100.7) as word)
        txt.spc()
        txt.print_bool(a > b)
        txt.print_bool(a < b)
        txt.print_bool(a == 3.5)
        txt.nl()
        float total = 0
        for k in 1 to 100
            total += 1.0 / (k as float)
        show(total)
        show(floats.sin(100.0))
        show(floats.atan2(1.0, -1.0))
        show(floats.pow(10.0, -3.0))
        txt.nl()
        functions()
    }

    sub functions() {
        float x
        ubyte k
        float[] values = [0.001, 0.3, 0.7853, 1.0, 1.5707, 2.0, 3.0, 3.1416, 4.5, 6.0, 10.0, 100.0, 1000.0, -0.5, -2.2, -77.0]
        for k in 0 to len(values) - 1 {
            x = values[k]
            txt.print_f(floats.sin(x))
            txt.spc()
            txt.print_f(floats.cos(x))
            txt.spc()
            txt.print_f(floats.atan(x))
            txt.spc()
            txt.print_f(floats.ln(abs(x)))
            txt.spc()
            txt.print_f(floats.pow(abs(x), 0.37))
            txt.spc()
            txt.print_f(floats.pow(1.01, x))
            txt.spc()
            txt.print_f(sqrt(abs(x)))
            txt.spc()
            txt.print_f(floats.log2(abs(x)))
            txt.nl()
        }
    }
}
