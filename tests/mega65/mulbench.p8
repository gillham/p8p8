%import textio
main {
    ubyte @shared a = 13
    ubyte @shared b = 17
    uword @shared w = 1234
    uword @shared x = 53
    word @shared sw = -321
    byte @shared sb = -7
    ubyte frame
    sub start() {
        txt.print_ub(a * b)
        txt.spc()
        txt.print_uw(w * x)
        txt.spc()
        txt.print_w(sw * 50 + sw * (x as word))
        txt.spc()
        txt.print_b(sb * (b as byte))
        txt.spc()
        txt.print_uw(w * w)
        txt.spc()
        txt.print_uw((a as uword) * 300)
        txt.nl()
        frame = @($d7fa)
        uword sum = 0
        uword i
        for i in 1 to 60000
            sum += i * x
        txt.print_uw(sum)
        txt.spc()
        txt.print_ub(@($d7fa) - frame)
        txt.print(" frames, words")
        txt.nl()
        frame = @($d7fa)
        ubyte bs = 0
        for i in 1 to 60000
            bs += lsb(i) * a
        txt.print_ub(bs)
        txt.spc()
        txt.print_ub(@($d7fa) - frame)
        txt.print(" frames, bytes")
        txt.nl()
    }
}
