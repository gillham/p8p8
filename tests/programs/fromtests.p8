%import textio
%zeropage basicsafe

; Constructs from upstream's unit tests that p8p8 did not take: several names
; with a value each, lmh's three results, flags and a sign in an if expression,
; a character in a string, an index from the end, arrays and strings as
; parameters, a loop over a string by its address.
main {
    ubyte @shared l
    ubyte @shared m
    ubyte @shared h
    long @shared big = $123456
    ubyte @shared a = 3
    ubyte @shared b = 9
    ubyte[10] array = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19]

    sub total(ubyte[] values, ubyte count) -> uword {
        uword sum = 0
        ubyte k
        for k in 0 to count - 1
            sum += values[k]
        return sum
    }

    sub count(str s) -> ubyte {
        ubyte n = 0
        ubyte c
        for c in s {
            if c == 'l'
                n++
        }
        return n
    }

    sub values() {
        ubyte @shared x, y, z = 11, 22, 33
        txt.print_ub(x + y + z)
        txt.spc()
        x, y, z = 99, 88, 77
        txt.print_ub(y)
        txt.spc()
        l, m, h = lmh(big)
        txt.print_ubhex(h, false)
        txt.print_ubhex(m, false)
        txt.print_ubhex(l, false)
        txt.spc()
        l, m, h = lmh(-2)
        txt.print_ubhex(h, false)
        txt.print_ubhex(l, false)
        txt.spc()
        @($0400) = -100
        txt.print_ub(@($0400))
        txt.nl()
    }

    sub conditions() {
        byte s = if a < b -1 else 1
        txt.print_b(s)
        s = if b < a -1 else 1
        txt.print_b(s)
        txt.spc()
        ubyte v = if a == 3 then 10 else 20
        txt.print_ub(v)
        v = if a == 4  10 else 20
        txt.print_ub(v)
        txt.spc()
        cmp(a, b)
        v = if_cs 1 else 2
        txt.print_ub(v)
        cmp(b, a)
        v = if_cs then 1 else 2
        txt.print_ub(v)
        cmp(a, a)
        uword w = if_z 1000 else 2000
        txt.print_uw(w)
        txt.nl()
    }

    sub strings() {
        str text = "hello"
        ubyte @shared ch = 'l'
        txt.print_bool(ch in text)
        txt.print_bool('z' in text)
        txt.print_bool('h' in text)
        txt.print_bool('o' in text)
        if ch in "email"
            txt.print("y")
        txt.spc()
        txt.print_ub(count("hello, world"))
        txt.print_ub(count(""))
        txt.nl()
    }

    sub arrays() {
        array[-1] = 99
        array[-10] = 1
        txt.print_ub(array[9])
        txt.print_ub(array[0])
        txt.print_ub(array[-2])
        txt.spc()
        txt.print_uw(total(array, 10))
        txt.spc()
        txt.print_uw(total("AB", 2))
        txt.nl()
    }

    sub start() {
        values()
        conditions()
        strings()
        arrays()
    }
}
