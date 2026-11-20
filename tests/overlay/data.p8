%import textio
%zeropage basicsafe

; Strings and arrays in an overlay (make overlaycheck): a block with %option overlay_data
; has its strings and its arrays with values in its overlay beside its code, and the
; string literals that only its code names; the library is called with that overlay
; left in the window, so it can print them, and so is a block of the program that says
; %option overlay_safe.  The other block's are in main memory.
; (overlays 2 and 3: on the X16 the bank a program starts with is 1, and the test would not
; show which bank a subroutine in main memory finds if the strings were there)
%overlay 2, texts
%overlay 3, plain

main {
    sub start() {
        txt.print("data ")
        texts.show()
        txt.print_ub(texts.pick(2))
        txt.spc()
        txt.print_uw(texts.wide(1))
        txt.spc()
        txt.print_ub(texts.measured())
        txt.spc()
        plain.show()
        txt.nl()
    }
}

texts {
    %option overlay_data
    str title = "in the overlay"
    ubyte[] table = [3, 14, 15, 92]
    uword[] words = [1000, 2000, 3000]

    sub show() {
        txt.print(title)
        txt.spc()
        txt.print("a literal too")
        txt.spc()
    }

    sub pick(ubyte i) -> ubyte {
        return table[i]
    }

    sub wide(ubyte i) -> uword {
        return words[i]
    }

    ; a subroutine of the program in main memory is handed the string: its block says
    ; that it can be (%option overlay_safe)
    sub measured() -> ubyte {
        return tools.length(title)
    }
}

tools {
    %option overlay_safe

    sub length(str text) -> ubyte {
        ubyte n = 0
        while text[n] != 0
            n++
        return n
    }
}

plain {
    str note = "in main memory"

    sub show() {
        txt.print(note)
    }
}
