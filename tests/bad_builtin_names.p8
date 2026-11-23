; An asmsub or extsub with the name of a builtin function is refused, as a sub is.
main {
    extsub $ffd2 = msb(ubyte c @A)

    asmsub poke() {
        %asm {{
            rts
        }}
    }

    sub start() {
    }
}
