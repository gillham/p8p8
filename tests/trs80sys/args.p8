; The command line and the directory on the TRS-80 targets.  trs80gp starts a program
; without a command line, so the first line printed is "1|"; then the program sets what
; the DOS would give it (HL at the rest of the line) and the arguments must come out.
; The directory is the DOS's own listing, on the screen; the program must go on after it.
; make trs80sys runs it on the Model I, III and 4.

%import textio
%import diskio
main {
    str @shared line = "one two  three\r"
    sub show() {
        uword n = sys.argc()
        uword k
        txt.print_uw(n)
        for k in 1 to n - 1 {
            txt.spc()
            txt.print(sys.argv(k))
        }
        txt.chrout('|')
        txt.nl()
    }
    sub start() {
        ; as trs80gp starts the program: no command line
        show()
        ; and as the DOS would: HL at the rest of the line
        %asm {{
            ld  hl,_main__line
            ld  (p8_entry_hl),hl
        }}
        show()
        void diskio.directory()
        txt.print("after\n")
    }
}
