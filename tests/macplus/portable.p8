; Names that programs written for other machines use, on the macplus target: the
; random numbers' routines for code in ROM, and the colour of a place on the screen.
%import textio
%import math

main {
    sub start() {
        math.rndseed_rom($1234, $5678)
        ubyte a = math.randrange_rom(100)
        math.rndseed($1234, $5678)
        txt.print_bool(a == math.randrange(100))
        txt.print_bool(a < 100)
        ; the other three, each against the plain routine from the same seed
        math.rndseed_rom(7, 9)
        ubyte b = math.rnd_rom()
        uword w = math.rndw_rom()
        uword r = math.randrangew_rom(1000)
        math.rndseed(7, 9)
        txt.print_bool(b == math.rnd())
        txt.print_bool(w == math.rndw())
        txt.print_bool(r == math.randrangew(1000) and r < 1000)
        txt.spc()
        txt.setclr(3, 3, 7)
        txt.print_ub(txt.getclr(3, 3))
        txt.spc()
        txt.setcc(70, 0, 'x', 5)
        txt.chrout(txt.getchr(70, 0))
        txt.nl()
    }
}
