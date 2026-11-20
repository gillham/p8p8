; Filling and copying memory, for the Z80 code generator's system calls: a fill with a
; byte and with a word, and copies that overlap in both directions.
; Compared with the host by make z80cmp.

%import textio

main {
    ubyte[16] bytes
    uword[4] @nosplit words

    sub show() {
        ubyte k
        for k in 0 to 15 {
            txt.print_ub(bytes[k])
            txt.spc()
        }
        txt.nl()
    }

    sub start() {
        ubyte k
        sys.memset(bytes, 16, 7)
        show()
        for k in 0 to 15
            bytes[k] = k
        sys.memcopy(&bytes, &bytes + 4, 8)      ; towards the end, over itself
        show()
        for k in 0 to 15
            bytes[k] = k
        sys.memcopy(&bytes + 4, &bytes, 8)      ; towards the start
        show()
        sys.memsetw(words, 4, $1234)
        txt.print_uwhex(words[0], true)
        txt.print_uwhex(words[3], true)
        txt.spc()
        txt.print_uw(sqrt(40000 as uword))
        txt.spc()
        txt.print_ub(clamp(200 as ubyte, 10, 100))
        txt.print_b(clamp(-50 as byte, -20, 20))
        txt.nl()
    }
}
