%import textio
%zeropage basicsafe
%zpallowed $40,$5f
%zpreserved $40,$47
%varsaddress $0400

; directives that say where things go, and ones that do nothing to what a
; program prints: %zpallowed and %zpreserved (the zero page variables are in
; $48-$5f), %varsaddress (the others from $0400), %assert, %breakpoint
main {
    const ubyte LIMIT = 12
    %assert LIMIT == 12
    %assert LIMIT > 3, "the limit is too low"
    uword @requirezp pointer1
    uword @requirezp pointer2
    ubyte[20] buffer

    sub start() {
        %assert sizeof(uword) * LIMIT == 24
        pointer1 = &buffer
        pointer2 = pointer1 + 5
        buffer[5] = 77
        txt.print_ub(@(pointer2))
        ; (after a call: upstream reads "77" and a "%breakpoint" on the next line as a remainder)
        %breakpoint
        txt.spc()
        txt.print_bool(&pointer1 >= $48 and &pointer1 <= $5e)
        txt.print_bool(&pointer2 >= $48 and &pointer2 <= $5e)
        txt.print_bool(&buffer >= $0400 and &buffer < $0800)
        txt.nl()
    }
}
