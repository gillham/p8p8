; lexer sample: every kind of token, for the -tokens dump test
/* block comment
   /* nested */ still comment */
%import textio
%option enable_floats, no_sysinit
%zeropage basicsafe

main {
    struct Node { ^^Node next ; comment after code
        uword value }
    ubyte[] @shared bytes = [1, $ff, %1010_1010, 1_000]
    uword @zp w = $ffff
    long big = -2_147_483_648
    uquad huge = $ffff_ffff_ffff_ffff
    float f = 1.5e-3
    float g = .25
    float h = 3.
    str s = "hello \"world\"\n"
    str t = iso:"tëxt"
    ubyte c = 'x'
    ubyte d = '\n'
    ubyte e = '\x41'
    const ubyte Priority::LOW = 1

    sub start() {
        ubyte @requirezp i
        for i in 0 to 10 step 2 {
            if i & 1 != 0 and not (i == 3 or i >= 7) {
                w += i as uword
                w -= 1
                w *= 2
                w /= 3
                w %= 4
                w &= 5
                w |= 6
                w ^= 7
                w <<= 1
                w >>= 1
                w = w << 2 >> 1
                i++
                i--
            }
            else if i <= 4 and i < 5 and i > 1 {
                w = &w
                w = &&w
                w = &<w
                w = &>w
                w = @($d020)
                w = ~w | w ^ w % 2 / 1 * 3 - 1 + 2
                w = w.next^^.value
            }
        }
        %asm {{
            lda #0
            sta $d020
        }}
        goto start
        on i goto (start, start)
        asmsub foo(ubyte a @A) clobbers(X) -> ubyte @Y {
            %asm {{ rts }}
        }
        return
    }
}
