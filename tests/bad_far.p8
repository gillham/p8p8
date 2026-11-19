; Far memory (the MEGA65): what a long address cannot do, and what is too far.
main {
    &ubyte[8] far = $40200
    &ubyte farone = $40300
    &ubyte toofar = $10000000                   ; error: 28 bits is all there is
    ubyte @shared index

    sub start() {
        cx16.r0 = &far                          ; error: the address is a long, not a word
        uword @shared w = &far                  ; error
        ^^ubyte @shared p = &&far               ; error: there is no pointer to it
        long @shared element = &far[index]      ; error: a constant index for now
        bool @shared found = 13 in far          ; error: searched by its address
        sys.memset(far, 8, 0)                   ; error: passed by its address
        farone = far[1]
    }
}
