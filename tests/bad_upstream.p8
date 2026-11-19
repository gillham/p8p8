; Checks that upstream's compiler makes, with its messages (for the X16, where
; an address is a word).  Every statement marked "error" must be reported.
main {
    ubyte[4] @shared buffer
    str @shared name = "hello"
    enum Level { LOW, NORMAL, HIGH, EXTREME = 1 }       ; error: the value of NORMAL
    struct Node {
        ubyte value
        ^^Node next
    }
    ubyte level
    level = 5                                   ; error: not in a subroutine

    sub start() {
        ^^ubyte @shared p = &&buffer
        long @shared l = p                      ; error: a pointer is a word
        long @shared big = 70000
        uword @shared w
        w = big                                 ; error: a long into a word
        cx16.r0L = @(big)                       ; error: a long is no address
        cx16.r0L = big[2]                       ; error: nor can it be indexed
        w = start                               ; error: the address is &start
        w = w - p                               ; error: which way round?
        p = $12345                              ; error: no such address
        cx16.r0L = 300 as ubyte                 ; error: 300 is not cut down
        cx16.r0L = -200 as ubyte                ; error
        cx16.r1 = name + 2                      ; error: &name + 2
        bool @shared found = 99 in 12345        ; error: in what?
        ubyte @shared a, b, c
        a, b, c = 1, 2, 3, 4                    ; error: four values for three
        ^^Node @shared head = 0
        for n in head via .next step 1 {        ; error: a list has no step
            n.value = 1
        }
        ubyte[3] @shared three
        three = buffer                          ; error: sizes differ
        ubyte[4] @shared four
        four = buffer                           ; error: arrays are not assigned
        ubyte @shared where = 42
        goto where                              ; error: an address is a word
    }

    sub loop() -> uword {                       ; error: it never returns
again:
        goto again
    }
}
