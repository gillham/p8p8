; Far memory (the MEGA65): what a long address cannot do yet, and what is too far.
main {
    &ubyte[8] far = $40200
    &ubyte farone = $40300
    &ubyte toofar = $10000000                   ; error: 28 bits is all there is
    long @shared where = $40000

    sub start() {
        cx16.r0 = &far                          ; error: the address is no pointer
        bool @shared found = 13 in far          ; error: searched by its address
        sys.memset(far, 8, 0)                   ; error: passed by its address
        cx16.r0L = @(where)                     ; error: a long variable as the address (not yet)
        cx16.r0L = peek(where)                  ; error
        cx16.r1L = where[2]                     ; error
        farone = far[1]
    }
}
