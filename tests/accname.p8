; In a block with %option no_symbol_prefixing a variable may be named "a".  The
; code generator's accumulator instructions must not name an operand "a" then:
; the assembler would take it for the variable.  Prints 11 3 99 12.
%import textio
%zeropage basicsafe

main {
    sub start() {
        test.run()
    }
}

test {
    %option no_symbol_prefixing

    ubyte[4] table = [10, 20, 30, 40]

    sub run() {
        ubyte a
        ubyte r1
        ubyte r2
        ubyte r3

        a = 99
        r1 = table[0] + 1
        r2 = table[2] >> 3
        r3 = (table[1] - 1) << 1
        r3 = (r3 >> 2) + 3
        txt.print_ub(r1)
        txt.spc()
        txt.print_ub(r2)
        txt.spc()
        txt.print_ub(a)
        txt.spc()
        txt.print_ub(r3)
        txt.nl()
    }
}

; merged into the library's block, which has the option: the warning here too
txt {
    %option merge

    sub twice(ubyte a) -> ubyte {
        return a * 2
    }
}
