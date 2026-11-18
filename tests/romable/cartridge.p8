%output raw
%launcher none
%address $8009
%option romable
%option no_sysinit
%zeropage basicsafe

; The shape of a C64 cartridge: the main block goes back to $8000 for the
; cartridge's header and on to the byte after the startup code.  What the
; compiler writes after the startup code has to be this block, and nothing
; that the header's lines would write over.
main {
    %asm {{
            *= $8000
            .addr prog8_program_start
            .addr p8b_main.p8s_nmi
            .byte $c3, $c2, $cd, $38, $30
            *= $8017
    }}
    uword counter = 3
    sub start() {
        counter++
        sys.memcopy(&payload, $0801, &payload_end - &payload)
    }
    asmsub nmi() {
        %asm {{
            rti
        }}
    }
payload:
    %asm {{
        .byte 1, 2, 3, 4, 5, 6, 7, 8
    }}
payload_end:
}
