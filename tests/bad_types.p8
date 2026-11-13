; must be rejected: type errors
main {
    sub start() {
        ubyte b = 300           ; value out of range
        uword w = -1            ; value out of range
        word x = w              ; cannot assign uword to word
        bool f = w              ; cannot assign uword to bool
        if w                    ; condition must be boolean
            b++
        foo(1, 2)               ; wrong number of arguments
        foo(w)                  ; cannot pass uword as ubyte
        b = foo(1)              ; void result
        return 1                ; too many return values
        str s = "abc"
        ^^uword p = &&b         ; wrong pointer type
    }
    sub foo(ubyte a) {
    }
}
