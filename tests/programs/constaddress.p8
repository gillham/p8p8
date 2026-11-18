%import textio
%zeropage basicsafe

; constants that are addresses the assembler works out: a block of memory()
; and a string
main {
    const pointer buffer = memory("buffer", 40, 0)
    const ^^ubyte name = "prog8"

    sub total(str text) -> uword {
        uword sum = 0
        ubyte k = 0
        while text[k] != 0 {
            sum += text[k]
            k++
        }
        return sum
    }

    sub start() {
        const pointer second = memory("second", 16, 0)
        @(buffer) = 11
        @(buffer + 39) = 22
        @(second + 5) = 33
        txt.print_ub(@(buffer) + @(buffer + 39) + @(second + 5))
        txt.spc()
        txt.print_bool(buffer != second)
        txt.print_bool(buffer == memory("buffer", 40, 0))
        txt.spc()
        txt.print(name)
        txt.spc()
        txt.print_uw(total(name))
        txt.nl()
    }
}
