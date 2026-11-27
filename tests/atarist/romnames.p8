; math's names for code in ROM on the 68000 targets of p8p8's own: each is the plain
; routine, and gives what that gives from the same seed.
%import textio
%import math

main {
    sub start() {
        math.rndseed_rom($1234, $5678)
        ubyte a = math.randrange_rom(100)
        ubyte b = math.rnd_rom()
        uword w = math.rndw_rom()
        uword r = math.randrangew_rom(1000)
        math.rndseed($1234, $5678)
        txt.print_bool(a == math.randrange(100) and a < 100)
        txt.print_bool(b == math.rnd())
        txt.print_bool(w == math.rndw())
        txt.print_bool(r == math.randrangew(1000) and r < 1000)
        txt.nl()
    }
}
