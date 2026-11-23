; p8p8: passes over the 6809 assembly, after the code generator.
;
; gen6809 gives every IR register a place in memory (p8r_S_N) and writes each instruction
; by itself: operands from their places into B, D or X, the result back to its place.
; Most of that traffic is not needed.  run() reads the lines of one subroutine and
;
; - follows what A, B, D and X hold of those places, of constants and of the program's
;   variables, and drops a load of what is there already (or makes it a move between D
;   and X), and a test of what was just loaded or stored;
; - where a place was given the value of a constant, a variable or another place, has
;   what reads the place read that instead;
; - then drops every store to a place that nothing reads any more.
;
; The places belong to one subroutine, are never reached through a pointer, and are no
; machine's memory-mapped anything, so what is known of one stays true until a line that
; this pass can see changes it.  A variable can be changed through a pointer: what is
; known of variables is forgotten at every write to memory that is not a place.  A
; variable at a fixed address (memory-mapped: gen6809 lists them in "volatile") is not
; followed at all, and a place that stands for a variable is read as the variable once
; only, so the program reads its variables as often as it did.  A label, a call and
; anything this pass does not know forget everything.  Assembly of the program's own
; (%asm) is between two marker lines and is left as it stands.
;
; A load also sets the flags for the sign and for zero.  It is dropped only where
; nothing can read them: not before a branch on them, not before a label; unless the
; line before it left the same flags (the store or load of the same place).
;
; branches() goes over the whole program at the end: the generator writes every branch
; in its short form, and a branch whose target is not near becomes the long one.

%import buf
%import mem

peep6809 {
    %option ignore_unused

    ^^buf.Buf src = 0               ; the text as it came
    ; the lines: where each begins in src, its length, and what it is
    ^^long starts = 0
    ^^uword lengths = 0
    ^^ubyte kinds = 0
    ^^ubyte fates = 0               ; what a line becomes
    ^^long with_at = 0              ; F_OPERAND: the operand it gets, in src
    ^^uword with_len = 0
    long capacity = 0
    long count = 0
    ^^buf.Buf volatile = 0          ; names of memory-mapped variables, each between line ends (gen6809 fills it)

    const ubyte F_KEEP = 0
    const ubyte F_D_X = 1           ; tfr d,x
    const ubyte F_X_D = 2           ; tfr x,d
    const ubyte F_OPERAND = 3       ; the same instruction with another operand

    ; places that hold what something else holds: the place, the other thing, and
    ; whether it is a word
    const ubyte EQUALS = 12
    long[EQUALS] eq_place_at
    uword[EQUALS] eq_place_len
    long[EQUALS] eq_other_at
    uword[EQUALS] eq_other_len
    bool[EQUALS] eq_wide
    ubyte eq_next = 0

    const ubyte K_OTHER = 0         ; a label, a comment, a directive, an empty line
    const ubyte K_CODE = 1          ; an instruction
    const ubyte K_ASM = 2           ; a line of the program's own assembly
    const ubyte K_GONE = 3          ; dropped

    ; what an instruction does to what is followed
    const ubyte E_UNKNOWN = 0       ; forget everything
    const ubyte E_NONE = 1          ; nothing
    const ubyte E_LOAD = 2          ; a register is loaded
    const ubyte E_STORE = 3         ; a register is stored
    const ubyte E_A = 4             ; A changes
    const ubyte E_B = 5             ; B changes
    const ubyte E_D = 6             ; A and B change
    const ubyte E_X = 7             ; X changes
    const ubyte E_MEMORY = 8        ; its memory operand changes
    const ubyte E_TEST = 9          ; tst of a memory operand
    const ubyte E_CALL = 10         ; a call: the registers are not known after it, the variables neither

    ; what A, B, D and X hold: an operand's text in src (length 0: not known)
    long[4] held_at
    uword[4] held_len
    const ubyte R_A = 0
    const ubyte R_B = 1
    const ubyte R_D = 2
    const ubyte R_X = 3

    ; ---- the lines ----

    sub split(^^buf.Buf text, long from) {
        src = text
        count = 0
        long p = from
        bool in_asm = false
        while p < text.len {
            long begin = p
            while p < text.len and text.data[p] != '\n'
                p++
            if count >= capacity {
                long bigger = capacity * 2 + 1024
                starts = mem.grow(starts, capacity * sizeof(long), bigger * sizeof(long))
                lengths = mem.grow(lengths, capacity * sizeof(uword), bigger * sizeof(uword))
                kinds = mem.grow(kinds, capacity, bigger)
                fates = mem.grow(fates, capacity, bigger)
                with_at = mem.grow(with_at, capacity * sizeof(long), bigger * sizeof(long))
                with_len = mem.grow(with_len, capacity * sizeof(uword), bigger * sizeof(uword))
                capacity = bigger
            }
            starts[count] = begin
            lengths[count] = (p - begin) as uword
            ubyte kind = K_OTHER
            if p - begin == 5 and buf.bytes_equal(text.data + begin, ";%asm", 5) {
                in_asm = true
                kind = K_ASM
            }
            else if p - begin == 5 and buf.bytes_equal(text.data + begin, ";%end", 5) {
                in_asm = false
                kind = K_ASM
            }
            else if in_asm
                kind = K_ASM
            else if p - begin > 4 and text.data[begin] == ' ' and text.data[begin + 4] != ' ' and text.data[begin + 4] != ';'
                kind = K_CODE
            kinds[count] = kind
            fates[count] = F_KEEP
            ; (a directive is no instruction: bytes, words, text, room, where the code goes)
            if kind == K_CODE and (is(count, "fcb") or is(count, "fdb") or is(count, "fqb") or is(count, "fcc") or is(count, "rmb")
                    or is(count, "rzb") or is(count, "org") or is(count, "align") or is(count, "end") or is(count, "pragma"))
                kinds[count] = K_OTHER
            count++
            p++
        }
    }

    ; the text after position from becomes the lines that are left
    sub join(long from) {
        ^^buf.Buf result = buf.new(src.len - from + 16)
        long k = 0
        while k < count {
            if kinds[k] != K_GONE {
                when fates[k] {
                    F_D_X -> buf.add_str(result, "    tfr  d,x")
                    F_X_D -> buf.add_str(result, "    tfr  x,d")
                    F_OPERAND -> {
                        operand(k)
                        buf.add_bytes(result, src.data + starts[k], operand_at - starts[k])
                        buf.add_bytes(result, src.data + with_at[k], with_len[k])
                    }
                    else -> buf.add_bytes(result, src.data + starts[k], lengths[k])
                }
                buf.add_byte(result, '\n')
            }
            k++
        }
        src.len = from
        buf.add_bytes(src, result.data, result.len)
    }

    ; is the mnemonic of line k this one?
    sub is(long k, str mnemonic) -> bool {
        ^^ubyte t = src.data + starts[k] + 4
        long n = lengths[k] - 4
        long m = 0
        while mnemonic[m] != 0 {
            if m >= n or t[m] != mnemonic[m]
                return false
            m++
        }
        return m == n or t[m] == ' '
    }

    ; where the operand of line k begins in src, and how long it is (0: none)
    long operand_at
    uword operand_len

    sub operand(long k) {
        long p = starts[k] + 4
        long stop = starts[k] + lengths[k]
        while p < stop and src.data[p] != ' '
            p++
        while p < stop and src.data[p] == ' '
            p++
        operand_at = p
        operand_len = (stop - p) as uword
    }

    ; is the operand found something that is followed: a constant, the place of an IR
    ; register, or a variable of the program that is not memory-mapped?
    sub followed() -> bool {
        if operand_len == 0
            return false
        if src.data[operand_at] == '#'
            return true
        if operand_len > 4 and buf.bytes_equal(src.data + operand_at, "p8r_", 4)
            return true
        return is_variable(operand_at, operand_len)
    }

    ; a variable by its name (with an offset or without), and not a memory-mapped one
    sub is_variable(long at, uword length) -> bool {
        if length < 2 or src.data[at] != '_'
            return false
        uword n = 0
        while n < length {
            ubyte c = src.data[at + n]
            if c == ',' or c == '[' or c == '-' or c == '*'
                return false
            n++
        }
        if volatile == 0
            return true
        ; (its name without the offset, between two line ends in the list)
        uword name_len = base_len(at, length)
        long p = 0
        while p + name_len + 1 < volatile.len {
            if volatile.data[p] == '\n' and volatile.data[p + name_len + 1] == '\n'
                    and buf.bytes_equal(volatile.data + p + 1, src.data + at, name_len)
                return false
            p++
        }
        return true
    }

    sub is_place(long at, uword length) -> bool {
        return length > 4 and buf.bytes_equal(src.data + at, "p8r_", 4)
    }

    ; how long the name of a place is without its offset
    sub base_len(long at, uword length) -> uword {
        uword n = 0
        while n < length and src.data[at + n] != '+'
            n++
        return n
    }

    sub same_base(long a_at, uword a_len, long b_at, uword b_len) -> bool {
        uword an = base_len(a_at, a_len)
        return an == base_len(b_at, b_len) and buf.bytes_equal(src.data + a_at, src.data + b_at, an)
    }

    sub forget() {
        held_len[R_A] = 0
        held_len[R_B] = 0
        held_len[R_D] = 0
        held_len[R_X] = 0
        ubyte e
        for e in 0 to EQUALS - 1
            eq_place_len[e] = 0
    }

    ; Memory that is no place was written: what is known of variables may be wrong now.
    ; A store to a variable by its name (the operand found) changes that variable and no
    ; other; any other write may be through a pointer and can have changed every one.
    sub memory_written() {
        bool named = is_variable(operand_at, operand_len)
        ubyte r
        for r in 0 to 3 {
            if held_len[r] != 0 and src.data[held_at[r]] == '_' and (not named or same_base(held_at[r], held_len[r], operand_at, operand_len))
                held_len[r] = 0
        }
        ubyte e
        for e in 0 to EQUALS - 1 {
            if eq_place_len[e] != 0 and src.data[eq_other_at[e]] == '_'
                    and (not named or same_base(eq_other_at[e], eq_other_len[e], operand_at, operand_len))
                eq_place_len[e] = 0
        }
    }

    ; A call: the registers hold something else after it, and any variable may; but a
    ; place is the subroutine's own (one that can be called again from inside is saved
    ; around the call), so what a place is known to hold of a constant or of another
    ; place stays.
    sub called() {
        held_len[R_A] = 0
        held_len[R_B] = 0
        held_len[R_D] = 0
        held_len[R_X] = 0
        ubyte e
        for e in 0 to EQUALS - 1 {
            if eq_place_len[e] != 0 and src.data[eq_other_at[e]] == '_'
                eq_place_len[e] = 0
        }
    }

    ; the place holds what the other thing holds
    sub equal(long place, uword place_length, long other, uword other_length, bool wide) {
        eq_place_at[eq_next] = place
        eq_place_len[eq_next] = place_length
        eq_other_at[eq_next] = other
        eq_other_len[eq_next] = other_length
        eq_wide[eq_next] = wide
        eq_next++
        if eq_next == EQUALS
            eq_next = 0
    }

    ; what the place of the operand found holds too, as a word or as a byte: its number
    ; in the list, or 255
    sub equal_of(bool wide) -> ubyte {
        ubyte e
        for e in 0 to EQUALS - 1 {
            if eq_place_len[e] == operand_len and eq_wide[e] == wide and buf.bytes_equal(src.data + eq_place_at[e], src.data + operand_at, operand_len)
                return e
        }
        return 255
    }

    ; does the instruction of line k read its operand as a word (2), as a byte (1), or
    ; is it none that can read something else instead (0)?
    sub reads_as(long k) -> ubyte {
        if is(k, "ldd") or is(k, "ldx") or is(k, "ldu") or is(k, "ldy") or is(k, "addd") or is(k, "subd")
                or is(k, "cmpd") or is(k, "cmpx") or is(k, "cmpu") or is(k, "cmpy")
            return 2
        if is(k, "lda") or is(k, "ldb") or is(k, "adda") or is(k, "addb") or is(k, "suba") or is(k, "subb")
                or is(k, "anda") or is(k, "andb") or is(k, "ora") or is(k, "orb") or is(k, "eora") or is(k, "eorb")
                or is(k, "adca") or is(k, "adcb") or is(k, "sbca") or is(k, "sbcb") or is(k, "cmpa") or is(k, "cmpb")
                or is(k, "bita") or is(k, "bitb")
            return 1
        return 0
    }

    ; the place of the operand found has changed: no register holds a part of it now
    sub place_changed() {
        ubyte r
        for r in 0 to 3 {
            if held_len[r] != 0 and is_place(held_at[r], held_len[r]) and same_base(held_at[r], held_len[r], operand_at, operand_len)
                held_len[r] = 0
        }
        ubyte e
        for e in 0 to EQUALS - 1 {
            if eq_place_len[e] != 0 and (same_base(eq_place_at[e], eq_place_len[e], operand_at, operand_len)
                    or (is_place(eq_other_at[e], eq_other_len[e]) and same_base(eq_other_at[e], eq_other_len[e], operand_at, operand_len)))
                eq_place_len[e] = 0
        }
    }

    sub holds(ubyte r) -> bool {
        return held_len[r] != 0 and held_len[r] == operand_len and buf.bytes_equal(src.data + held_at[r], src.data + operand_at, operand_len)
    }

    ; the register that a load or store is of: R_A..R_X, or 255
    sub register_of(long k) -> ubyte {
        ubyte c = src.data[starts[k] + 6]
        if lengths[k] < 7
            return 255
        when c {
            'a' -> return R_A
            'b' -> return R_B
            'd' -> return R_D
            'x' -> return R_X
        }
        return 255
    }

    sub effect(long k) -> ubyte {
        ^^ubyte t = src.data + starts[k] + 4
        long n = lengths[k] - 4
        long m = 0
        while m < n and t[m] != ' '
            m++
        ; (m: the length of the mnemonic)
        if m == 3 and t[0] == 'l' and t[1] == 'd' {
            if t[2] == 'a' or t[2] == 'b' or t[2] == 'd' or t[2] == 'x'
                return E_LOAD
            return E_NONE               ; (ldu, ldy: not followed)
        }
        if m == 3 and t[0] == 's' and t[1] == 't' {
            if t[2] == 'a' or t[2] == 'b' or t[2] == 'd' or t[2] == 'x'
                return E_STORE
            return E_MEMORY             ; (stu, sty)
        }
        if is(k, "cmpa") or is(k, "cmpb") or is(k, "cmpd") or is(k, "cmpx") or is(k, "cmpy") or is(k, "cmpu")
                or is(k, "bita") or is(k, "bitb") or is(k, "tsta") or is(k, "tstb") or is(k, "andcc") or is(k, "orcc")
                or is(k, "pshs") or is(k, "leay") or is(k, "leau")
            return E_NONE
        if is(k, "tst")
            return E_TEST
        if is(k, "jsr") or is(k, "bsr")
            return E_CALL
        ; a conditional branch (not bra, bsr, brn)
        if t[0] == 'b' and m == 3 and not is(k, "bra") and not is(k, "bsr") and not is(k, "brn")
            return E_NONE
        if is(k, "adda") or is(k, "suba") or is(k, "anda") or is(k, "ora") or is(k, "eora") or is(k, "adca") or is(k, "sbca")
                or is(k, "clra") or is(k, "coma") or is(k, "nega") or is(k, "inca") or is(k, "deca") or is(k, "lsla")
                or is(k, "lsra") or is(k, "asra") or is(k, "rola") or is(k, "rora") or is(k, "sex")
            return E_A
        if is(k, "addb") or is(k, "subb") or is(k, "andb") or is(k, "orb") or is(k, "eorb") or is(k, "adcb") or is(k, "sbcb")
                or is(k, "clrb") or is(k, "comb") or is(k, "negb") or is(k, "incb") or is(k, "decb") or is(k, "lslb")
                or is(k, "lsrb") or is(k, "asrb") or is(k, "rolb") or is(k, "rorb")
            return E_B
        if is(k, "addd") or is(k, "subd") or is(k, "mul")
            return E_D
        if is(k, "abx") or is(k, "leax")
            return E_X
        if is(k, "clr") or is(k, "inc") or is(k, "dec") or is(k, "neg") or is(k, "com") or is(k, "lsl") or is(k, "lsr")
                or is(k, "asr") or is(k, "rol") or is(k, "ror")
            return E_MEMORY
        return E_UNKNOWN
    }

    ; does line k (or what can come to it) read the flags for the sign and for zero that
    ; the line before it left?
    sub reads_flags(long k) -> bool {
        while k < count and kinds[k] == K_GONE
            k++
        if k >= count or kinds[k] != K_CODE
            return true
        ^^ubyte t = src.data + starts[k] + 4
        if t[0] == 'b' and not is(k, "bra") and not is(k, "bsr") and not is(k, "bita") and not is(k, "bitb")
            return true
        if t[0] == 'l' and t[1] == 'b' and not is(k, "lbra") and not is(k, "lbsr")
            return true
        ; (a move or a push of the flags themselves)
        if is(k, "tfr") or is(k, "pshs") or is(k, "exg") {
            operand(k)
            long q = operand_at
            while q + 1 < operand_at + operand_len {
                if src.data[q] == 'c' and src.data[q + 1] == 'c'
                    return true
                q++
            }
        }
        return false
    }

    ; ---- one subroutine ----

    sub run(^^buf.Buf text, long from) {
        ; (twice: what the first round takes out lets the second see more)
        repeat 2 {
            split(text, from)
            loads()
            join(from)
            split(text, from)
            sums()
            join(from)
            split(text, from)
            stores()
            join(from)
            split(text, from)
            twice()
            join(from)
        }
        split(text, from)
        calls()
        join(from)
    }

    ; a load of what the register holds already, and a test of what was just moved
    sub loads() {
        forget()
        long before = -1            ; the instruction just before, when nothing is between
        long k = 0
        while k < count {
            if kinds[k] != K_CODE {
                if kinds[k] != K_GONE {
                    forget()
                    before = -1
                }
                k++
                continue
            }
            operand(k)
            ; (an operand that moves X along)
            if operand_len >= 3 {
                long q = operand_at
                long stop = operand_at + operand_len
                while q + 1 < stop {
                    if (src.data[q] == 'x' and src.data[q + 1] == '+') or (src.data[q] == '-' and src.data[q + 1] == 'x')
                        held_len[R_X] = 0
                    q++
                }
            }
            ubyte what = effect(k)
            ubyte r
            if what == E_LOAD {
                r = register_of(k)
                if r != 255 and holds(r) and (not reads_flags(k + 1) or same_flags(before, k)) {
                    kinds[k] = K_GONE
                    k++
                    continue            ; (the line before is still the one before)
                }
                operand(k)
                if r == R_X and holds(R_D) and not reads_flags(k + 1) {
                    ; (what D holds: a move is shorter than a load)
                    fates[k] = F_D_X
                    held_at[R_X] = operand_at
                    held_len[R_X] = operand_len
                    before = k
                    k++
                    continue
                }
                if r == R_D and holds(R_X) and not reads_flags(k + 1) {
                    fates[k] = F_X_D
                    held_len[R_A] = 0
                    held_len[R_B] = 0
                    held_at[R_D] = operand_at
                    held_len[R_D] = operand_len
                    before = k
                    k++
                    continue
                }
            }
            ; (a place that holds what something else holds: that is read instead)
            ubyte width = reads_as(k)
            if width != 0 and is_place(operand_at, operand_len) {
                ubyte e = equal_of(width == 2)
                if e != 255 {
                    fates[k] = F_OPERAND
                    with_at[k] = eq_other_at[e]
                    with_len[k] = eq_other_len[e]
                    operand_at = eq_other_at[e]
                    operand_len = eq_other_len[e]
                    ; (a variable is read once for each time the program read it)
                    if src.data[operand_at] == '_'
                        eq_place_len[e] = 0
                }
            }
            when what {
                E_UNKNOWN -> forget()
                E_CALL -> called()
                E_LOAD -> {
                    r = register_of(k)
                    if r == 255
                        forget()
                    else {
                        loaded(r)
                        if followed() {
                            held_at[r] = operand_at
                            held_len[r] = operand_len
                        }
                    }
                }
                E_STORE -> {
                    r = register_of(k)
                    if r == 255
                        forget()
                    else if is_place(operand_at, operand_len) {
                        long had_at = held_at[r]
                        uword had_len = held_len[r]
                        place_changed()
                        if had_len != 0 and not same_base(had_at, had_len, operand_at, operand_len)
                            equal(operand_at, operand_len, had_at, had_len, r == R_D or r == R_X)
                        held_at[r] = operand_at
                        held_len[r] = operand_len
                    }
                    else {
                        ; (A store through X leaves what X is known to hold of a variable:
                        ; only a pointer that points at itself would be changed by it.)
                        long x_at = held_at[R_X]
                        uword x_len = held_len[R_X]
                        bool through_x = operand_len >= 2 and src.data[operand_at + operand_len - 2] == ',' and src.data[operand_at + operand_len - 1] == 'x'
                        memory_written()
                        if through_x {
                            held_at[R_X] = x_at
                            held_len[R_X] = x_len
                        }
                        ; (the register holds the variable too now; what it is known to
                        ; hold of a place or a constant is kept, which lasts longer)
                        if held_len[r] == 0 and followed() {
                            held_at[r] = operand_at
                            held_len[r] = operand_len
                        }
                    }
                }
                E_A -> {
                    held_len[R_A] = 0
                    held_len[R_D] = 0
                }
                E_B -> {
                    held_len[R_B] = 0
                    held_len[R_D] = 0
                }
                E_D -> {
                    held_len[R_A] = 0
                    held_len[R_B] = 0
                    held_len[R_D] = 0
                }
                E_X -> held_len[R_X] = 0
                E_MEMORY -> {
                    if is_place(operand_at, operand_len)
                        place_changed()
                    else
                        memory_written()
                }
                E_TEST -> {
                    ; (a byte that was just loaded or stored: its flags are there)
                    if before >= 0 and fates[before] == F_KEEP and (is(before, "ldb") or is(before, "stb") or is(before, "lda") or is(before, "sta")) and same_operand(before, k) {
                        kinds[k] = K_GONE
                        k++
                        continue
                    }
                }
            }
            before = k
            k++
        }
    }

    ; a register was loaded: what it held, and what holds a part of it, is not known
    sub loaded(ubyte r) {
        held_len[r] = 0
        when r {
            R_A, R_B -> held_len[R_D] = 0
            R_D -> {
                held_len[R_A] = 0
                held_len[R_B] = 0
            }
        }
    }

    sub same_operand(long a, long b) -> bool {
        operand(a)
        long a_at = operand_at
        uword a_len = operand_len
        operand(b)
        return a_len == operand_len and buf.bytes_equal(src.data + a_at, src.data + operand_at, a_len)
    }

    ; did line a (the one before line b, or -1) leave the flags that the load in line b
    ; would: a load or store of the same register and operand?
    sub same_flags(long a, long b) -> bool {
        if a < 0
            return false
        ubyte ea = effect(a)
        if ea != E_LOAD and ea != E_STORE
            return false
        if register_of(a) != register_of(b)
            return false
        bool same = same_operand(a, b)
        operand(b)
        return same
    }

    ; ---- small things ----

    ; the instruction after line k when nothing but dropped lines is between, or -1
    sub next_code(long k) -> long {
        k++
        while k < count and kinds[k] == K_GONE
            k++
        if k < count and kinds[k] == K_CODE and fates[k] == F_KEEP
            return k
        return -1
    }

    ; can the load in line k be left out or moved: is its operand a constant, a place, or
    ; a variable that is not memory-mapped?
    sub plain_load(long k) -> bool {
        operand(k)
        return followed()
    }

    sub sums() {
        long k = 0
        while k < count {
            if kinds[k] != K_CODE {
                k++
                continue
            }
            long second = next_code(k)
            long third = -1
            if second >= 0
                third = next_code(second)
            ; "std P / ldd Q / addd P" is "addd Q" (and the same for bytes, with and, or,
            ; xor too): the sum does not mind which comes first
            if third >= 0 and is(k, "std") and is(second, "ldd") and is(third, "addd") and same_operand(k, third) and plain_load(second) {
                kinds[second] = K_GONE
                fates[third] = F_OPERAND
                operand(second)
                with_at[third] = operand_at
                with_len[third] = operand_len
            }
            else if third >= 0 and is(k, "stb") and is(second, "ldb") and (is(third, "addb") or is(third, "andb") or is(third, "orb") or is(third, "eorb"))
                    and same_operand(k, third) and plain_load(second) {
                kinds[second] = K_GONE
                fates[third] = F_OPERAND
                operand(second)
                with_at[third] = operand_at
                with_len[third] = operand_len
            }
            k++
        }
    }

    ; is line k a call of one of the program's subroutines ("_name" or "p8e_name")?
    sub program_call(long k) -> bool {
        operand(k)
        if operand_len == 0
            return false
        if src.data[operand_at] == '_'
            return true
        return operand_len > 4 and buf.bytes_equal(src.data + operand_at, "p8e_", 4)
    }

    ; is the operand of line k one that goes through a register (",x", "d,x", "[...]")?
    sub through_register(long k) -> bool {
        operand(k)
        long q = operand_at
        while q < operand_at + operand_len {
            if src.data[q] == ',' or src.data[q] == '['
                return true
            q++
        }
        return false
    }

    ; does line k read the carry?
    sub reads_carry(long k) -> bool {
        return is(k, "rolb") or is(k, "rola") or is(k, "rorb") or is(k, "rora") or is(k, "rol") or is(k, "ror")
            or is(k, "adcb") or is(k, "adca") or is(k, "sbcb") or is(k, "sbca") or is(k, "bcc") or is(k, "bcs")
            or is(k, "blo") or is(k, "bhs") or is(k, "bhi") or is(k, "bls") or is(k, "tfr") or is(k, "pshs")
    }

    sub twice() {
        long k = 0
        while k < count {
            if kinds[k] != K_CODE {
                k++
                continue
            }
            long second = next_code(k)
            long third = -1
            if second >= 0
                third = next_code(second)
            ; "cmpb #0" before a branch on zero only is "tstb"
            if second >= 0 and lengths[k] == 12 and buf.bytes_equal(src.data + starts[k], "    cmpb  #0", 12) and (is(second, "beq") or is(second, "bne")) {
                ; (and nothing at all after an instruction that left B's flags)
                long first = k - 1
                while first >= 0 and kinds[first] == K_GONE
                    first--
                if first >= 0 and kinds[first] == K_CODE and (is(first, "ldb") or is(first, "stb") or is(first, "addb") or is(first, "subb")
                        or is(first, "andb") or is(first, "orb") or is(first, "eorb") or is(first, "incb") or is(first, "decb")
                        or is(first, "negb") or is(first, "comb"))
                    kinds[k] = K_GONE
                else {
                    sys.memcopy("    tstb    ", src.data + starts[k], 12)
                    lengths[k] = 8
                }
            }
            ; "ldd Q / tfr d,x" before a call of a subroutine of the program, which takes
            ; nothing in D (a byte for it in B would be loaded after this), is "ldx Q"
            if third >= 0 and is(k, "ldd") and is(second, "tfr") and lengths[second] == 12 and buf.bytes_equal(src.data + starts[second] + 9, "d,x", 3)
                    and ((is(third, "jsr") and program_call(third)) or is(third, "ldb") or is(third, "lda")) {
                src.data[starts[k] + 6] = 'x'
                kinds[second] = K_GONE
            }
            ; "ldd Q / tfr d,x / ldd R" is "ldx Q / ldd R"
            else if third >= 0 and is(k, "ldd") and is(second, "tfr") and lengths[second] == 12 and buf.bytes_equal(src.data + starts[second] + 9, "d,x", 3)
                    and is(third, "ldd") {
                src.data[starts[k] + 6] = 'x'
                kinds[second] = K_GONE
            }
            ; a load, and then the same register is loaded again (after a load of D, one
            ; of A or B: the generator never takes the other half from what was there)
            ; (not when the second load goes through the register that the first loaded)
            else if second >= 0 and plain_load(k) and not through_register(second) and ((is(k, "ldd") and (is(second, "ldd") or is(second, "ldb") or is(second, "lda")))
                    or (is(k, "ldb") and (is(second, "ldb") or is(second, "ldd")))
                    or (is(k, "lda") and (is(second, "lda") or is(second, "ldd"))) or (is(k, "ldx") and is(second, "ldx")))
                kinds[k] = K_GONE
            ; a zero: cleared, where nothing takes the carry that the clearing clears
            if kinds[k] == K_CODE and second >= 0 and lengths[k] == 11 and (buf.bytes_equal(src.data + starts[k], "    ldb  #0", 11) or buf.bytes_equal(src.data + starts[k], "    lda  #0", 11))
                    and not reads_carry(second) {
                ubyte which = src.data[starts[k] + 6]
                sys.memcopy("    clr", src.data + starts[k], 7)
                src.data[starts[k] + 7] = which
                lengths[k] = 8
            }
            k++
        }
    }

    ; ---- stores that nothing reads ----

    ; the places that the subroutine names: where each name is in src, and whether a
    ; line reads it
    ^^long place_at = 0
    ^^uword place_len = 0
    ^^ubyte place_read = 0
    long place_cap = 0
    long place_count = 0

    sub place_index(long at, uword length) -> long {
        long k = 0
        while k < place_count {
            if place_len[k] == length and buf.bytes_equal(src.data + place_at[k], src.data + at, length)
                return k
            k++
        }
        if place_count >= place_cap {
            long bigger = place_cap * 2 + 256
            place_at = mem.grow(place_at, place_cap * sizeof(long), bigger * sizeof(long))
            place_len = mem.grow(place_len, place_cap * sizeof(uword), bigger * sizeof(uword))
            place_read = mem.grow(place_read, place_cap, bigger)
            place_cap = bigger
        }
        place_at[place_count] = at
        place_len[place_count] = length
        place_read[place_count] = 0
        place_count++
        return place_count - 1
    }

    ; is line k nothing but a store to a place (std, stb, sta, stx, stu, clr)?
    sub plain_store(long k) -> bool {
        if not (is(k, "std") or is(k, "stb") or is(k, "sta") or is(k, "stx") or is(k, "stu") or is(k, "clr"))
            return false
        operand(k)
        return is_place(operand_at, operand_len)
    }

    sub stores() {
        place_count = 0
        long k = 0
        while k < count {
            if kinds[k] == K_CODE or kinds[k] == K_ASM {
                bool store = kinds[k] == K_CODE and plain_store(k)
                ; every place the line names
                long p = starts[k]
                long stop = starts[k] + lengths[k]
                while p + 4 < stop {
                    if src.data[p] == 'p' and src.data[p + 1] == '8' and src.data[p + 2] == 'r' and src.data[p + 3] == '_' {
                        long q = p + 4
                        while q < stop and ((src.data[q] >= '0' and src.data[q] <= '9') or src.data[q] == '_')
                            q++
                        long at = place_index(p, (q - p) as uword)
                        if not store
                            place_read[at] = 1
                        p = q
                    }
                    else
                        p++
                }
            }
            k++
        }
        k = 0
        while k < count {
            if kinds[k] == K_CODE and plain_store(k) {
                long which = place_index(operand_at, base_len(operand_at, operand_len))
                long store_at = operand_at
                uword store_len = operand_len
                if (place_read[which] == 0 or overwritten(k, store_at, store_len)) and not reads_flags(k + 1)
                    kinds[k] = K_GONE
            }
            k++
        }
    }

    ; Is what line k stores to its place written over before anything can read it: does a
    ; store of the same register kind to the same operand come, with no line between
    ; that names the place, no label and no branch?  (A call is no reader: the places
    ; are this subroutine's own, and one that can be called again from inside saves
    ; them by reading them, which is a line that names them.)
    sub overwritten(long k, long at, uword length) -> bool {
        uword base = base_len(at, length)
        ubyte wide = src.data[starts[k] + 6]
        long j = k + 1
        while j < count {
            if kinds[j] == K_GONE {
                j++
                continue
            }
            if kinds[j] != K_CODE
                return false
            ^^ubyte t = src.data + starts[j] + 4
            if is(j, "rts") or is(j, "jmp") or (t[0] == 'b' and not is(j, "bita") and not is(j, "bitb") and not is(j, "bsr"))
                    or (t[0] == 'l' and t[1] == 'b' and not is(j, "lbsr"))
                return false
            ; does it name the place?
            long p = starts[j]
            long stop = starts[j] + lengths[j]
            bool names = false
            while p + base <= stop {
                if buf.bytes_equal(src.data + p, src.data + at, base) and (p + base == stop or src.data[p + base] < '0' or src.data[p + base] > '9') {
                    names = true
                    break
                }
                p++
            }
            if names {
                ; (the same store again: of a register as wide, to the same bytes)
                if plain_store(j) and not is(j, "clr") and src.data[starts[j] + 6] == wide and operand_len == length
                        and buf.bytes_equal(src.data + operand_at, src.data + at, length)
                    return wide != 'r'
                return false
            }
            j++
        }
        return false
    }

    ; a call and then the return: a jump
    sub calls() {
        long k = 0
        while k + 1 < count {
            if kinds[k] == K_CODE and kinds[k + 1] == K_CODE and is(k, "jsr") and is(k + 1, "rts") {
                operand(k)
                if operand_len != 0 and src.data[operand_at] != '[' and src.data[operand_at] != ',' {
                    src.data[starts[k] + 5] = 'm'
                    src.data[starts[k] + 6] = 'p'
                    kinds[k + 1] = K_GONE
                }
            }
            k++
        }
    }

    ; ---- the whole program: which branches are long ----

    ; How many bytes an instruction is at most, from how it is written: nothing after it
    ; 2 (most are 1), a constant 3, a place in memory 3, through a register up to 4 (with
    ; a 16-bit offset), and one more for the instructions with a first byte before
    ; their own; a branch as its long form.
    sub most_bytes(long k) -> long {
        operand(k)
        ^^ubyte t = src.data + starts[k] + 4
        long more = 0
        if is(k, "cmpd") or is(k, "cmpy") or is(k, "cmpu") or is(k, "cmps") or is(k, "ldy") or is(k, "sty") or is(k, "lds") or is(k, "sts")
            more = 1
        if operand_len == 0
            return 2
        if is(k, "tfr") or is(k, "exg") or is(k, "pshs") or is(k, "puls") or is(k, "andcc") or is(k, "orcc")
            return 2
        if t[0] == 'b' and lengths[k] > 7 and t[3] == ' ' and not is(k, "bit")
            return 4
        if src.data[operand_at] == '#'
            return 3 + more
        long q = operand_at
        while q < operand_at + operand_len {
            if src.data[q] == ',' or src.data[q] == '['
                return 4 + more
            q++
        }
        return 3 + more
    }

    ; is the label of this name within reach of the short branch in line k, with nothing
    ; but instructions between?  (127 bytes forward from the end of the branch, 128 back
    ; from there.)
    sub near(long k, long name_at, uword name_len) -> bool {
        long bytes = 0
        long j = k + 1
        while j < count and bytes <= 127 {
            if kinds[j] == K_CODE
                bytes += most_bytes(j)
            else if kinds[j] == K_ASM
                break
            else if is_label(j, name_at, name_len)
                return true
            else if not plain(j)
                break
            j++
        }
        bytes = 2
        j = k - 1
        while j >= 0 {
            if kinds[j] == K_CODE {
                bytes += most_bytes(j)
                if bytes > 128
                    break
            }
            else if kinds[j] == K_ASM
                break
            else if is_label(j, name_at, name_len)
                return true
            else if not plain(j)
                break
            j--
        }
        return false
    }

    ; is line j "name:"?
    sub is_label(long j, long name_at, uword name_len) -> bool {
        return lengths[j] == name_len + 1 and src.data[starts[j] + name_len] == ':'
            and buf.bytes_equal(src.data + starts[j], src.data + name_at, name_len)
    }

    ; a line that takes no room: empty, a comment, or a label by itself
    sub plain(long j) -> bool {
        if lengths[j] == 0 or src.data[starts[j]] == ';'
            return true
        return src.data[starts[j]] != ' ' and src.data[starts[j] + lengths[j] - 1] == ':'
    }

    sub branches(^^buf.Buf text) {
        split(text, 0)
        ^^buf.Buf result = buf.new(text.len + text.len / 16 + 64)
        long k = 0
        while k < count {
            ^^ubyte t = text.data + starts[k]
            bool long_form = false
            if kinds[k] == K_CODE and t[4] == 'b' and lengths[k] > 9 and t[7] == ' ' and not is(k, "bit") {
                operand(k)
                ; (a branch to a name: "*" and the like are left alone)
                ubyte first = text.data[operand_at]
                if (first == '_' or (first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z')) and not near(k, operand_at, operand_len)
                    long_form = true
            }
            if long_form {
                buf.add_str(result, "    l")
                buf.add_bytes(result, t + 4, lengths[k] - 4)
            }
            else
                buf.add_bytes(result, t, lengths[k])
            buf.add_byte(result, '\n')
            k++
        }
        text.len = 0
        buf.add_bytes(text, result.data, result.len)
    }
}
