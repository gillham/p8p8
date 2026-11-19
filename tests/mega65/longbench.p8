%import textio

; longs on the MEGA65: the time of a few loops, in video frames
main {
    ubyte frame

    sub start() {
        frame = @($d7fa)
        long sum = 0
        long i
        for i in 1 to 600000
            sum += i
        txt.print("add  ")
        txt.print_l(sum)
        report()

        sum = 0
        long x = 1
        repeat 4000 {
            x = x * 1103515245 + 12345
            sum ^= x
        }
        txt.print("mul  ")
        txt.print_l(sum)
        report()

        sum = 0
        for i in 1 to 2500
            sum += 2000000000 / i
        txt.print("div  ")
        txt.print_l(sum)
        report()

        long hits = 0
        long a = 0
        long b = 2000000
        while a < b {
            if a & 1023 == 0
                hits++
            a += 3
            b -= 2
        }
        txt.print("cmp  ")
        txt.print_l(hits)
        report()
    }

    sub report() {
        ; (the VIC-IV counts frames at $d7fa; the jiffy clock stands still in the emulator)
        ubyte now = @($d7fa)
        txt.spc()
        txt.print_ub(now - frame)
        txt.print(" frames")
        txt.nl()
        frame = @($d7fa)
    }
}
