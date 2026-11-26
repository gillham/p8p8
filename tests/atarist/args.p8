; The command line of an Atari ST program (sys.argc, sys.argv).  tests/atarist/args.sh
; has tests/atarist/argsrun.p8 start it with one.
%import textio
%import strings

main {
    sub start() {
        uword n
        txt.print_uw(sys.argc())
        txt.nl()
        for n in 1 to sys.argc() {
            txt.chrout('[')
            txt.print(sys.argv(n))
            txt.chrout(']')
        }
        txt.nl()
        txt.print_ub(strings.length(sys.argv(0)))
        txt.nl()
        ; (two arguments held at once)
        str first = "?" * 20
        void strings.copy(sys.argv(1), first)
        txt.print(sys.argv(3))
        txt.print(first)
        txt.nl()
    }
}
