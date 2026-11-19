; More of upstream's checks, with its messages (for the X16): tags, booleans,
; values, signatures.  Every line marked "error" must be reported.
main {
    ubyte @shared @fast counter                 ; error: no such tag
    ubyte[4] @shared @nosplit bytes             ; error: not a word array
    ubyte @shared @alignword single             ; error: not an array
    ubyte[4] @shared buffer
    uword[200] @shared @nosplit many            ; error: 128 at most unless split
    struct Node {
        ubyte value
        ^^Node next
    }
    union Either {
        ubyte small
        uword big
    }

    sub start() {
        bool @shared flag
        ubyte @shared number = 3
        flag = number                           ; error: a number is no boolean
        if number and flag                      ; error: and is for booleans
            number++
        if flag > number                        ; error: no order on booleans
            number++
        uword @shared address
        address = buffer                        ; error: &buffer
        ^^ubyte @shared bp = 0
        ^^uword @shared wp = 0
        wp = bp                                 ; error: another pointer type
        ^^Node @shared node = ^^Node:[value=1, colour=2]    ; error: no such field
        ^^Either @shared either = [1]           ; error: a union has no values
        cx16.r0 = pair() + 1                    ; error: two values in an expression
        void call(start, 1)                     ; error: one argument
        on address goto (first, second)         ; error: the index is a byte
        cx16.r0L = sizeof(start)                ; error: of a subroutine
        cx16.r1L = 3.5 * 100 as ubyte           ; error: 350 does not fit
first:
second:
    }

    sub pair() -> ubyte, ubyte {
        return 1, 2
    }

    inline sub twice() {                        ; error (where it is called): two statements
        cx16.r0L++
        cx16.r1L++
    }

    sub caller() {
        twice()
    }

    sub registers(uword one @R1, ubyte two @R1) {       ; error: R1 twice
        one += two
    }

    asmsub carry(ubyte value @Pc) {             ; error: the carry is a boolean
        %asm {{
            rts
        }}
    }

    asmsub falls() -> ubyte @A {                ; error: it runs off its end
        %asm {{
            lda  #1
        }}
    }
}
