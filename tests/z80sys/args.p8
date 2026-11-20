; The command line, the wait and the clock on CP/M.  make z80sys runs it in tnylpo
; with the arguments "one two  three" and with none.

%import textio
main {
    sub start() {
        uword n = sys.argc()
        uword k
        txt.print_uw(n)
        for k in 1 to n - 1 {
            txt.spc()
            txt.print(sys.argv(k))
        }
        txt.chrout('|')
        txt.print(sys.argv(9))
        txt.chrout('|')
        sys.wait(3)
        sys.waitvsync()
        txt.print_uw(sys.ticks())
        txt.nl()
    }
}
