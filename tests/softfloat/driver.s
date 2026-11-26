; The float routines of the 68000 machines, each with the operands of table.s (which
; tests/softfloat/vectors.py writes): an Atari ST program that prints every result as
; eight hex digits on a line.  tests/softfloat/run.sh builds and runs it.
        section .text,code
start:  lea     table,a3
.loop:  move.l  (a3)+,d7
        bmi     .end
        move.l  (a3)+,d0
        move.l  (a3)+,d1
        cmp.w   #0,d7
        bne.s   .n1
        bsr     p8f_add
        bra     .show
.n1:    cmp.w   #1,d7
        bne.s   .n2
        bsr     p8f_sub
        bra     .show
.n2:    cmp.w   #2,d7
        bne.s   .n3
        bsr     p8f_mul
        bra     .show
.n3:    cmp.w   #3,d7
        bne.s   .n4
        bsr     p8f_div
        bra     .show
.n4:    cmp.w   #4,d7
        bne.s   .n5
        bsr     p8f_cmp
        bra     .show
.n5:    cmp.w   #5,d7
        bne.s   .n6
        bsr     p8f_fromsl
        bra     .show
.n6:    cmp.w   #6,d7
        bne.s   .n7
        bsr     p8f_tosl
        bra     .show
.n7:    bsr     p8f_sqrt
.show:  move.l  d0,d6
        moveq   #7,d5
.digit: rol.l   #4,d6
        move.w  d6,d0
        and.w   #15,d0
        add.w   #'0',d0
        cmp.w   #'9',d0
        bls.s   .out
        addq.w  #7,d0
.out:   move.w  d0,-(sp)
        move.w  #2,-(sp)
        trap    #1
        addq.l  #4,sp
        dbra    d5,.digit
        move.w  #10,-(sp)
        move.w  #2,-(sp)
        trap    #1
        addq.l  #4,sp
        bra     .loop
.end:   clr.w   -(sp)
        move.w  #$4c,-(sp)
        trap    #1
        include "m68k_softfloat.asm"
        section .data,data
table:
        include "table.s"
        dc.l    -1
