%import textio

; The 45GS02's way to name an address of 28 bits, tried by hand: a pointer of four
; bytes in the zero page, used with [zp],z.  A byte is written into bank 4 (the
; MEGA65's memory at $40000) and into the attic RAM at $8000000 and read back, four
; bytes are stored and fetched there with the 32-bit register, and bank 0 is looked at
; to see that it was left alone.
main {
    ubyte[16] @shared buffer        ; the place in bank 0 with the same low address
    ubyte[10] @shared results
    ubyte @shared bank0

    sub start() {
        buffer[0] = $11
        modes()
        ubyte k
        txt.print("[zp],z      ")
        txt.print_ubhex(results[0], true)
        txt.spc()
        txt.print_ubhex(results[1], true)
        txt.nl()
        txt.print("ldq [zp]    ")
        for k in 2 to 5 {
            txt.print_ubhex(results[k], true)
            txt.spc()
        }
        txt.nl()
        txt.print("attic       ")
        txt.print_ubhex(results[6], true)
        txt.nl()
        if bank0 == $11
            txt.print("bank 4 is memory of its own")
        else
            txt.print("bank 4 is bank 0 again")
        txt.nl()
    }

    asmsub modes() {
        %asm {{
            .cpu "45gs02"
            ; the pointer: bank 4, the address of the buffer
            lda  #<p8v_buffer
            sta  P8ZP_SCRATCH_W1
            lda  #>p8v_buffer
            sta  P8ZP_SCRATCH_W1+1
            lda  #$04
            sta  P8ZP_SCRATCH_W1+2
            lda  #$00
            sta  P8ZP_SCRATCH_W1+3
            ldz  #0
            lda  #$b1
            sta  [P8ZP_SCRATCH_W1],z
            lda  #0
            lda  [P8ZP_SCRATCH_W1],z
            sta  p8v_results+0
            ldz  #9
            lda  #$b2
            sta  [P8ZP_SCRATCH_W1],z
            lda  #0
            lda  [P8ZP_SCRATCH_W1],z
            sta  p8v_results+1
            ; four bytes at once
            lda  #$c1
            ldx  #$c2
            ldy  #$c3
            ldz  #$c4
            stq  [P8ZP_SCRATCH_W1]
            lda  #0
            tax
            tay
            taz
            ldq  [P8ZP_SCRATCH_W1],z
            sta  p8v_results+2
            stx  p8v_results+3
            sty  p8v_results+4
            stz  p8v_results+5
            ; the attic RAM
            lda  #$00
            sta  P8ZP_SCRATCH_W1+2
            lda  #$08
            sta  P8ZP_SCRATCH_W1+3
            ldz  #0
            lda  #$b3
            sta  [P8ZP_SCRATCH_W1],z
            lda  #0
            lda  [P8ZP_SCRATCH_W1],z
            sta  p8v_results+6
            ; bank 0
            lda  p8v_buffer
            sta  p8v_bank0
            ldz  #0
            .cpu "default"
            rts
        }}
    }
}
