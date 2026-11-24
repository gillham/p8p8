; For tests/mapcheck.sh: a program whose map (-map) has something of every kind:
; two blocks, a subroutine inside another, variables with and without a value,
; an array, a string, and the library.

%import textio

main {
    ubyte[100] table
    uword counter = 5
    ubyte[] primes = [2, 3, 5, 7, 11, 13]

    sub start() {
        helper.show(counter)
        table[3] = primes[2]
        txt.print("sizes")
        txt.nl()
        helper.show(inner(table[3]))

        sub inner(ubyte value) -> uword {
            return value * $0101
        }
    }
}

helper {
    ubyte calls
    uword[20] history

    sub show(uword value) {
        history[calls] = value
        calls++
        txt.print_uw(value)
        txt.nl()
    }
}
