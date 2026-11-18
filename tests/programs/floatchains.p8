%import textio
%import floats
%zeropage basicsafe

; float expressions of every shape: operands that are variables, constants and
; results; the four operations; results that are stored, used again, compared
main {
    float a = 3.5
    float b = -1.25
    float c = 10.0
    float d

    sub show(float v) {
        floats.print(v)
        txt.spc()
    }

    sub twice(float v) -> float {
        return v * 2.0
    }

    sub start() {
        d = a * b * 2.0 + c
        show(d)
        d = a - b + c
        show(d)
        d = a - b * c
        show(d)
        d = (a - b) / (c - a)
        show(d)
        d = c / a / 2.0
        show(d)
        d = 2.0 / a
        show(d)
        d = a * a
        show(d)
        d = d * d - d
        show(d)
        d = a + b
        d = d + d
        show(d)
        txt.nl()
        float e = a * b
        float f = e + e * e
        show(e)
        show(f)
        d = twice(a + b) - twice(c)
        show(d)
        d = a
        d -= b
        d *= c
        d /= 4.0
        d += 0.5
        show(d)
        if a + b < c - 1.0
            txt.print("lt ")
        if a * 2.0 == 7.0
            txt.print("eq ")
        float x = 0.0
        float y = 0.0
        ubyte iter = 0
        while iter < 12 and x * x + y * y < 4.0 {
            float t = x * x - y * y + 0.3
            y = x * y * 2.0 + 0.5
            x = t
            iter++
        }
        txt.print_ub(iter)
        txt.spc()
        show(x)
        show(y)
        txt.nl()
    }
}
