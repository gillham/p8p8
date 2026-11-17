%import textio

; Kernels for timing the 68000 code: each prints a checksum.

main {
    ubyte[256] flags
    uword[64] table
    long[16] wide

    sub sieve() -> uword {
        uword count = 0
        ubyte round
        for round in 0 to 59 {
            uword i
            for i in 0 to 255
                flags[i as ubyte] = 1
            count = 0
            for i in 2 to 255 {
                if flags[i as ubyte] != 0 {
                    count++
                    uword k = i * 2
                    while k < 256 {
                        flags[k as ubyte] = 0
                        k += i
                    }
                }
            }
        }
        return count
    }

    sub words() -> uword {
        uword sum = 0
        uword i
        for i in 0 to 29999 {
            sum += i ^ (i >> 3)
            sum = (sum << 1) | (sum >> 15)
        }
        return sum
    }

    sub arrays() -> uword {
        uword sum = 0
        ubyte round
        ubyte i
        for round in 0 to 199 {
            for i in 0 to 63
                table[i] = (i as uword) * 37 + round
            for i in 0 to 62
                sum += table[i] ^ table[i + 1]
        }
        return sum
    }

    sub longs() -> long {
        long acc = 1
        uword i
        for i in 1 to 3000 {
            acc = acc * 31 + i
            wide[lsb(i) & 15] = acc / 7
            acc += wide[(lsb(i) + 3) & 15] % 1000
        }
        return acc
    }


    struct Shape {
        uword count
        long[8] values
        ubyte[8] marks
    }
    ubyte[64] storage

    sub structs() -> long {
        ^^Shape s = &storage
        ^^uword w = &table
        long sum = 0
        uword round
        ubyte i
        for round in 0 to 399 {
            for i in 0 to 7 {
                s.values[i] = round + i
                s.marks[i] = i
                w[i] = round
            }
            for i in 0 to 7
                sum += s.values[i] + s.marks[7 - i] + w[i]
            s.count++
        }
        return sum + s.count
    }

    sub fib(ubyte n) -> uword {
        if n < 2
            return n
        return fib(n - 1) + fib(n - 2)
    }

    sub start() {
        txt.print_uw(arrays())
        txt.nl()
    }
}
