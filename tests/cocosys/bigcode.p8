; The coco3ram target with a program that is too long for the memory below $8000:
; p8c puts some of its blocks above, and the program's first instructions read them
; from the end of its file (lib/targets/coco3ram/target.properties, high_loader).
; Each block here is long through bytes that do nothing, with a few known ones at
; their end; the routines are called from wherever each block is, with a float and
; the highram module at work between.  make cocosys runs it from a disk in XRoar.
%import textio
%import floats
%import highram
main {
    sub start() {
        txt.print_uw(one.sum(100))
        txt.spc()
        txt.print_uw(two.sum(200))
        txt.spc()
        txt.print_uw(three.sum(300))
        txt.spc()
        txt.print_uw(four.sum(400))
        txt.nl()
        txt.print_ub(one.last())
        txt.print_ub(two.last())
        txt.print_ub(three.last())
        txt.print_ub(four.last())
        txt.nl()
        txt.print_f(sqrt(2.0) * four.twice(2))
        txt.nl()
        highram.setbyte(5, 99)
        txt.print_ub(highram.getbyte(5))
        txt.spc()
        ; which of the blocks are above
        txt.print_bool(&one.sum >= $8000 or &two.sum >= $8000 or &three.sum >= $8000 or &four.sum >= $8000)
        txt.print_bool(&txt.print_uw < $8000 and &main.start != 0)
        txt.print_bool(sys.upperstart() > $8000)
        txt.nl()
    }
}

one {
    sub sum(uword n) -> uword {
        uword total = 0
        uword k
        for k in 1 to n
            total += k
        return total + two.twice(1)
    }
    asmsub last() -> ubyte @A {
        %asm {{
            lda  p8t_one_end-1
            jmp  p8t_one_end
            zmb  9000
            fcb  1
p8t_one_end:
            rts
        }}
    }
}

two {
    sub sum(uword n) -> uword {
        uword total = 0
        uword k
        for k in 1 to n
            total += k
        return total + three.twice(2)
    }
    sub twice(uword n) -> uword {
        return n * 2
    }
    asmsub last() -> ubyte @A {
        %asm {{
            lda  p8t_two_end-1
            jmp  p8t_two_end
            zmb  9000
            fcb  2
p8t_two_end:
            rts
        }}
    }
}

three {
    sub sum(uword n) -> uword {
        uword total = 0
        uword k
        for k in 1 to n
            total += k
        return total + four.twice(3)
    }
    sub twice(uword n) -> uword {
        return n * 2
    }
    asmsub last() -> ubyte @A {
        %asm {{
            lda  p8t_three_end-1
            jmp  p8t_three_end
            zmb  9000
            fcb  3
p8t_three_end:
            rts
        }}
    }
}

four {
    sub sum(uword n) -> uword {
        uword total = 0
        uword k
        for k in 1 to n
            total += k
        return total + one.sum(4)
    }
    sub twice(uword n) -> uword {
        return n * 2
    }
    asmsub last() -> ubyte @A {
        %asm {{
            lda  p8t_four_end-1
            jmp  p8t_four_end
            zmb  9000
            fcb  4
p8t_four_end:
            rts
        }}
    }
}
