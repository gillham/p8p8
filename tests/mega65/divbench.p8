%import textio
main {
    ubyte @shared a = 200
    ubyte @shared b = 17
    uword @shared w = 54321
    uword @shared x = 53
    word @shared sw = -3210
    ubyte frame
    sub start() {
        txt.print_ub(a / b)
        txt.spc()
        txt.print_ub(a % b)
        txt.spc()
        txt.print_uw(w / x)
        txt.spc()
        txt.print_uw(w % x)
        txt.spc()
        txt.print_w(sw / 7)
        txt.spc()
        txt.print_uw(w / 1000)
        txt.spc()
        txt.print_uw(w % 1000)
        txt.spc()
        txt.print_ub(b / a)
        txt.spc()
        txt.print_uw(x % w)
        txt.nl()
        frame = @($d7fa)
        uword sum = 0
        uword i
        for i in 1 to 30000
            sum += w / i + w % i
        txt.print_uw(sum)
        txt.spc()
        txt.print_ub(@($d7fa) - frame)
        txt.print(" frames, words")
        txt.nl()
        frame = @($d7fa)
        ubyte bs = 0
        ubyte j
        repeat 100 {
            for j in 1 to 255
                bs += a / j + a % j
        }
        txt.print_ub(bs)
        txt.spc()
        txt.print_ub(@($d7fa) - frame)
        txt.print(" frames, bytes")
        txt.nl()
    }
}
