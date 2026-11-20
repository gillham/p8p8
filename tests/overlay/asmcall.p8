%import textio
%zeropage basicsafe

; Assembly that calls a subroutine in another overlay by its name gets a warning (make
; overlaycheck): the compiler writes the way into an overlay for calls in Prog8 code
; only.  From the main program and from overlay 2; the call inside overlay 1 is fine.
%overlay 1, first
%overlay 2, second

main {
    sub start() {
        first.value()
        direct()
        second.also()
    }

    asmsub direct() {
        %asm {{
            jsr  p8b_first.p8s_value
            rts
        }}
    }
}

first {
    ubyte count
    sub value() {
        count++
    }
    asmsub same_overlay() {
        %asm {{
            jmp  p8b_first.p8s_value
        }}
    }
}

second {
    sub also() {
        %asm {{
            jsr  p8b_first.p8s_value
        }}
        first.same_overlay()
    }
}
