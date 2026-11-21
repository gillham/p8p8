; A measure of the Z80 code's speed: a sieve, a loop of word arithmetic and a loop of
; long arithmetic, each run many times.  make z80bench builds it for CP/M and times it
; in tnylpo; it prints 1899 22290 136168418.

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
    ; (Each run of the word and long loops starts from the result so far and ends at a
    ; number that is read from memory, so that no compiler can work the loops out
    ; while it compiles: CP/M's byte at $0080, the length of the command line, is 0.)
    sub words(uword seed) -> uword {
        uword total = seed
        uword n
        uword lim = 20000
        lim += @($0080)
        for n in 1 to lim {
            total += n * 3
            total ^= n >> 2
            if total & 1 != 0
                total -= 7
        }
        return total
    }
    sub longs(long seed) -> long {
        long total = seed
        long n
        long lim = 4000
        lim += @($0080)
        for n in 1 to lim {
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
        c = 0
        for round in 1 to 250
            c += words(c + round)
        txt.print_uw(c)
        txt.spc()
        long lr = 0
        for round in 1 to 60
            lr += longs(lr + round)
        txt.print_l(lr)
        txt.nl()
    }
}
