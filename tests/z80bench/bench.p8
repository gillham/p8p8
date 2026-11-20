; A measure of the Z80 code's speed: a sieve, a loop of word arithmetic and a loop of
; long arithmetic, each run many times.  make z80bench builds it for CP/M and times it
; in tnylpo; it prints 1899 53576 -136168480.

%import textio
main {
    const uword SIZE = 8190
    ubyte[SIZE] flags
    sub sieve() -> uword {
        uword count = 0
        uword i
        uword k
        uword prime
        sys.memset(flags, SIZE, 1)
        for i in 0 to SIZE - 1 {
            if flags[i] != 0 {
                prime = i + i + 3
                k = i + prime
                while k < SIZE {
                    flags[k] = 0
                    k += prime
                }
                count++
            }
        }
        return count
    }
    sub words() -> uword {
        uword total = 0
        uword n
        for n in 1 to 20000 {
            total += n * 3
            total ^= n >> 2
            if total & 1 != 0
                total -= 7
        }
        return total
    }
    sub longs() -> long {
        long total = 0
        long n
        for n in 1 to 4000 {
            total += n * n
            total -= n / 3
        }
        return total
    }
    sub start() {
        ubyte round
        uword c
        for round in 1 to 250
            c = sieve()
        txt.print_uw(c)
        txt.spc()
        for round in 1 to 250
            c = words()
        txt.print_uw(c)
        txt.spc()
        long lr
        for round in 1 to 60
            lr = longs()
        txt.print_l(lr)
        txt.nl()
    }
}
