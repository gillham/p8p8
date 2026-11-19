%import textio

; The 65816's four ways to name a 24-bit address, tried by hand: a byte is written
; into bank 2 with each and read back, and bank 0 is looked at to see whether the
; machine has a bank 2 of its own or shows bank 0 there again.
;   absolute long            lda $021234
;   absolute long indexed    lda $021234,x
;   direct indirect long     lda [dp]
;   the same, indexed        lda [dp],y
; Build with -cpu 65816 (for the Commander X16 or the C64 with a SuperCPU).
main {
    ubyte[16] @shared buffer        ; the place in bank 0 with the same low address
    ubyte[8] @shared results
    ubyte @shared bank0             ; what buffer[0] is afterwards

    sub start() {
        buffer[0] = $11
        modes()
        ubyte k
        txt.print("long        ")
        txt.print_ubhex(results[0], true)
        txt.nl()
        txt.print("long,x      ")
        txt.print_ubhex(results[1], true)
        txt.spc()
        txt.print_ubhex(results[2], true)
        txt.nl()
        txt.print("[dp]        ")
        txt.print_ubhex(results[3], true)
        txt.nl()
        txt.print("[dp],y      ")
        txt.print_ubhex(results[4], true)
        txt.spc()
        txt.print_ubhex(results[5], true)
        txt.nl()
        if bank0 == $11
            txt.print("bank 2 is memory of its own")
        else
            txt.print("bank 2 is bank 0 again")
        txt.nl()
    }

    asmsub modes() {
        %asm {{
            .cpu "65816"
            php
            sei
            clc
            xce                     ; native mode, whatever it was
            php                     ; (the carry says what it was)
            sep  #$30               ; the accumulator and the index registers 8 bits wide
            ; absolute long
            lda  #$a1
            sta  $020000+p8v_buffer
            lda  #0
            lda  $020000+p8v_buffer
            sta  p8v_results+0
            ; absolute long, indexed by X
            ldx  #5
            lda  #$a2
            sta  $020000+p8v_buffer,x
            lda  #0
            lda  $020000+p8v_buffer,x
            sta  p8v_results+1
            lda  $020000+p8v_buffer+5
            sta  p8v_results+2
            ; direct indirect long: a pointer of three bytes in the zero page
            lda  #<p8v_buffer
            sta  P8ZP_SCRATCH_W1
            lda  #>p8v_buffer
            sta  P8ZP_SCRATCH_W1+1
            lda  #2
            sta  P8ZP_SCRATCH_W1+2
            lda  #$a3
            sta  [P8ZP_SCRATCH_W1]
            lda  #0
            lda  [P8ZP_SCRATCH_W1]
            sta  p8v_results+3
            ; and indexed by Y
            ldy  #7
            lda  #$a4
            sta  [P8ZP_SCRATCH_W1],y
            lda  #0
            lda  [P8ZP_SCRATCH_W1],y
            sta  p8v_results+4
            lda  $020000+p8v_buffer+7
            sta  p8v_results+5
            ; bank 0
            lda  p8v_buffer
            sta  p8v_bank0
            plp
            xce                     ; the mode the program was in
            plp
            .cpu "default"
            rts
        }}
    }
}
