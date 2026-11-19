%import textio
main {
    long @shared a = 100000
    long @shared b = 250000
    long @shared n = -5
    long @shared z = 0
    sub start() {
        if a < b txt.print("lt ") else txt.print("ge ")
        if a > b txt.print("gt ") else txt.print("le ")
        if a <= a txt.print("le ") else txt.print("gt ")
        if b >= a txt.print("ge ") else txt.print("lt ")
        if a == b txt.print("eq ") else txt.print("ne ")
        if a != b txt.print("ne ") else txt.print("eq ")
        if z == 0 txt.print("zero ") else txt.print("nonzero ")
        if a == 100000 txt.print("eq ") else txt.print("ne ")
        txt.nl()
        if n < a txt.print("lt ") else txt.print("ge ")
        if n < 0 txt.print("neg ") else txt.print("pos ")
        if a > n txt.print("gt ") else txt.print("le ")
        if n >= -5 txt.print("ge ") else txt.print("lt ")
        if n > -5 txt.print("gt ") else txt.print("le ")
        if n <= -6 txt.print("le ") else txt.print("gt ")
        if a > 99999 txt.print("gt ") else txt.print("le ")
        if a < 100000 txt.print("lt ") else txt.print("ge ")
        txt.nl()
        long big = 2000000000
        long small = -2000000000
        if small < big txt.print("lt ") else txt.print("ge ")
        if big < small txt.print("lt ") else txt.print("ge ")
        if big > small txt.print("gt ") else txt.print("le ")
        if small >= big txt.print("ge ") else txt.print("lt ")
        txt.nl()
        long count = 0
        long i
        for i in 1 to 70000 step 7
            count += i
        txt.print_l(count)
        txt.spc()
        count = 0
        i = 300000
        while i > 299000 {
            count += 3
            i -= 10
        }
        txt.print_l(count)
        txt.spc()
        i = -3
        do {
            count -= 1000
            i++
        } until i == 2
        txt.print_l(count)
        txt.nl()
    }
}
