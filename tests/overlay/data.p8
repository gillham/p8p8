%import textio
%zeropage basicsafe

; Strings and arrays in an overlay (make overlaycheck): a block with %option overlay_data
; has its strings and its arrays with values in its overlay beside its code, and the
; string literals that only its code names; the library is called with that overlay
; left in the window, so it can print them.  The other block's are in main memory.
%overlay 1, texts
%overlay 2, plain

main {
    sub start() {
        txt.print("data ")
        texts.show()
        txt.print_ub(texts.pick(2))
        txt.spc()
        txt.print_uw(texts.wide(1))
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
}

plain {
    str note = "in main memory"

    sub show() {
        txt.print(note)
    }
}
