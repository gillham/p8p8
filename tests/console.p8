%import textio

; A program that reads keys and asks for the terminal's size is built with
; the console runtime: its routines are called in place of getchar.

main {
    sub key() -> ubyte {
        %ir {{
            syscall 217 (): r99100.b
            returnr.b r99100.b
        }}
    }

    sub size() -> uword {
        %ir {{
            syscall 219 (): r99000.w
            returnr.w r99000.w
        }}
    }

    sub start() {
        txt.print_uw(size())
        txt.nl()
        txt.print_ub(key())
        txt.nl()
    }
}
