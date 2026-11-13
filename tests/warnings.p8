; What -warnall says, and what it must not say anything about.
; (make test compares the warnings with tests/expected/llvm64_warnings.txt)

%import textio

main {
    ubyte never                 ; warned: nothing uses it
    ubyte counted = 3
    ubyte @shared for_others    ; not warned: @shared says something else uses it

    struct Point {
        ubyte x
        ubyte y
    }

    sub start() {
        ubyte local_unused      ; warned
        ubyte local_used = 1
        ^^Point p = 2000
        txt.print_ub(local_used + counted + helper(4, 5))
        txt.print_ub(p.x)       ; p is used through its field
        txt.print_ub(main.qualified.seen)
        qualified()
        after_return()
        loops()
        return
        txt.print("never")      ; warned: after the return
    }

    sub helper(ubyte wanted, ubyte ignored) -> ubyte {     ; warned: the parameter ignored
        return wanted + 1
    }

    sub qualified() {
        ubyte seen = 7          ; used by name from start
        txt.spc()
    }

    sub orphan() {              ; warned: never called
        txt.nl()
    }

    sub after_return() -> ubyte {
        if counted == 3 {
            return 1
        }
        ; reached when counted is not 3: nothing to warn about
        return 0
    back:
        ; reached through the label: not warned
        goto back
    }

    sub loops() {
        ubyte i
        for i in 0 to 3 {
            if i == 2 {
                break
                txt.print("x")  ; warned: after the break
            }
            continue
            txt.print("y")      ; warned: after the continue
        }
    }
}
