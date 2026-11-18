; clamp of a long, and "in" with longs and floats: a list of values, and an array
; (upstream cannot build the search through a long array for the 6502 machines)
%import textio
%import floats
main {
    sub start() {
        long @shared l = 100000
        long @shared lo = 5
        long @shared hi = 70000
        txt.print_l(clamp(l, lo, hi))
        txt.spc()
        txt.print_l(clamp(l, -5, 90))
        txt.spc()
        float @shared f = 3.5
        floats.print(floats.clampf(f, 1.0, 2.5))
        txt.spc()
        txt.print_bool(l in [5, 100000, 7])
        txt.print_bool(l in [5, 100001, 7])
        txt.spc()
        txt.print_bool(f in [1.0, 3.5])
        txt.print_bool(f in [1.0, 3.25])
        txt.spc()
        long[] @shared la = [5, 100000, -7]
        float[] @shared fa = [1.0, 3.5, 9.25]
        txt.print_bool(l in la)
        txt.print_bool(lo in la)
        l = -7
        txt.print_bool(l in la)
        l = 6
        txt.print_bool(l in la)
        txt.print_bool(f in fa)
        f = 9.25
        txt.print_bool(f in fa)
        f = 9.5
        txt.print_bool(f in fa)
        txt.spc()
        txt.print_l(clamp(l, lo, hi))
        txt.print_l(clamp(l, 10, hi))
        txt.print_l(clamp(l, -9, 2))
        txt.nl()
    }
}
