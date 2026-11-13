; A status flag as the result of an asmsub: the carry (strings.isdigit and friends)
; used as a condition and as a value.
; Compared with upstream by the cx16 emulator suite.

%import textio
%import strings
%zeropage basicsafe

main {
    asmsub is_even(ubyte value @A) -> bool @Pc {
        %asm {{
            lsr  a
            bcc  +
            clc
            rts
+           sec
            rts
        }}
    }

    sub start() {
        ubyte digits = 0
        ubyte c
        for c in "a1b22c333-" {
            if strings.isdigit(c)
                digits++
        }
        txt.print_ub(digits)
        txt.chrout(' ')
        bool e4 = is_even(4)
        bool e7 = is_even(7)
        txt.print_bool(e4)
        txt.chrout(' ')
        txt.print_bool(e7)
        txt.chrout(' ')
        ubyte evens = 0
        for c in 1 to 9 {
            if is_even(c)
                evens++
            else if strings.isupper(c + 60)
                evens += 10
        }
        txt.print_ub(evens)
        txt.nl()
    }
}
