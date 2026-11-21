; More of what the reference compiler refuses: programs that p8c compiled into
; something else than was written.

%import floats
%zeropage basicsafe

main {
    sub start() {
        float f = 7.5
        byte sb = -3
        ubyte ub = cx16.r4L
        sb += cx16.r0sL
        f = f % 2.0                 ; error: no remainder of floats
        f %= 2.0                    ; error
        ub = ub % 3                 ; fine
        repeat -3 {                 ; error
            cx16.r1L++
        }
        repeat sb {                 ; fine: not known when the program is compiled
            cx16.r1L++
        }
        repeat ub {                 ; fine
            cx16.r1L++
        }
        ubyte[5] five = 1 to ub     ; error: not known when the program is compiled
        ubyte[] some = 1 to ub      ; error
        ubyte[] known = 1 to 5      ; fine
        cx16.r0L = five[0] + some[0] + known[0]
    }
}
