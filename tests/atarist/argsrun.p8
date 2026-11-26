; Starts ARGS.TOS (tests/atarist/args.p8) with a command line, as a shell would:
; GEMDOS's Pexec, with the line as a length and its characters.
%import textio

main {
    str program = "ARGS.TOS"
    ubyte[] line = [22, 'o', 'n', 'e', ' ', ' ', 't', 'w', 'o', 9, 't', 'h', 'r', 'e', 'e', ' ', '-', 'x', ' ', 'l', 'a', 's', 't', 0]
    ubyte[] none = [0, 0]

    asmsub pexec(str name @A0, pointer tail @A1) -> long @D0 {
        %asm {{
            movem.l d2/a2,-(sp)
            clr.l   -(sp)               ; the parent's environment
            move.l  a1,-(sp)
            move.l  a0,-(sp)
            clr.w   -(sp)               ; load and go
            move.w  #$4b,-(sp)
            trap    #1
            lea     16(sp),sp
            movem.l (sp)+,d2/a2
            rts
        }}
    }

    sub start() {
        txt.print_l(pexec(program, &line))
        txt.nl()
        txt.print_l(pexec(program, &none))
        txt.nl()
        ; (Pterm0: tests/strun.sh ends Hatari at this one, not at the started program's Pterm)
        %asm {{
            clr.w   -(sp)
            trap    #1
        }}
    }
}
