%import textio
; which 32-bit instructions set the zero flag for all four bytes (in xmega65)?
; each case makes a value whose low byte is zero and whose other bytes are not
main {
    ubyte[16] @shared results
    long @shared v100 = $00000100
    long @shared vff00 = $0000ff00
    long @shared v101 = $00000101
    long @shared one = 1
    long @shared v80 = $00000080
    long @shared v200 = $00000200
    long @shared scratch
    sub start() {
        test()
        ubyte k
        for k in 0 to 15 {
            txt.chrout(results[k])
        }
        txt.nl()
    }
    asmsub test() {
        %asm {{
            .cpu "45gs02"
            ldx  #15
            lda  #'?'
-           sta  p8v_results,x
            dex
            bpl  -
            ; 0: ldq
            ldq  p8v_v100
            jsr  _flag
            sta  p8v_results+0
            ; 1: deq  ($101 - 1 = $100)
            ldq  p8v_v101
            deq
            jsr  _flag
            sta  p8v_results+1
            ; 2: inq  ($ff + 1 = $100)
            lda  #$ff
            ldx  #0
            ldy  #0
            ldz  #0
            inq
            jsr  _flag
            sta  p8v_results+2
            ; 3: adq  ($80 + $80)
            ldq  p8v_v80
            clc
            adq  p8v_v80
            jsr  _flag
            sta  p8v_results+3
            ; 4: sbq  ($101 - 1)
            ldq  p8v_v101
            sec
            sbq  p8v_one
            jsr  _flag
            sta  p8v_results+4
            ; 5: anq  ($101 & $ff00)
            ldq  p8v_v101
            anq  p8v_vff00
            jsr  _flag
            sta  p8v_results+5
            ; 6: orq  ($100 | $100)
            ldq  p8v_v100
            orq  p8v_v100
            jsr  _flag
            sta  p8v_results+6
            ; 7: eoq  ($101 ^ 1)
            ldq  p8v_v101
            eoq  p8v_one
            jsr  _flag
            sta  p8v_results+7
            ; 8: asl q  ($80 << 1)
            ldq  p8v_v80
            asl  q
            jsr  _flag
            sta  p8v_results+8
            ; 9: lsr q  ($200 >> 1)
            ldq  p8v_v200
            lsr  q
            jsr  _flag
            sta  p8v_results+9
            ; 10: asr q
            ldq  p8v_v200
            asr  q
            jsr  _flag
            sta  p8v_results+10
            ; 11: negq  (-(-$100))
            ldq  p8v_v100
            .byte $42, $42, $42
            .byte $42, $42, $42
            jsr  _flag
            sta  p8v_results+11
            ; 13: deq then stq (abs)
            ldq  p8v_v101
            deq
            stq  p8v_scratch
            jsr  _flag
            sta  p8v_results+13
            ; 14: ldq then stq zp-ish abs
            ldq  p8v_v100
            stq  p8v_scratch
            jsr  _flag
            sta  p8v_results+14
            ; 15: adq then stq
            ldq  p8v_v80
            clc
            adq  p8v_v80
            stq  p8v_scratch
            jsr  _flag
            sta  p8v_results+15
            ; 12: cpq equal low bytes ($100 against $200: not equal)
            ldq  p8v_v100
            cpq  p8v_v200
            jsr  _flag
            sta  p8v_results+12
            ldz  #0
            .cpu "default"
            rts
_flag       beq  +
            lda  #'n'           ; not zero: right
            rts
+           lda  #'z'           ; the zero flag is set: wrong
            rts
        }}
    }
}
