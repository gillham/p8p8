; The Model 4's clock: sys.ticks() counts 60ths of a second (an interrupt task of the
; DOS that the first call installs, see lib/targets/trs80m4/target.properties), so it
; moves over a wait, and by about as much as the wait is long.
%import textio
main {
    sub start() {
        uword before = sys.ticks()
        sys.wait(60)
        uword passed = sys.ticks() - before
        txt.print_bool(passed >= 30 and passed <= 180)
        txt.nl()
    }
}
