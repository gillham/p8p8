%import textio
%zeropage basicsafe

; more than the zero page holds: what @requirezp asks for is an error then, what
; @zp asks for is not
main {
    ubyte[80] @requirezp many
    ubyte[80] @requirezp more
    uword[60] @zp wish
    uword[4] @requirezp words
    sub start() {
        many[1] = 1
        more[1] = 2
        wish[1] = 3
        words[3] = 4
        txt.print_uw(many[1] + more[1] + wish[1])
    }
}
