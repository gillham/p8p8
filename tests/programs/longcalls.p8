%import textio
main {
    long @shared a = 123456
    long @shared b = 7890
    long @shared n = -321
    sub start() {
        long c = a * b
        txt.print_l(c)
        txt.spc()
        c = a * n
        txt.print_l(c)
        txt.spc()
        c = n * n
        txt.print_l(c)
        txt.spc()
        c = a * 1000
        txt.print_l(c)
        txt.spc()
        c = b
        c *= b
        txt.print_l(c)
        txt.nl()
        txt.print_l(twice(a))
        txt.spc()
        txt.print_l(twice(twice(n)) + 1)
        txt.spc()
        c = sum3(a, b, n)
        txt.print_l(c)
        txt.spc()
        txt.print_l(fact(10))
        txt.nl()
    }
    sub twice(long v) -> long {
        return v + v
    }
    sub sum3(long x, long y, long z) -> long {
        long s = x + y
        return s + z
    }
    sub fact(long k) -> long {
        long f = 1
        long j
        for j in 2 to k
            f *= j
        return f
    }
}
