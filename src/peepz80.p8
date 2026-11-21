; p8p8: a pass over the Z80 assembly of one subroutine, after the code generator.
;
; genz80 gives every IR register a place in memory (p8r_S_N) and writes each instruction
; by itself: operands from their places into A, HL or DE, the result back to its place.
; Most of that traffic is not needed.  This pass reads the lines of a subroutine and
;
; - follows what A, HL and DE hold of those places, and drops a load of what is there
;   already (or makes it a move between registers, which is shorter);
; - then drops every store to a place that nothing reads any more.
;
; Only the places of IR registers are followed.  They belong to one subroutine, are
; never reached through a pointer, and are no machine's memory-mapped anything, so
; what a register holds of one stays true until a line that this pass can see changes
; it.  A label, a call and anything this pass does not know forget everything.
; Assembly of the program's own (%asm) is between two marker lines and is left as it
; stands.

%import buf
%import mem

peepz80 {
    %option ignore_unused

    ^^buf.Buf src = 0               ; the subroutine's text as it came
    ; the lines: where each begins in src, its length, and what became of it
    ^^long starts = 0
    ^^uword lengths = 0
    ^^ubyte fates = 0               ; F_KEEP, F_DROP or one of the replacements
    ^^long with_at = 0              ; F_HL_IS, F_DE_IS, F_A_IS: the operand that is loaded instead, in src
    ^^uword with_len = 0
    ^^buf.Buf volatile = 0          ; names of memory-mapped variables, each between line ends (genz80 fills it)
    long capacity = 0
    long count = 0
    ^^ubyte has_read = 0            ; per IR register number: a line reads its place

    const ubyte F_KEEP = 0
    const ubyte F_DROP = 1
    const ubyte F_EX = 2            ; ex de,hl
    const ubyte F_DE_HL = 3         ; ld d,h / ld e,l
    const ubyte F_HL_DE = 4         ; ld h,d / ld l,e
    const ubyte F_A_L = 5           ; ld a,l
    const ubyte F_A_H = 6           ; ld a,h
    const ubyte F_A_E = 7
    const ubyte F_A_D = 8
    const ubyte F_HL_IS = 9         ; ld hl,<with>
    const ubyte F_DE_IS = 10        ; ld de,<with>
    const ubyte F_A_IS = 11         ; ld a,<with>
    const ubyte F_WIDE_DE = 12      ; ld e,a / xor a / ld d,a   (in place of "xor a")
    const ubyte F_WIDE_HL = 13      ; ld l,a / xor a / ld h,a
    const ubyte F_SHORT = 14        ; jr in place of jp
    const ubyte F_XOR = 15          ; xor a in place of "ld a,0"

    ; What the registers hold at the jumps to a label that is still to come, by the
    ; label's name: where the jumps agree (and what runs into the label from above
    ; agrees too), the label has it.
    const ubyte JOINS = 48
    ^^long j_name_at = 0
    ^^uword j_name_len = 0
    ^^long j_at = 0                 ; three for each: HL, DE, A
    ^^uword j_len = 0
    ubyte joins = 0
    bool joins_full = false

    ; what a register holds: the text of a place (in src), or nothing (length 0)
    long hl_at
    uword hl_len
    long de_at
    uword de_len
    long a_at
    uword a_len

    ; the parts of the line being read
    long m_at                       ; the mnemonic
    uword m_len
    long o1_at                      ; the first operand
    uword o1_len
    long o2_at                      ; the second
    uword o2_len

    long saved = 0                  ; lines dropped or shortened, for whoever asks

    ; The lines of b from position from on are a subroutine: they are read, and b gets
    ; them back with what this pass did.
    sub run(^^buf.Buf b, long from) {
        if src == 0
            src = buf.new(16384)
        if has_read == 0 {
            has_read = mem.alloc(70000)
            long z
            for z in 0 to 69999
                has_read[z] = 0
        }
        ; (what one round leaves can let the next one do more: a store that is dropped
        ; frees a register, a register that keeps its value saves a load)
        ubyte rounds = 0
        repeat {
            buf.clear(src)
            buf.add_bytes(src, b.data + from, b.len - from)
            b.len = from
            split()
            follow()
            widened()
            forwarded()
            superseded()
            dead_loads()
            dead_stores()
            zero_loads()
            short_jumps()
            bool worked = write(b)
            rounds++
            if not worked or rounds == 6
                break
        }
    }

    ; the lines as they are now; did anything change?
    sub write(^^buf.Buf b) -> bool {
        bool worked = false
        long k
        for k in 0 to count - 1 {
            if fates[k] != F_KEEP
                worked = true
            when fates[k] {
                F_KEEP -> {
                    if into_de(k) {
                        ; "ld hl,X" and then "ex de,hl" (HL is loaded anew after it):
                        ; X goes to DE at once and HL keeps what it had
                        buf.add_str(b, "    ld  de,")
                        buf.add_bytes(b, src.data + o2_at, o2_len)
                        buf.add_byte(b, '\n')
                        worked = true
                    }
                    else {
                        buf.add_bytes(b, src.data + starts[k], lengths[k])
                        buf.add_byte(b, '\n')
                    }
                }
                F_DROP -> saved++
                F_EX -> buf.add_str(b, "    ex  de,hl\n")
                F_DE_HL -> buf.add_str(b, "    ld  d,h\n    ld  e,l\n")
                F_HL_DE -> buf.add_str(b, "    ld  h,d\n    ld  l,e\n")
                F_A_L -> buf.add_str(b, "    ld  a,l\n")
                F_A_H -> buf.add_str(b, "    ld  a,h\n")
                F_A_E -> buf.add_str(b, "    ld  a,e\n")
                F_A_D -> buf.add_str(b, "    ld  a,d\n")
                F_HL_IS -> loaded(b, k, "    ld  hl,")
                F_DE_IS -> loaded(b, k, "    ld  de,")
                F_A_IS -> loaded(b, k, "    ld  a,")
                F_WIDE_DE -> buf.add_str(b, "    ld  e,a\n    xor  a\n    ld  d,a\n")
                F_WIDE_HL -> buf.add_str(b, "    ld  l,a\n    xor  a\n    ld  h,a\n")
                F_XOR -> buf.add_str(b, "    xor  a\n")
                F_SHORT -> {
                    buf.add_str(b, "    jr")
                    buf.add_bytes(b, src.data + starts[k] + 6, lengths[k] - 6)
                    buf.add_byte(b, '\n')
                }
            }
        }
        return worked
    }

    sub loaded(^^buf.Buf b, long k, str start) {
        buf.add_str(b, start)
        buf.add_bytes(b, src.data + with_at[k], with_len[k])
        buf.add_byte(b, '\n')
    }

    ; Is line k "ld hl,X" with the exchange of DE and HL as the next line that is
    ; written?  Then that exchange is dropped, and the operand X is in o2.
    sub into_de(long k) -> bool {
        long j = k + 1
        while j < count and fates[j] == F_DROP
            j++
        if j >= count or fates[j] != F_EX
            return false
        if not instruction(k) or not is(m_at, m_len, "ld") or not is(o1_at, o1_len, "hl") or is(o2_at, o2_len, "(hl)")
            return false
        fates[j] = F_DROP
        return true
    }

    sub split() {
        long n = 1
        long p
        if src.len != 0 {
            for p in 0 to src.len - 1 {
                if src.data[p] == '\n'
                    n++
            }
        }
        if n > capacity {
            capacity = n + 256
            starts = mem.alloc(capacity * sizeof(long))
            with_at = mem.alloc(capacity * sizeof(long))
            with_len = mem.alloc(capacity * sizeof(uword))
            lengths = mem.alloc(capacity * sizeof(uword))
            fates = mem.alloc(capacity)
        }
        count = 0
        p = 0
        while p < src.len {
            long begin = p
            while p < src.len and src.data[p] != '\n'
                p++
            starts[count] = begin
            lengths[count] = (p - begin) as uword
            fates[count] = F_KEEP
            count++
            p++
        }
    }

    ; ---- reading a line ----

    ; is line k an instruction (four blanks, then a mnemonic)?  Its parts are found.
    sub instruction(long k) -> bool {
        ^^ubyte t = src.data + starts[k]
        uword n = lengths[k]
        if n < 6 or t[0] != ' ' or t[1] != ' ' or t[2] != ' ' or t[3] != ' ' or t[4] == ' ' or t[4] == ';'
            return false
        uword p = 4
        while p < n and t[p] != ' '
            p++
        m_at = starts[k] + 4
        m_len = p - 4
        while p < n and t[p] == ' '
            p++
        o1_at = starts[k] + p
        uword q = p
        while q < n and t[q] != ',' and t[q] != ';'
            q++
        o1_len = q - p
        o2_len = 0
        o2_at = 0
        if q < n and t[q] == ',' {
            q++
            while q < n and t[q] == ' '
                q++
            p = q
            while q < n and t[q] != ';'
                q++
            o2_at = starts[k] + p
            o2_len = q - p
        }
        ; (blanks at the end are not part of an operand)
        while o1_len != 0 and src.data[o1_at + o1_len - 1] == ' '
            o1_len--
        while o2_len != 0 and src.data[o2_at + o2_len - 1] == ' '
            o2_len--
        return true
    }

    sub is(long at, uword n, str text) -> bool {
        uword k = 0
        while text[k] != 0 {
            if k >= n or src.data[at + k] != text[k]
                return false
            k++
        }
        return k == n
    }

    ; is the operand the place of an IR register in brackets, "(p8r_...)"?
    sub place(long at, uword n) -> bool {
        return n > 6 and src.data[at] == '(' and src.data[at + 1] == 'p' and src.data[at + 2] == '8'
            and src.data[at + 3] == 'r' and src.data[at + 4] == '_'
    }

    sub same(long at1, uword n1, long at2, uword n2) -> bool {
        if n1 != n2 or n1 == 0
            return false
        uword k
        for k in 0 to n1 - 1 {
            if src.data[at1 + k] != src.data[at2 + k]
                return false
        }
        return true
    }

    ; the length of a place's text without its offset: "(p8r_2_14+1)" as far as the 4
    sub base_len(long at, uword n) -> uword {
        uword k = 0
        while k < n and src.data[at + k] != '+' and src.data[at + k] != ')'
            k++
        return k
    }

    ; do two places lie in the same IR register?
    sub overlap(long at1, uword n1, long at2, uword n2) -> bool {
        if n1 == 0 or n2 == 0
            return false
        uword b1 = base_len(at1, n1)
        uword b2 = base_len(at2, n2)
        if b1 != b2
            return false
        uword k
        for k in 0 to b1 - 1 {
            if src.data[at1 + k] != src.data[at2 + k]
                return false
        }
        return true
    }

    ; is place 2 the byte after place 1?  ("(p8r_2_14)" and "(p8r_2_14+1)")
    sub high_of(long at1, uword n1, long at2, uword n2) -> bool {
        if n1 == 0 or n2 != n1 + 2
            return false
        uword k
        for k in 0 to n1 - 2 {
            if src.data[at1 + k] != src.data[at2 + k]
                return false
        }
        return src.data[at2 + n1 - 1] == '+' and src.data[at2 + n1] == '1' and src.data[at2 + n1 + 1] == ')'
    }

    ; what the registers hold of variables is forgotten; of IR registers' places it stays
    sub forget_variables() {
        if hl_len != 0 and not place(hl_at, hl_len)
            hl_len = 0
        if de_len != 0 and not place(de_at, de_len)
            de_len = 0
        if a_len != 0 and not place(a_at, a_len)
            a_len = 0
    }

    sub forget() {
        hl_len = 0
        de_len = 0
        a_len = 0
    }

    ; a place was written: what the registers held of that IR register is gone
    sub written(long at, uword n) {
        if overlap(at, n, hl_at, hl_len)
            hl_len = 0
        if overlap(at, n, de_at, de_len)
            de_len = 0
        if overlap(at, n, a_at, a_len)
            a_len = 0
    }

    ; the register an operand names is changed
    sub changed(long at, uword n) {
        if n == 0
            return
        ubyte c = src.data[at]
        if n == 1 {
            when c {
                'a' -> a_len = 0
                'h', 'l' -> hl_len = 0
                'd', 'e' -> de_len = 0
            }
        }
        else if n == 2 {
            if c == 'h' and src.data[at + 1] == 'l'
                hl_len = 0
            else if c == 'd' and src.data[at + 1] == 'e'
                de_len = 0
            else if c == 'a' and src.data[at + 1] == 'f'
                a_len = 0
        }
    }

    ; is the next instruction after line k a load of HL (which then holds nothing yet)?
    sub hl_loaded_next(long k) -> bool {
        long save_m = m_at
        uword save_ml = m_len
        long s1 = o1_at
        uword s1l = o1_len
        long s2 = o2_at
        uword s2l = o2_len
        bool answer = false
        k++
        while k < count {
            if lengths[k] != 0 and src.data[starts[k]] != ';' {
                if instruction(k)
                    answer = is(m_at, m_len, "ld") and is(o1_at, o1_len, "hl") and not is(o2_at, o2_len, "(hl)")
                break
            }
            k++
        }
        m_at = save_m
        m_len = save_ml
        o1_at = s1
        o1_len = s1l
        o2_at = s2
        o2_len = s2l
        return answer
    }

    ; ---- what the registers hold ----

    sub follow() {
        forget()
        if j_name_at == 0 {
            j_name_at = mem.alloc(JOINS * sizeof(long))
            j_name_len = mem.alloc(JOINS * sizeof(uword))
            j_at = mem.alloc(JOINS * 3 * sizeof(long))
            j_len = mem.alloc(JOINS * 3 * sizeof(uword))
        }
        joins = 0
        joins_full = false
        bool own_asm = false
        bool unreached = false      ; after a jump or return without a condition, until a label
        long k
        for k in 0 to count - 1 {
            ^^ubyte t = src.data + starts[k]
            if lengths[k] >= 5 and t[0] == ';' and t[1] == '%' {
                ; (";%asm" before assembly of the program's own, ";%end" after it)
                own_asm = t[2] == 'a'
                unreached = false
                forget()
                continue
            }
            if own_asm
                continue
            if lengths[k] == 0 or t[0] == ';'
                continue
            if not instruction(k) {
                if not joined(k, unreached)
                    forget()        ; a label that anything may come to, or something else
                unreached = false
                continue
            }
            if unreached {
                fates[k] = F_DROP   ; (nothing comes here)
                continue
            }
            if is(m_at, m_len, "ld")
                load(k)
            else if is(m_at, m_len, "ex") {
                if is(o1_at, o1_len, "de") and is(o2_at, o2_len, "hl") {
                    long ta = hl_at
                    uword tn = hl_len
                    hl_at = de_at
                    hl_len = de_len
                    de_at = ta
                    de_len = tn
                }
                else
                    forget()
            }
            else if is(m_at, m_len, "push") or is(m_at, m_len, "cp") or is(m_at, m_len, "scf") or is(m_at, m_len, "ccf")
                    or is(m_at, m_len, "nop") or is(m_at, m_len, "bit") or is(m_at, m_len, "out") or is(m_at, m_len, "djnz") {
                ; (nothing that is followed changes)
            }
            else if is(m_at, m_len, "jp") or is(m_at, m_len, "jr") or is(m_at, m_len, "ret") {
                ; (with a condition the next line is reached with everything as it is;
                ; without one it is not reached from here at all)
                if not is(m_at, m_len, "ret") {
                    if o2_len != 0
                        jump_to(o2_at, o2_len)
                    else
                        jump_to(o1_at, o1_len)
                }
                if o2_len == 0 and not (is(m_at, m_len, "ret") and o1_len != 0) {
                    forget()
                    unreached = true
                }
            }
            else if is(m_at, m_len, "inc") or is(m_at, m_len, "dec") or is(m_at, m_len, "sla") or is(m_at, m_len, "sra")
                    or is(m_at, m_len, "srl") or is(m_at, m_len, "rl") or is(m_at, m_len, "rr") or is(m_at, m_len, "pop") {
                if o1_len != 0 and src.data[o1_at] == '('
                    forget_variables()      ; (memory through a pointer)
                changed(o1_at, o1_len)
            }
            else if is(m_at, m_len, "set") or is(m_at, m_len, "res") {
                if o2_len != 0 and src.data[o2_at] == '('
                    forget_variables()
                changed(o2_at, o2_len)
            }
            else if is(m_at, m_len, "or") or is(m_at, m_len, "and") {
                ; (with A itself the value stays)
                if not is(o1_at, o1_len, "a")
                    a_len = 0
            }
            else if is(m_at, m_len, "sub") or is(m_at, m_len, "xor") or is(m_at, m_len, "neg") or is(m_at, m_len, "cpl")
                    or is(m_at, m_len, "rla") or is(m_at, m_len, "rra") or is(m_at, m_len, "rlca") or is(m_at, m_len, "rrca")
                    or is(m_at, m_len, "daa")
                a_len = 0
            else if is(m_at, m_len, "add") or is(m_at, m_len, "adc") or is(m_at, m_len, "sbc")
                changed(o1_at, o1_len)
            else
                forget()            ; a call, a block move, anything else
        }
    }

    ; ---- labels where the ways in agree ----

    sub join_of(long at, uword n) -> ubyte {
        ubyte j = 0
        while j < joins {
            if same(at, n, j_name_at[j], j_name_len[j])
                return j
            j++
        }
        return 255
    }

    ; a jump to the label that the operand names, with the registers as they are
    sub jump_to(long at, uword n) {
        if n == 0 or src.data[at] == '('
            return
        ubyte j = join_of(at, n)
        if j == 255 {
            if joins == JOINS {
                joins_full = true
                return
            }
            j = joins
            joins++
            j_name_at[j] = at
            j_name_len[j] = n
            j_at[j * 3] = hl_at
            j_len[j * 3] = hl_len
            j_at[j * 3 + 1] = de_at
            j_len[j * 3 + 1] = de_len
            j_at[j * 3 + 2] = a_at
            j_len[j * 3 + 2] = a_len
            return
        }
        if not same(hl_at, hl_len, j_at[j * 3], j_len[j * 3])
            j_len[j * 3] = 0
        if not same(de_at, de_len, j_at[j * 3 + 1], j_len[j * 3 + 1])
            j_len[j * 3 + 1] = 0
        if not same(a_at, a_len, j_at[j * 3 + 2], j_len[j * 3 + 2])
            j_len[j * 3 + 2] = 0
    }

    sub name_char(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
    }

    ; does line k name the label (as a whole name)?
    sub names_label(long k, long at, uword n) -> bool {
        if lengths[k] < n
            return false
        long p = starts[k]
        long last = starts[k] + lengths[k] - n
        while p <= last {
            uword q = 0
            while q < n and src.data[p + q] == src.data[at + q]
                q++
            if q == n and (p == starts[k] or not name_char(src.data[p - 1]))
                    and (p == last or not name_char(src.data[p + n]))
                return true
            p++
        }
        return false
    }

    ; Line k is not an instruction.  When it is a label of the compiler's own that only
    ; jumps above it name, the registers hold what they held at all of those jumps and
    ; (unless nothing runs into the label) just above it: true then, with the registers
    ; set so.  False: nothing is known.
    sub joined(long k, bool unreached) -> bool {
        if joins_full
            return false
        long at = starts[k]
        uword n = lengths[k]
        if n < 6 or src.data[at + n - 1] != ':'
            return false
        n--
        ; (only the labels that the compiler made: no other subroutine jumps to them)
        bool own = false
        if n > 14 and src.data[at] == '_' and src.data[at + 1] == 'p' and src.data[at + 2] == '8' and src.data[at + 3] == '_'
                and src.data[at + 4] == 'l' and src.data[at + 5] == 'a' and src.data[at + 6] == 'b' and src.data[at + 7] == 'e'
                and src.data[at + 8] == 'l' and src.data[at + 9] == '_' and src.data[at + 10] == 'g' and src.data[at + 11] == 'e'
                and src.data[at + 12] == 'n' and src.data[at + 13] == '_'
            own = true
        if src.data[at] == 'p' and src.data[at + 1] == '8' and src.data[at + 2] == 'z' and src.data[at + 3] == '_'
            own = true
        if not own
            return false
        ; who names it: above only jumps, below nobody
        bool in_asm = false
        long j
        for j in 0 to count - 1 {
            if j == k
                continue
            ^^ubyte t = src.data + starts[j]
            if lengths[j] >= 5 and t[0] == ';' and t[1] == '%' {
                in_asm = t[2] == 'a'
                continue
            }
            if lengths[j] == 0 or (t[0] == ';' and not in_asm)
                continue
            if not names_label(j, at, n)
                continue
            if j > k or in_asm or not instruction(j)
                return false
            if not is(m_at, m_len, "jp") and not is(m_at, m_len, "jr")
                return false
        }
        ubyte found = join_of(at, n)
        if found == 255
            return not unreached    ; (no jump comes here: as from above, when that runs in)
        if unreached {
            hl_at = j_at[found * 3]
            hl_len = j_len[found * 3]
            de_at = j_at[found * 3 + 1]
            de_len = j_len[found * 3 + 1]
            a_at = j_at[found * 3 + 2]
            a_len = j_len[found * 3 + 2]
            return true
        }
        if not same(hl_at, hl_len, j_at[found * 3], j_len[found * 3])
            hl_len = 0
        if not same(de_at, de_len, j_at[found * 3 + 1], j_len[found * 3 + 1])
            de_len = 0
        if not same(a_at, a_len, j_at[found * 3 + 2], j_len[found * 3 + 2])
            a_len = 0
        return true
    }

    ; "ld a,0" where the flags are not read before they are set again: "xor a", a byte
    ; shorter.
    sub zero_loads() {
        long k
        for k in 0 to count - 1 {
            if not kept(k) or not is(m_at, m_len, "ld") or not is(o1_at, o1_len, "a") or not is(o2_at, o2_len, "0")
                continue
            long j = k
            ubyte steps = 0
            while steps < 16 {
                steps++
                j = next_live(j)
                if j >= count or src.data[starts[j]] == ';'
                    break
                if fates[j] != F_KEEP {
                    if fates[j] == F_SHORT
                        break
                    continue        ; (a load in another form)
                }
                if not instruction(j)
                    continue        ; (a label: on into what follows it)
                if is(m_at, m_len, "ld") or is(m_at, m_len, "ex") or is(m_at, m_len, "inc") or is(m_at, m_len, "dec")
                    continue
                if is(m_at, m_len, "push") or is(m_at, m_len, "pop") {
                    if is(o1_at, o1_len, "af")
                        break
                    continue
                }
                if is(m_at, m_len, "cp") or is(m_at, m_len, "or") or is(m_at, m_len, "and") or is(m_at, m_len, "xor")
                        or is(m_at, m_len, "sub") or is(m_at, m_len, "neg") or is(m_at, m_len, "call")
                        or (is(m_at, m_len, "add") and is(o1_at, o1_len, "a"))
                        or (is(m_at, m_len, "ret") and o1_len == 0) {
                    fates[k] = F_XOR
                }
                break
            }
        }
    }

    ; a load: "ld  to,from"
    sub load(long k) {
        ; (an ordinary variable is followed like the place of an IR register; a
        ; memory-mapped one is not)
        bool from_place = place(o2_at, o2_len) or (direct(o2_at, o2_len) and not is_volatile(o2_at, o2_len))
        bool to_place = place(o1_at, o1_len) or (direct(o1_at, o1_len) and not is_volatile(o1_at, o1_len))
        if not to_place and o1_len != 0 and src.data[o1_at] == '(' {
            ; a store through a pointer, or to memory-mapped memory: any variable may
            ; have changed (the places of IR registers have not)
            forget_variables()
            return
        }
        if from_place {
            if is(o1_at, o1_len, "hl") {
                if same(o2_at, o2_len, hl_at, hl_len)
                    fates[k] = F_DROP
                else if same(o2_at, o2_len, de_at, de_len) {
                    fates[k] = F_HL_DE
                    hl_at = de_at
                    hl_len = de_len
                }
                else {
                    hl_at = o2_at
                    hl_len = o2_len
                }
            }
            else if is(o1_at, o1_len, "de") {
                if same(o2_at, o2_len, de_at, de_len)
                    fates[k] = F_DROP
                else if same(o2_at, o2_len, hl_at, hl_len) {
                    if hl_loaded_next(k) {
                        ; (HL is loaded anew at once: the two change places)
                        ; (What HL gets is not counted on: the load that follows
                        ; must stay, since the exchange itself may go, see into_de.)
                        fates[k] = F_EX
                        hl_len = 0
                    }
                    else
                        fates[k] = F_DE_HL
                    de_at = o2_at
                    de_len = o2_len
                }
                else {
                    de_at = o2_at
                    de_len = o2_len
                }
            }
            else if is(o1_at, o1_len, "a") {
                if same(o2_at, o2_len, a_at, a_len)
                    fates[k] = F_DROP
                else {
                    if same(o2_at, o2_len, hl_at, hl_len)
                        fates[k] = F_A_L
                    else if high_of(hl_at, hl_len, o2_at, o2_len)
                        fates[k] = F_A_H
                    else if same(o2_at, o2_len, de_at, de_len)
                        fates[k] = F_A_E
                    else if high_of(de_at, de_len, o2_at, o2_len)
                        fates[k] = F_A_D
                    a_at = o2_at
                    a_len = o2_len
                }
            }
            else
                changed(o1_at, o1_len)
            return
        }
        if to_place {
            written(o1_at, o1_len)
            if is(o2_at, o2_len, "hl") {
                hl_at = o1_at
                hl_len = o1_len
            }
            else if is(o2_at, o2_len, "de") {
                de_at = o1_at
                de_len = o1_len
            }
            else if is(o2_at, o2_len, "a") {
                a_at = o1_at
                a_len = o1_len
            }
            return
        }
        ; anything else: the register it loads no longer holds a place
        changed(o1_at, o1_len)
        ; The address of an IR register's place ("ld hl,p8r_2_14"): what comes next
        ; writes that place through the pointer, so what a register held of it is
        ; no longer its value.
        if o2_len > 4 and src.data[o2_at] == 'p' and src.data[o2_at + 1] == '8' and src.data[o2_at + 2] == 'r'
                and src.data[o2_at + 3] == '_' {
            if named(hl_at, hl_len, o2_at, o2_len)
                hl_len = 0
            if named(de_at, de_len, o2_at, o2_len)
                de_len = 0
            if named(a_at, a_len, o2_at, o2_len)
                a_len = 0
        }
    }

    ; is the place "(p8r_2_14+1)" one of the IR register that the name "p8r_2_14" is?
    sub named(long at, uword n, long name_at, uword name_len) -> bool {
        if n == 0 or not place(at, n)
            return false
        uword b = base_len(at, n) - 1
        uword nb = 0
        while nb < name_len and src.data[name_at + nb] != '+'
            nb++
        if b != nb
            return false
        uword k
        for k in 0 to b - 1 {
            if src.data[at + 1 + k] != src.data[name_at + k]
                return false
        }
        return true
    }

    ; ---- more of the same kind ----

    ; the next line after k that will be written and is not a comment or empty; count
    ; when there is none
    sub next_live(long k) -> long {
        k++
        while k < count {
            if fates[k] != F_DROP and lengths[k] != 0 and src.data[starts[k]] != ';'
                return k
            if lengths[k] >= 2 and src.data[starts[k]] == ';' and src.data[starts[k] + 1] == '%'
                return k            ; (the marker of assembly of the program's own: a stop)
            k++
        }
        return count
    }

    ; is line k an instruction that is kept as it is?  Its parts are found.
    sub kept(long k) -> bool {
        return k < count and fates[k] == F_KEEP and instruction(k)
    }

    ; does the line run on to the next one, with nothing that this pass cannot follow?
    ; (No jump, call or return, no label, no store through a pointer, no block move.)
    sub plain(long k) -> bool {
        if not kept(k)
            return false
        if is(m_at, m_len, "jp") or is(m_at, m_len, "jr") or is(m_at, m_len, "ret") or is(m_at, m_len, "call")
                or is(m_at, m_len, "djnz") or is(m_at, m_len, "rst") or is(m_at, m_len, "ldir") or is(m_at, m_len, "lddr")
            return false
        ; (a store through a register pair may be to anything)
        if o1_len >= 4 and src.data[o1_at] == '(' and not direct(o1_at, o1_len)
            return false
        return true
    }

    ; is the operand a place in memory by its name or number, "(name)", not "(hl)"?
    sub direct(long at, uword n) -> bool {
        if n < 3 or src.data[at] != '('
            return false
        if is(at, n, "(hl)") or is(at, n, "(de)") or is(at, n, "(bc)") or is(at, n, "(sp)") or is(at, n, "(c)")
            return false
        return not (src.data[at + 1] == 'i' and (src.data[at + 2] == 'x' or src.data[at + 2] == 'y'))
    }

    ; Is the operand something whose value may change by itself, or whose reading does
    ; something?  Memory at a number, and a memory-mapped variable.
    sub is_volatile(long at, uword n) -> bool {
        if not direct(at, n)
            return false
        ubyte c = src.data[at + 1]
        if c == '$' or (c >= '0' and c <= '9')
            return true
        if volatile == 0 or volatile.len == 0
            return false
        ; the name without brackets and offset, between line ends in the list
        uword m = base_len(at, n) - 1
        long p = 0
        while p + m + 1 < volatile.len {
            if volatile.data[p] == '\n' and volatile.data[p + m + 1] == '\n' {
                uword q = 0
                while q < m and volatile.data[p + 1 + q] == src.data[at + 1 + q]
                    q++
                if q == m
                    return true
            }
            p++
        }
        return false
    }

    ; does line k (as it came) name the IR register of the place at (at, n)?
    sub mentions(long k, long at, uword n) -> bool {
        uword b = base_len(at, n) - 1       ; "p8r_2_14"
        if lengths[k] < b
            return false
        long p = starts[k]
        long last = starts[k] + lengths[k] - b
        while p <= last {
            if src.data[p] == 'p' {
                uword q = 0
                while q < b and src.data[p + q] == src.data[at + 1 + q]
                    q++
                if q == b {
                    ubyte after = 0
                    if p + b < starts[k] + lengths[k]
                        after = src.data[p + b]
                    if after < '0' or after > '9'
                        return true
                }
            }
            p++
        }
        return false
    }

    ; A byte made a word through its place, and the word then taken into DE or HL:
    ;     ld (C),a / xor a / ld (C+1),a / [ld hl,X] / ld de,(C)
    ; The byte goes to E while A still has it.
    sub widened() {
        long k
        for k in 0 to count - 1 {
            if not kept(k) or not is(m_at, m_len, "ld") or not place(o1_at, o1_len) or not is(o2_at, o2_len, "a")
                continue
            long c_at = o1_at
            uword c_len = o1_len
            if base_len(c_at, c_len) + 1 != c_len
                continue                        ; (the low byte: no offset)
            long k1 = next_live(k)
            if not kept(k1) or not is(m_at, m_len, "xor") or not is(o1_at, o1_len, "a")
                continue
            long k2 = next_live(k1)
            if not kept(k2) or not is(m_at, m_len, "ld") or not is(o2_at, o2_len, "a") or not high_of(c_at, c_len, o1_at, o1_len)
                continue
            long k3 = next_live(k2)
            if not kept(k3) or not is(m_at, m_len, "ld")
                continue
            if is(o1_at, o1_len, "hl") and same(o2_at, o2_len, c_at, c_len) {
                fates[k1] = F_WIDE_HL
                fates[k3] = F_DROP
                continue
            }
            if is(o1_at, o1_len, "hl") and not place(o2_at, o2_len) {
                ; (one load of HL may stand between)
                k3 = next_live(k3)
                if not kept(k3) or not is(m_at, m_len, "ld")
                    continue
            }
            if is(o1_at, o1_len, "de") and same(o2_at, o2_len, c_at, c_len) {
                fates[k1] = F_WIDE_DE
                fates[k3] = F_DROP
            }
        }
    }

    ; A value that goes through a place on its way: "ld hl,S / ld (C),hl" and later
    ; "ld hl,(C)" (or DE; or the same with A).  The later load takes S itself, when S
    ; is a constant or a variable that nothing between may have changed.
    sub forwarded() {
        long k
        for k in 0 to count - 2 {
            if not kept(k) or not is(m_at, m_len, "ld") or place(o2_at, o2_len) or is_volatile(o2_at, o2_len)
                continue
            bool wide = is(o1_at, o1_len, "hl")
            if not wide and not is(o1_at, o1_len, "a")
                continue
            if o2_len == 0 or (src.data[o2_at] == '(' and not direct(o2_at, o2_len))
                continue
            ; (a byte's source is a constant or memory, not another register)
            if not wide and o2_len == 1
                continue
            long s_at = o2_at
            uword s_len = o2_len
            bool s_memory = src.data[s_at] == '('
            long k1 = next_live(k)
            if not kept(k1) or not is(m_at, m_len, "ld") or not place(o1_at, o1_len)
                continue
            if wide and not is(o2_at, o2_len, "hl")
                continue
            if not wide and not is(o2_at, o2_len, "a")
                continue
            long c_at = o1_at
            uword c_len = o1_len
            long j = next_live(k1)
            while j < count {
                if fates[j] != F_KEEP
                    break
                if mentions(j, c_at, c_len) {
                    if kept(j) and is(m_at, m_len, "ld") and same(o2_at, o2_len, c_at, c_len) {
                        ubyte how = 0
                        if wide and is(o1_at, o1_len, "hl")
                            how = F_HL_IS
                        else if wide and is(o1_at, o1_len, "de")
                            how = F_DE_IS
                        else if not wide and is(o1_at, o1_len, "a")
                            how = F_A_IS
                        if how != 0 {
                            fates[j] = how
                            with_at[j] = s_at
                            with_len[j] = s_len
                        }
                    }
                    break
                }
                if not plain(j)
                    break
                ; (a store to the variable that S is: ordinary variables do not share
                ; memory, and the memory-mapped ones are not forwarded at all)
                if s_memory and is(m_at, m_len, "ld") and direct(o1_at, o1_len) and same_variable(o1_at, o1_len, s_at, s_len)
                    break
                j = next_live(j)
            }
        }
    }

    ; are two operands "(name...)" the same variable, whatever their offsets?
    sub same_variable(long at1, uword n1, long at2, uword n2) -> bool {
        uword b1 = base_len(at1, n1)
        if b1 != base_len(at2, n2)
            return false
        uword k
        for k in 0 to b1 - 1 {
            if src.data[at1 + k] != src.data[at2 + k]
                return false
        }
        return true
    }

    ; A store to a place, and before anything reads that IR register another store to
    ; the same place: the first one is for nothing.
    sub superseded() {
        long k
        for k in 0 to count - 2 {
            if not is_store(k)
                continue
            long c_at = o1_at
            uword c_len = o1_len
            uword first_width = o2_len      ; (1: a byte register, 2: a pair)
            long j = next_live(k)
            while j < count {
                if mentions(j, c_at, c_len) {
                    ; (the later store must cover all of the first: a byte does not
                    ; replace a word)
                    if is_store(j) and same(o1_at, o1_len, c_at, c_len) and o2_len >= first_width and o2_len <= 2
                        fates[k] = F_DROP
                    break
                }
                if not plain(j)
                    break
                j = next_live(j)
            }
        }
    }

    ; "ld hl,S" and at once another load of HL: the first is for nothing (unless reading
    ; S does something).  The same for DE and A.
    sub dead_loads() {
        long k
        for k in 0 to count - 2 {
            if not kept(k) or not is(m_at, m_len, "ld") or is_volatile(o2_at, o2_len)
                continue
            ubyte which = 0
            if is(o1_at, o1_len, "hl")
                which = 1
            else if is(o1_at, o1_len, "de")
                which = 2
            else if is(o1_at, o1_len, "a")
                which = 3
            if which == 0 or (o2_len != 0 and src.data[o2_at] == '(' and not direct(o2_at, o2_len))
                continue
            long j = next_live(k)
            if j >= count or fates[j] == F_KEEP {
                if not kept(j) or not is(m_at, m_len, "ld")
                    continue
                ; (the second load must not take its value from the register itself)
                if which == 1 and is(o1_at, o1_len, "hl") and (o2_len == 0 or src.data[o2_at] != '(' or direct(o2_at, o2_len))
                    fates[k] = F_DROP
                else if which == 2 and is(o1_at, o1_len, "de") and (o2_len == 0 or src.data[o2_at] != '(' or direct(o2_at, o2_len))
                    fates[k] = F_DROP
                else if which == 3 and is(o1_at, o1_len, "a") and o2_len != 1
                    fates[k] = F_DROP
            }
            else if (fates[j] == F_HL_IS and which == 1) or (fates[j] == F_DE_IS and which == 2) or (fates[j] == F_A_IS and which == 3)
                fates[k] = F_DROP
        }
    }

    ; ---- short jumps ----

    ; A jump to a label that is near becomes the short one (two bytes, not three).  Near:
    ; at most 30 lines away, counted as they will be written.  No instruction that the
    ; generator writes is longer than four bytes, so that is within the 126 that a short
    ; jump reaches, whatever the lines are.  Only the conditions that the short jump has.
    sub short_jumps() {
        long k
        for k in 0 to count - 1 {
            if not kept(k) or not is(m_at, m_len, "jp")
                continue
            long t_at = o1_at
            uword t_len = o1_len
            if o2_len != 0 {
                if not (is(o1_at, o1_len, "z") or is(o1_at, o1_len, "nz") or is(o1_at, o1_len, "c") or is(o1_at, o1_len, "nc"))
                    continue
                t_at = o2_at
                t_len = o2_len
            }
            if t_len == 0 or src.data[t_at] == '('
                continue
            if near(k, t_at, t_len, 1) or near(k, t_at, t_len, -1)
                fates[k] = F_SHORT
        }
    }

    ; is the label a line within reach of line k, in this direction?
    sub near(long k, long t_at, uword t_len, byte direction) -> bool {
        ubyte lines = 0
        long j = k
        repeat {
            if direction > 0
                j++
            else
                j--
            if j < 0 or j >= count or lines > 30
                return false
            uword n = lengths[j]
            if n == 0 or fates[j] == F_DROP
                continue
            ^^ubyte t = src.data + starts[j]
            if t[0] == ';' {
                if n >= 2 and t[1] == '%'
                    return false        ; (assembly of the program's own: of unknown length)
                continue
            }
            if t[0] != ' ' {
                ; a label: this one?
                if n == t_len + 1 and t[n - 1] == ':' {
                    uword q = 0
                    while q < t_len and t[q] == src.data[t_at + q]
                        q++
                    if q == t_len
                        return true
                }
                continue
            }
            when fates[j] {
                F_WIDE_DE, F_WIDE_HL -> lines += 3
                F_DE_HL, F_HL_DE -> lines += 2
                else -> lines++
            }
        }
    }

    ; ---- stores that nothing reads ----

    ; the number of the IR register in a place's text: "(p8r_2_14+1)" is 14
    sub register_number(long at) -> long {
        long p = at + 5             ; after "(p8r_"
        while src.data[p] >= '0' and src.data[p] <= '9'
            p++
        p++                         ; the underscore
        long n = 0
        while src.data[p] >= '0' and src.data[p] <= '9' {
            n = n * 10 + (src.data[p] - '0')
            p++
        }
        if n > 69999
            n = 69999
        return n
    }

    ; is line k, as it will be written, a store to a place and nothing else?
    sub is_store(long k) -> bool {
        if fates[k] != F_KEEP or not instruction(k)
            return false
        return is(m_at, m_len, "ld") and place(o1_at, o1_len)
    }

    sub dead_stores() {
        long k
        long p
        ; which IR registers does a line read?  Every mention of a place that is not
        ; the target of a store.  (A line that was dropped or replaced reads nothing.)
        bool own_asm = false
        for k in 0 to count - 1 {
            if fates[k] != F_KEEP or lengths[k] < 6
                continue
            long first = starts[k]
            long last = starts[k] + lengths[k] - 5
            long skip = -1
            if is_store(k)
                skip = o1_at
            p = first
            while p <= last {
                if src.data[p] == 'p' and src.data[p + 1] == '8' and src.data[p + 2] == 'r' and src.data[p + 3] == '_'
                        and p > first and p - 1 != skip
                    has_read[register_number(p - 1)] = 1
                p++
            }
        }
        for k in 0 to count - 1 {
            if is_store(k) and has_read[register_number(o1_at)] == 0
                fates[k] = F_DROP
        }
        ; (the marks are for this subroutine only)
        for k in 0 to count - 1 {
            if lengths[k] < 6
                continue
            p = starts[k] + 1
            long stop = starts[k] + lengths[k] - 4
            while p < stop {
                if src.data[p] == 'p' and src.data[p + 1] == '8' and src.data[p + 2] == 'r' and src.data[p + 3] == '_'
                    has_read[register_number(p - 1)] = 0
                p++
            }
        }
    }
}
