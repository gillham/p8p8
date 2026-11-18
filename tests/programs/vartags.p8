%import textio
%zeropage basicsafe

; every tag a variable can have: where it puts the variable, and that the
; variable works as any other
main {
    word  @zp         zpword = 9999
    uword @requirezp  zpaddr = $3000
    word  @shared     asmvar
    byte  @nozp       memvar
    uword[4] @nosplit together = [1, 2, 3, 4]
    uword[4]          apart = [1, 2, 3, 4]
    ubyte[3] @alignword aw = [1, 2, 3]
    ubyte[3] @align64 a64 = [1, 2, 3]
    ubyte[3] @alignpage apage = [1, 2, 3]
    sub start() {
        uword @dirty scratch
        ubyte @zp @shared both = 5
        scratch = zpword as uword + zpaddr + both
        txt.print_uw(scratch)
        txt.spc()
        txt.print_bool(&zpword < 256)
        txt.print_bool(&zpaddr < 256)
        txt.print_bool(&memvar >= 256)
        txt.print_bool(&aw & 1 == 0)
        txt.print_bool(&a64 & 63 == 0)
        txt.print_bool(&apage & 255 == 0)
        txt.print_bool(&together + 2 == &together[1])
        txt.print_uw(together[2] + apart[3] + aw[0] + a64[1] + apage[2])
        txt.nl()
    }
}
