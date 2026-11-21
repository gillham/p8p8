; The end of a for loop's range: upstream wants a value of the loop
; variable's own type there.  A smaller type is only widened when the start
; is a variable or expression of that type already; with a number as the
; start, or a start of a smaller type, it is an error.

%zeropage basicsafe

main {
    sub start() {
        ubyte ub = 5
        byte sb = 5
        uword uw = 500
        word sw = 500
        long lg = 70000
        ub += cx16.r2L
        sb += cx16.r2sL
        uw += cx16.r3
        sw += cx16.r3s
        lg += cx16.r4

        uword n
        word m
        long k

        for n in 0 to uw {                      ; fine
            cx16.r0L++
        }
        for n in ub to uw {                     ; fine: the start fits
            cx16.r0L++
        }
        for n in uw to ub {                     ; fine: widened to the start's type
            cx16.r0L++
        }
        for n in uw downto ub {                 ; fine
            cx16.r0L++
        }
        for k in lg to uw + ub {                ; fine
            cx16.r0L++
        }
        for k in 0 to uw as long {              ; fine: the cast belongs to the end
            cx16.r0L++
        }
        for n in 0 to ub {                      ; error
            cx16.r0L++
        }
        for n in ub to ub + 1 {                 ; error
            cx16.r0L++
        }
        for m in 0 to sb {                      ; error
            cx16.r0L++
        }
        for m in sb to ub {                     ; error
            cx16.r0L++
        }
        for k in 1 to 4000 + @($0080) {         ; error
            cx16.r0L++
        }
        for k in uw to sw {                     ; error
            cx16.r0L++
        }
        for uword t in 0 to ub {                ; error
            cx16.r0L++
        }

        ; "in" a range: an end that is not a number must fit the type of the value
        if n in ub to uw                        ; fine
            cx16.r0L++
        if ub in 0 to uw                        ; error
            cx16.r0L++
        if 4 in sb to 10                        ; error
            cx16.r0L++
    }
}
