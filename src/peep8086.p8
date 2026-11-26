; p8p8: a pass over the 8086 assembly, after the code generator.
;
; gen8086 gives every IR register a place in memory (p8r_S_N) and writes each instruction
; by itself: operands from their places into AL or AX, the result back to its place.
; Most of that traffic is not needed.  run() reads the lines of one subroutine and
;
; - follows what the registers hold of those places, of constants and of the program's
;   variables, and drops a load of what is there already;
; - where a register holds what an instruction reads from a place, or the place was
;   given the value of a constant, a variable or another place, has the instruction
;   read that instead;
; - then drops every store to a place that nothing reads any more;
; - and a few small things: a load that the next line loads over, a compare with 0
;   after the instruction that left the flags, a call before a return.
;
; The places belong to one subroutine, are never reached through a pointer, and are no
; machine's memory-mapped anything, so what is known of one stays true until a line that
; this pass can see changes it.  A variable can be changed through a pointer: what is
; known of variables is forgotten at every write to memory that is not a place and not
; a variable by its name.  A variable at a fixed address (memory-mapped: gen8086 lists
; them in "volatile") is not followed at all, and a place that stands for a variable is
; read as the variable once only, so the program reads its variables as often as it
; did.  A label and anything this pass does not know forget everything; a call forgets
; the registers and the variables.  Assembly of the program's own (%asm) is between
; two marker lines and is left as it stands.
;
; The 8086's "mov" changes no flag, so a load or a store can go wherever nothing
; needs its value.

%import buf
%import mem

peep8086 {
    %option ignore_unused

    ^^buf.Buf pool = 0              ; the lines' text: the subroutine as it came, then the lines written anew
    ^^long starts = 0               ; per line: where it begins in pool
    ^^uword lengths = 0
    ^^ubyte kinds = 0
    long capacity = 0
    long count = 0
    ^^buf.Buf volatile = 0          ; names of memory-mapped variables, each between line ends (gen8086 fills it)

    const ubyte K_OTHER = 0         ; a label, a comment, a directive, an empty line
    const ubyte K_CODE = 1          ; an instruction
    const ubyte K_ASM = 2           ; a line of the program's own assembly
    const ubyte K_GONE = 3          ; dropped

    ; ---- the lines ----

    sub split(^^buf.Buf text, long from) {
        if pool == 0
            pool = buf.new(65536)
        buf.clear(pool)
        buf.add_bytes(pool, text.data + from, text.len - from)
        count = 0
        long p = 0
        bool in_asm = false
        while p < pool.len {
            long begin = p
            while p < pool.len and pool.data[p] != '\n'
                p++
            if count >= capacity {
                long bigger = capacity * 2 + 1024
                starts = mem.grow(starts, capacity * sizeof(long), bigger * sizeof(long))
                lengths = mem.grow(lengths, capacity * sizeof(uword), bigger * sizeof(uword))
                kinds = mem.grow(kinds, capacity, bigger)
                capacity = bigger
            }
            starts[count] = begin
            lengths[count] = (p - begin) as uword
            ubyte kind = K_OTHER
            if p - begin == 5 and buf.bytes_equal(pool.data + begin, ";%asm", 5) {
                in_asm = true
                kind = K_ASM
            }
            else if p - begin == 5 and buf.bytes_equal(pool.data + begin, ";%end", 5) {
                in_asm = false
                kind = K_ASM
            }
            else if in_asm
                kind = K_ASM
            else if p - begin > 4 and pool.data[begin] == ' ' and pool.data[begin + 4] != ' ' and pool.data[begin + 4] != ';'
                kind = K_CODE
            kinds[count] = kind
            ; (a directive is no instruction)
            if kind == K_CODE and (is(count, "db") or is(count, "dw") or is(count, "dd") or is(count, "times") or is(count, "resb")
                    or is(count, "org") or is(count, "align") or is(count, "alignb") or is(count, "cpu") or is(count, "bits")
                    or is(count, "absolute"))
                kinds[count] = K_OTHER
            ; (a label with something after it on its line)
            if kind == K_CODE {
                long q = begin + 4
                while q < p and pool.data[q] != ' ' and pool.data[q] != ':'
                    q++
                if q < p and pool.data[q] == ':'
                    kinds[count] = K_OTHER
            }
            count++
            p++
        }
    }

    ; the text after position from becomes the lines that are left
    sub join(^^buf.Buf text, long from) {
        text.len = from
        long k = 0
        while k < count {
            if kinds[k] != K_GONE {
                buf.add_bytes(text, pool.data + starts[k], lengths[k])
                buf.add_byte(text, '\n')
            }
            k++
        }
    }

    ; is the mnemonic of line k this one?
    sub is(long k, str mnemonic) -> bool {
        ^^ubyte t = pool.data + starts[k] + 4
        long n = lengths[k] - 4
        long m = 0
        while mnemonic[m] != 0 {
            if m >= n or t[m] != mnemonic[m]
                return false
            m++
        }
        return m == n or t[m] == ' '
    }

    ; ---- a line's parts ----

    long m_at                       ; the mnemonic
    uword m_len
    long a_at                       ; the first operand (length 0: none)
    uword a_len
    long b_at                       ; the second operand
    uword b_len

    sub parse(long k) {
        long p = starts[k] + 4
        long stop = starts[k] + lengths[k]
        m_at = p
        while p < stop and pool.data[p] != ' '
            p++
        m_len = (p - m_at) as uword
        while p < stop and pool.data[p] == ' '
            p++
        a_at = p
        while p < stop and pool.data[p] != ','
            p++
        a_len = (p - a_at) as uword
        b_at = p
        b_len = 0
        if p < stop {
            p++
            while p < stop and pool.data[p] == ' '
                p++
            b_at = p
            b_len = (stop - p) as uword
        }
    }

    sub mnemonic_is(str text) -> bool {
        uword n = 0
        while text[n] != 0 {
            if n >= m_len or pool.data[m_at + n] != text[n]
                return false
            n++
        }
        return n == m_len
    }

    ; What an operand is: a register (its number below), memory (a width and the text
    ; between the brackets), or a constant.
    const ubyte O_NONE = 0
    const ubyte O_REG = 1
    const ubyte O_MEM = 2
    const ubyte O_CONST = 3
    ubyte o_kind
    ubyte o_reg                     ; O_REG: which
    ubyte o_width                   ; O_MEM: 1 or 2 (0: not said); O_REG: the register's
    long o_at                       ; O_MEM: the text between the brackets; O_CONST: the text
    uword o_len

    ; The registers: 0-3 AX BX CX DX, 4 SI, 5 DI, 6-9 AL BL CL DL, 10-13 AH BH CH DH,
    ; 14 another one (BP, SP, a segment register).  What 0 to 9 hold is followed.
    const ubyte R_AX = 0
    const ubyte R_BX = 1
    const ubyte R_CX = 2
    const ubyte R_DX = 3
    const ubyte R_SI = 4
    const ubyte R_DI = 5
    const ubyte R_AL = 6
    const ubyte R_AH = 10
    const ubyte R_OTHER = 14
    const ubyte TRACKED = 10

    sub register_number(long at, uword length) -> ubyte {
        if length != 2
            return 255
        ubyte first = pool.data[at]
        ubyte second = pool.data[at + 1]
        ubyte letter = 255
        when first {
            'a' -> letter = 0
            'b' -> letter = 1
            'c' -> letter = 2
            'd' -> letter = 3
        }
        if letter != 255 {
            when second {
                'x' -> return letter
                'l' -> return 6 + letter
                'h' -> return 10 + letter
            }
        }
        if first == 's' and second == 'i'
            return R_SI
        if first == 'd' and second == 'i'
            return R_DI
        if (first == 'b' or first == 's') and second == 'p'
            return R_OTHER
        if (first == 'c' or first == 'd' or first == 'e' or first == 's') and second == 's'
            return R_OTHER
        return 255
    }

    sub classify(long at, uword length) {
        o_kind = O_NONE
        o_width = 0
        o_at = at
        o_len = length
        if length == 0
            return
        ubyte r = register_number(at, length)
        if r != 255 {
            o_kind = O_REG
            o_reg = r
            o_width = 2
            if r >= 6 and r < 14
                o_width = 1
            return
        }
        if pool.data[at + length - 1] == ']' {
            o_kind = O_MEM
            if length > 7 and buf.bytes_equal(pool.data + at, "byte [", 6) {
                o_width = 1
                o_at = at + 6
                o_len = length - 7
            }
            else if length > 7 and buf.bytes_equal(pool.data + at, "word [", 6) {
                o_width = 2
                o_at = at + 6
                o_len = length - 7
            }
            else if pool.data[at] == '[' {
                o_at = at + 1
                o_len = length - 2
            }
            else
                o_kind = O_CONST        ; (not as the generator writes memory)
            return
        }
        o_kind = O_CONST
    }

    ; ---- memory by its name ----

    sub is_place(long at, uword length) -> bool {
        return length > 4 and buf.bytes_equal(pool.data + at, "p8r_", 4)
    }

    ; memory that has a name (a variable, or a place of the generator's own) and is not
    ; reached through a register; not a memory-mapped variable
    sub is_named(long at, uword length) -> bool {
        if length < 2
            return false
        ubyte first = pool.data[at]
        if first != '_' and not (first == 'p' and pool.data[at + 1] == '8')
            return false
        uword n = 0
        while n < length {
            ubyte c = pool.data[at + n]
            if c == '-' or c == '*' or c == ':' or c == ' '
                return false
            n++
        }
        if volatile == 0 or is_place(at, length)
            return true
        ; (its name without the offset, between two line ends in the list)
        uword name_len = base_len(at, length)
        long p = 0
        while p + name_len + 1 < volatile.len {
            if volatile.data[p] == '\n' and volatile.data[p + name_len + 1] == '\n'
                    and buf.bytes_equal(volatile.data + p + 1, pool.data + at, name_len)
                return false
            p++
        }
        return true
    }

    ; how long a name is without its offset
    sub base_len(long at, uword length) -> uword {
        uword n = 0
        while n < length and pool.data[at + n] != '+'
            n++
        return n
    }

    sub offset_of(long at, uword length) -> long {
        uword n = base_len(at, length)
        long value = 0
        n++
        while n < length and pool.data[at + n] >= '0' and pool.data[at + n] <= '9' {
            value = value * 10 + (pool.data[at + n] - '0')
            n++
        }
        return value
    }

    ; do the two pieces of named memory share a byte?  (A width of 0 is taken as 4.)
    sub overlap(long a, uword a_length, ubyte a_width, long b, uword b_length, ubyte b_width) -> bool {
        uword an = base_len(a, a_length)
        if an != base_len(b, b_length) or not buf.bytes_equal(pool.data + a, pool.data + b, an)
            return false
        long a_from = offset_of(a, a_length)
        long b_from = offset_of(b, b_length)
        if a_width == 0
            a_width = 4
        if b_width == 0
            b_width = 4
        return a_from < b_from + b_width and b_from < a_from + a_width
    }

    ; ---- what is known ----

    ; what the registers 0 to 9 hold: memory by its name (H_MEM, the text between the
    ; brackets) or a constant (H_CONST, its text); the width is the register's
    const ubyte H_NONE = 0
    const ubyte H_MEM = 1
    const ubyte H_CONST = 2
    ubyte[TRACKED] held_kind
    long[TRACKED] held_at
    uword[TRACKED] held_len

    ; places that hold what something else holds
    const ubyte EQUALS = 16
    long[EQUALS] eq_place_at
    uword[EQUALS] eq_place_len      ; 0: free
    ubyte[EQUALS] eq_width
    ubyte[EQUALS] eq_kind           ; H_MEM or H_CONST
    long[EQUALS] eq_other_at
    uword[EQUALS] eq_other_len
    ubyte eq_next = 0

    sub width_of(ubyte r) -> ubyte {
        if r >= 6
            return 1
        return 2
    }

    sub forget_registers() {
        ubyte r
        for r in 0 to TRACKED - 1
            held_kind[r] = H_NONE
    }

    sub forget() {
        forget_registers()
        ubyte e
        for e in 0 to EQUALS - 1
            eq_place_len[e] = 0
    }

    ; a register gets another value: it, and what it is a part of or has as a part
    sub kill(ubyte r) {
        if r < 4 {
            held_kind[r] = H_NONE
            held_kind[r + 6] = H_NONE
        }
        else if r < 6
            held_kind[r] = H_NONE
        else if r < 10 {
            held_kind[r] = H_NONE
            held_kind[r - 6] = H_NONE
        }
        else if r < 14
            held_kind[r - 10] = H_NONE
    }

    ; named memory was written (width bytes at this name): what holds a part of it is
    ; not known any more
    sub written(long at, uword length, ubyte width) {
        ubyte r
        for r in 0 to TRACKED - 1 {
            if held_kind[r] == H_MEM and overlap(held_at[r], held_len[r], width_of(r), at, length, width)
                held_kind[r] = H_NONE
        }
        ubyte e
        for e in 0 to EQUALS - 1 {
            if eq_place_len[e] != 0 and (overlap(eq_place_at[e], eq_place_len[e], eq_width[e], at, length, width)
                    or (eq_kind[e] == H_MEM and overlap(eq_other_at[e], eq_other_len[e], eq_width[e], at, length, width)))
                eq_place_len[e] = 0
        }
    }

    ; memory was written through a register or at an address: any variable may have
    ; changed (not a place)
    sub variables_changed() {
        ubyte r
        for r in 0 to TRACKED - 1 {
            if held_kind[r] == H_MEM and not is_place(held_at[r], held_len[r])
                held_kind[r] = H_NONE
        }
        ubyte e
        for e in 0 to EQUALS - 1 {
            if eq_place_len[e] != 0 and eq_kind[e] == H_MEM and not is_place(eq_other_at[e], eq_other_len[e])
                eq_place_len[e] = 0
        }
    }

    ; A call: the registers hold something else after it, and any variable may; but a
    ; place is the subroutine's own (one that can be called again from inside is saved
    ; around the call), so what a place is known to hold of a constant or of another
    ; place stays.
    sub called() {
        forget_registers()
        variables_changed()
    }

    ; the destination of an instruction has changed (the operand as classify left it)
    sub destination_changed() {
        when o_kind {
            O_REG -> kill(o_reg)
            O_MEM -> {
                if is_named(o_at, o_len)
                    written(o_at, o_len, o_width)
                else
                    variables_changed()
            }
            else -> forget()
        }
    }

    sub equal(long place, uword place_length, ubyte width, ubyte kind, long other, uword other_length) {
        eq_place_at[eq_next] = place
        eq_place_len[eq_next] = place_length
        eq_width[eq_next] = width
        eq_kind[eq_next] = kind
        eq_other_at[eq_next] = other
        eq_other_len[eq_next] = other_length
        eq_next++
        if eq_next == EQUALS
            eq_next = 0
    }

    ; what the place holds too, read with this width: its number in the list, or 255
    sub equal_of(long at, uword length, ubyte width) -> ubyte {
        ubyte e
        for e in 0 to EQUALS - 1 {
            if eq_place_len[e] == length and eq_width[e] == width and buf.bytes_equal(pool.data + eq_place_at[e], pool.data + at, length)
                return e
        }
        return 255
    }

    ; the register of this width that holds this memory, or 255
    sub holder(long at, uword length, ubyte width) -> ubyte {
        ubyte r
        for r in 0 to TRACKED - 1 {
            if held_kind[r] == H_MEM and width_of(r) == width and held_len[r] == length and buf.bytes_equal(pool.data + held_at[r], pool.data + at, length)
                return r
        }
        return 255
    }

    sub register_name(ubyte r) -> str {
        when r {
            0 -> return "ax"
            1 -> return "bx"
            2 -> return "cx"
            3 -> return "dx"
            4 -> return "si"
            5 -> return "di"
            6 -> return "al"
            7 -> return "bl"
            8 -> return "cl"
        }
        return "dl"
    }

    ; ---- lines written anew ----

    ; What an operand of the line becomes: as it is (S_SAME), a register, a constant's
    ; text, or other memory of the same width.
    const ubyte S_SAME = 0
    const ubyte S_REG = 1
    const ubyte S_CONST = 2
    const ubyte S_MEM = 3
    ubyte sa_kind
    ubyte sa_reg
    long sa_at
    uword sa_len
    ubyte sb_kind
    ubyte sb_reg
    long sb_at
    uword sb_len

    sub add_operand(ubyte kind, ubyte r, long at, uword length, ubyte width, long old_at, uword old_len) {
        when kind {
            S_REG -> buf.add_str(pool, register_name(r))
            S_CONST -> buf.add_bytes(pool, pool.data + at, length)
            S_MEM -> {
                if width == 1
                    buf.add_str(pool, "byte [")
                else
                    buf.add_str(pool, "word [")
                buf.add_bytes(pool, pool.data + at, length)
                buf.add_byte(pool, ']')
            }
            else -> buf.add_bytes(pool, pool.data + old_at, old_len)
        }
    }

    ; line k again, with the operands that sa_ and sb_ say (the widths are those of the
    ; memory operands they stand for)
    sub rewrite(long k, ubyte a_width, ubyte b_width) {
        buf.reserve(pool, lengths[k] + 64)
        long begin = pool.len
        buf.add_str(pool, "    ")
        buf.add_bytes(pool, pool.data + m_at, m_len)
        buf.add_str(pool, "  ")
        add_operand(sa_kind, sa_reg, sa_at, sa_len, a_width, a_at, a_len)
        if b_len != 0 {
            buf.add_str(pool, ", ")
            add_operand(sb_kind, sb_reg, sb_at, sb_len, b_width, b_at, b_len)
        }
        starts[k] = begin
        lengths[k] = (pool.len - begin) as uword
        parse(k)
    }

    ; What can be read in place of the memory operand that classify just found (a
    ; place): the register that holds it, or what the place is known to hold.  A
    ; constant only where the instruction can take one, other memory only where the
    ; other operand is no memory.  Sets the kind (S_SAME: nothing).
    ubyte found_kind
    ubyte found_reg
    long found_at
    uword found_len

    sub instead(bool constant_fits, bool memory_fits) {
        found_kind = S_SAME
        if o_kind != O_MEM or o_width == 0 or not is_place(o_at, o_len)
            return
        ubyte r = holder(o_at, o_len, o_width)
        if r != 255 {
            found_kind = S_REG
            found_reg = r
            return
        }
        ubyte e = equal_of(o_at, o_len, o_width)
        if e == 255
            return
        if eq_kind[e] == H_CONST {
            if constant_fits {
                found_kind = S_CONST
                found_at = eq_other_at[e]
                found_len = eq_other_len[e]
            }
            return
        }
        if memory_fits {
            ; (the register that holds that other memory, when one does)
            r = holder(eq_other_at[e], eq_other_len[e], o_width)
            if r != 255 {
                found_kind = S_REG
                found_reg = r
                return
            }
            found_kind = S_MEM
            found_at = eq_other_at[e]
            found_len = eq_other_len[e]
            ; (a variable is read once for each time the program read it)
            if not is_place(found_at, found_len)
                eq_place_len[e] = 0
        }
    }

    ; ---- one subroutine ----

    sub run(^^buf.Buf text, long from) {
        ; (twice: what the first round takes out lets the second see more)
        repeat 2 {
            split(text, from)
            loads()
            join(text, from)
            split(text, from)
            stores()
            join(text, from)
            split(text, from)
            small()
            join(text, from)
        }
    }

    ; loads of what is there already, and operands that can be read from elsewhere
    sub loads() {
        forget()
        long k = 0
        while k < count {
            if kinds[k] != K_CODE {
                if kinds[k] != K_GONE
                    forget()
                k++
                continue
            }
            parse(k)
            line(k)
            k++
        }
    }

    sub line(long k) {
        ubyte a_kind
        ubyte a_reg
        ubyte a_width
        long a_inner
        uword a_inner_len
        sa_kind = S_SAME
        sb_kind = S_SAME
        if mnemonic_is("mov") {
            classify(a_at, a_len)
            a_kind = o_kind
            a_reg = o_reg
            a_width = o_width
            a_inner = o_at
            a_inner_len = o_len
            if a_kind == O_REG {
                classify(b_at, b_len)
                if a_reg >= TRACKED {
                    kill(a_reg)
                    return
                }
                ; what is there already
                if o_kind == O_MEM and held_kind[a_reg] == H_MEM and held_len[a_reg] == o_len and buf.bytes_equal(pool.data + held_at[a_reg], pool.data + o_at, o_len) {
                    kinds[k] = K_GONE
                    return
                }
                if o_kind == O_CONST and held_kind[a_reg] == H_CONST and held_len[a_reg] == o_len and buf.bytes_equal(pool.data + held_at[a_reg], pool.data + o_at, o_len) {
                    kinds[k] = K_GONE
                    return
                }
                if o_kind == O_REG and o_reg == a_reg {
                    kinds[k] = K_GONE
                    return
                }
                instead(true, true)
                if found_kind != S_SAME {
                    if found_kind == S_REG and found_reg == a_reg {
                        kinds[k] = K_GONE
                        return
                    }
                    sb_kind = found_kind
                    sb_reg = found_reg
                    sb_at = found_at
                    sb_len = found_len
                    rewrite(k, 0, a_width)
                    classify(b_at, b_len)
                }
                ; what the register holds now
                ubyte kind = H_NONE
                long at = 0
                uword length = 0
                when o_kind {
                    O_MEM -> {
                        if is_named(o_at, o_len) {
                            kind = H_MEM
                            at = o_at
                            length = o_len
                        }
                    }
                    O_CONST -> {
                        kind = H_CONST
                        at = o_at
                        length = o_len
                    }
                    O_REG -> {
                        if o_reg < TRACKED {
                            kind = held_kind[o_reg]
                            at = held_at[o_reg]
                            length = held_len[o_reg]
                        }
                    }
                }
                kill(a_reg)
                held_kind[a_reg] = kind
                held_at[a_reg] = at
                held_len[a_reg] = length
                ; (the low half of a word from memory is the byte there)
                if a_reg < 4 and kind == H_MEM {
                    held_kind[a_reg + 6] = H_MEM
                    held_at[a_reg + 6] = at
                    held_len[a_reg + 6] = length
                }
                return
            }
            if a_kind == O_MEM {
                classify(b_at, b_len)
                ubyte source_kind = H_NONE
                long source_at = 0
                uword source_len = 0
                ubyte source_reg = 255
                if o_kind == O_REG and o_reg < TRACKED {
                    source_reg = o_reg
                    source_kind = held_kind[o_reg]
                    source_at = held_at[o_reg]
                    source_len = held_len[o_reg]
                }
                else if o_kind == O_CONST {
                    source_kind = H_CONST
                    source_at = o_at
                    source_len = o_len
                }
                if not is_named(a_inner, a_inner_len) {
                    variables_changed()
                    return
                }
                if a_width == 0 and source_reg != 255
                    a_width = width_of(source_reg)
                bool place = is_place(a_inner, a_inner_len)
                written(a_inner, a_inner_len, a_width)
                if place and a_width != 0 and source_kind != H_NONE
                        and not (source_kind == H_MEM and overlap(source_at, source_len, a_width, a_inner, a_inner_len, a_width))
                    equal(a_inner, a_inner_len, a_width, source_kind, source_at, source_len)
                if source_reg != 255 and (place or held_kind[source_reg] == H_NONE) {
                    ; (the register holds the place too now; what it is known to hold of
                    ; a variable stays when the store is to another variable)
                    held_kind[source_reg] = H_MEM
                    held_at[source_reg] = a_inner
                    held_len[source_reg] = a_inner_len
                    if source_reg < 4 {
                        held_kind[source_reg + 6] = H_MEM
                        held_at[source_reg + 6] = a_inner
                        held_len[source_reg + 6] = a_inner_len
                    }
                }
                return
            }
            forget()
            return
        }
        if mnemonic_is("cmp") or mnemonic_is("test") {
            ; (nothing changes; either operand may be read from elsewhere)
            classify(b_at, b_len)
            ubyte b_kind = o_kind
            classify(a_at, a_len)
            a_kind = o_kind
            a_width = o_width
            if a_kind == O_MEM {
                instead(false, b_kind != O_MEM)
                if found_kind != S_SAME {
                    sa_kind = found_kind
                    sa_reg = found_reg
                    sa_at = found_at
                    sa_len = found_len
                    rewrite(k, a_width, 0)
                }
                return
            }
            if a_kind == O_REG {
                classify(b_at, b_len)
                ubyte bw = o_width
                instead(true, true)
                if found_kind != S_SAME {
                    sb_kind = found_kind
                    sb_reg = found_reg
                    sb_at = found_at
                    sb_len = found_len
                    rewrite(k, 0, bw)
                }
            }
            return
        }
        if mnemonic_is("add") or mnemonic_is("adc") or mnemonic_is("sub") or mnemonic_is("sbb") or mnemonic_is("and")
                or mnemonic_is("or") or mnemonic_is("xor") {
            classify(a_at, a_len)
            a_kind = o_kind
            if a_kind == O_REG {
                classify(b_at, b_len)
                ubyte bw2 = o_width
                instead(true, true)
                if found_kind != S_SAME {
                    sb_kind = found_kind
                    sb_reg = found_reg
                    sb_at = found_at
                    sb_len = found_len
                    rewrite(k, 0, bw2)
                }
            }
            classify(a_at, a_len)
            destination_changed()
            return
        }
        if mnemonic_is("inc") or mnemonic_is("dec") or mnemonic_is("neg") or mnemonic_is("not") or mnemonic_is("shl")
                or mnemonic_is("shr") or mnemonic_is("sar") or mnemonic_is("rol") or mnemonic_is("ror") or mnemonic_is("rcl")
                or mnemonic_is("rcr") or mnemonic_is("pop") {
            classify(a_at, a_len)
            destination_changed()
            return
        }
        if mnemonic_is("mul") or mnemonic_is("imul") or mnemonic_is("div") or mnemonic_is("idiv") or mnemonic_is("push") {
            classify(a_at, a_len)
            a_width = o_width
            instead(false, true)
            if found_kind != S_SAME {
                sa_kind = found_kind
                sa_reg = found_reg
                sa_at = found_at
                sa_len = found_len
                rewrite(k, a_width, 0)
            }
            if not mnemonic_is("push") {
                kill(R_AX)
                kill(R_DX)
            }
            return
        }
        if mnemonic_is("cbw") or mnemonic_is("lahf") {
            kill(R_AH)
            return
        }
        if mnemonic_is("cwd") {
            kill(R_DX)
            return
        }
        if mnemonic_is("sahf") or mnemonic_is("clc") or mnemonic_is("stc") or mnemonic_is("cmc") or mnemonic_is("cld")
                or mnemonic_is("std") or mnemonic_is("cli") or mnemonic_is("sti") or mnemonic_is("pushf") or mnemonic_is("popf")
                or mnemonic_is("nop") or mnemonic_is("jcxz")
            return
        if mnemonic_is("loop") {
            kill(R_CX)
            return
        }
        if mnemonic_is("call") or mnemonic_is("int") {
            ; (a float routine writes where DI points, which may be a place)
            if a_len > 4 and buf.bytes_equal(pool.data + a_at, "p8f_", 4)
                forget()
            else
                called()
            return
        }
        if m_len >= 2 and pool.data[m_at] == 'j' and not mnemonic_is("jmp")
            return                      ; (a conditional jump: what is known goes on)
        forget()
    }

    ; ---- stores that nothing reads ----

    ; the places that the subroutine names: where each name is in pool, and whether a
    ; line reads it
    ^^long place_at = 0
    ^^uword place_len = 0
    ^^ubyte place_read = 0
    long place_cap = 0
    long place_count = 0

    sub place_index(long at, uword length) -> long {
        long k = 0
        while k < place_count {
            if place_len[k] == length and buf.bytes_equal(pool.data + place_at[k], pool.data + at, length)
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

    ; Is line k nothing but a store to a place ("mov" of a register or a constant to
    ; it)?  Leaves the place as classify gives it.
    sub plain_store(long k) -> bool {
        if not is(k, "mov")
            return false
        parse(k)
        classify(b_at, b_len)
        if o_kind == O_MEM
            return false
        classify(a_at, a_len)
        return o_kind == O_MEM and is_place(o_at, o_len)
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
                    if pool.data[p] == 'p' and pool.data[p + 1] == '8' and pool.data[p + 2] == 'r' and pool.data[p + 3] == '_' {
                        long q = p + 4
                        while q < stop and ((pool.data[q] >= '0' and pool.data[q] <= '9') or pool.data[q] == '_')
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
                long which = place_index(o_at, base_len(o_at, o_len))
                if place_read[which] == 0 or overwritten(k)
                    kinds[k] = K_GONE
            }
            k++
        }
    }

    ; Is what line k stores to its place written over before anything can read it: does
    ; the same store (to the same bytes) come, with no line between that names the
    ; place, no label and no jump?  (A call is no reader: the places are this
    ; subroutine's own, and one that can be called again from inside saves them by
    ; reading them, which is a line that names them.)
    sub overwritten(long k) -> bool {
        long at = a_at
        uword length = a_len
        uword base = base_len(o_at, o_len)
        long name_at = o_at
        long j = k + 1
        while j < count {
            if kinds[j] == K_GONE {
                j++
                continue
            }
            if kinds[j] != K_CODE
                return false
            if is(j, "ret") or pool.data[starts[j] + 4] == 'j' or is(j, "loop")
                return false
            ; does it name the place?
            long p = starts[j]
            long stop = starts[j] + lengths[j]
            bool names = false
            while p + base <= stop {
                if buf.bytes_equal(pool.data + p, pool.data + name_at, base) and (p + base == stop or pool.data[p + base] < '0' or pool.data[p + base] > '9') {
                    names = true
                    break
                }
                p++
            }
            if names {
                if plain_store(j) and a_len == length and buf.bytes_equal(pool.data + a_at, pool.data + at, length)
                    return true
                return false
            }
            j++
        }
        return false
    }

    ; ---- small things ----

    ; the instruction after line k when nothing but dropped lines is between, or -1
    sub next_code(long k) -> long {
        k++
        while k < count and kinds[k] == K_GONE
            k++
        if k < count and kinds[k] == K_CODE
            return k
        return -1
    }

    sub previous_code(long k) -> long {
        k--
        while k >= 0 and kinds[k] == K_GONE
            k--
        if k >= 0 and kinds[k] == K_CODE
            return k
        return -1
    }

    ; does the text of length bytes at at name the register r, or a part of it, or what
    ; it is a part of?
    sub mentions(long at, uword length, ubyte r) -> bool {
        long p = at
        while p + 1 < at + length {
            ubyte other = register_number(p, 2)
            if other != 255 and (p == at or not is_word_char(pool.data[p - 1])) and (p + 2 == at + length or not is_word_char(pool.data[p + 2])) {
                if other == r
                    return true
                if r < 4 and (other == r + 6 or other == r + 10)
                    return true
                if r >= 6 and r < 10 and other == r - 6
                    return true
                if r >= 10 and r < 14 and other == r - 10
                    return true
            }
            p++
        }
        return false
    }

    sub is_word_char(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
    }

    ; are the flags that line k would change needed by nothing: does an instruction that
    ; sets them all come before anything can read them?
    sub flags_free(long k) -> bool {
        long j = next_code(k)
        while j >= 0 {
            if is(j, "mov") or is(j, "push") or is(j, "pop") {
                j = next_code(j)
                continue
            }
            return is(j, "add") or is(j, "sub") or is(j, "and") or is(j, "or") or is(j, "xor") or is(j, "cmp") or is(j, "test") or is(j, "neg")
        }
        return false
    }

    ; Does the register r, loaded in line k, get another value before anything reads
    ; it?  The lines after k, as long as they are instructions that do not name it: a
    ; "mov" into it (or into what it is a part of) from something that does not name
    ; it ends the search with yes.  For AX, BX, CX and DX the two halves may go one
    ; after the other ("mov al, .." and then "xor ah, ah" or "cbw").  A jump, a call, a
    ; return, a label and anything else that names it say no.
    sub never_read(long k, ubyte r) -> bool {
        bool low_gone = false
        ubyte whole = r
        if r >= 6
            whole = r - 6
        long j = next_code(k)
        while j >= 0 {
            parse(j)
            if pool.data[m_at] == 'j' or mnemonic_is("call") or mnemonic_is("ret") or mnemonic_is("int") or mnemonic_is("loop")
                    or (m_len >= 3 and pool.data[m_at] == 'r' and pool.data[m_at + 1] == 'e' and pool.data[m_at + 2] == 'p')
                    or mnemonic_is("mul") or mnemonic_is("imul") or mnemonic_is("div") or mnemonic_is("idiv")
                    or mnemonic_is("lodsb") or mnemonic_is("lodsw") or mnemonic_is("stosb") or mnemonic_is("stosw")
                    or mnemonic_is("movsb") or mnemonic_is("movsw") or mnemonic_is("scasb") or mnemonic_is("scasw")
                    or mnemonic_is("cmpsb") or mnemonic_is("cmpsw") or mnemonic_is("in") or mnemonic_is("out")
                    or mnemonic_is("cbw") or mnemonic_is("cwd") or mnemonic_is("lahf") or mnemonic_is("sahf") or mnemonic_is("xlat") {
                ; (instructions that use registers without naming them)
                if mnemonic_is("cbw") and whole == R_AX and r < 4 and low_gone
                    return true
                return false
            }
            if mnemonic_is("mov") {
                classify(a_at, a_len)
                if o_kind == O_REG and not mentions(b_at, b_len, whole) {
                    if o_reg == whole
                        return true
                    if o_reg == whole + 6 {
                        if r >= 6
                            return true
                        low_gone = true
                        j = next_code(j)
                        continue
                    }
                }
            }
            if r < 4 and low_gone and mnemonic_is("xor") and a_len == 2 and b_len == 2 and pool.data[a_at + 1] == 'h' and pool.data[b_at + 1] == 'h'
                    and register_number(a_at, 2) == whole + 10 and register_number(b_at, 2) == whole + 10
                return true
            if mentions(a_at, a_len, whole) or mentions(b_at, b_len, whole)
                return false
            j = next_code(j)
        }
        return false
    }

    sub replace_line(long k, str head, long tail_at, uword tail_len) {
        buf.reserve(pool, tail_len + 64)
        long begin = pool.len
        buf.add_str(pool, head)
        buf.add_bytes(pool, pool.data + tail_at, tail_len)
        starts[k] = begin
        lengths[k] = (pool.len - begin) as uword
    }

    sub small() {
        long k = 0
        while k < count {
            if kinds[k] != K_CODE {
                k++
                continue
            }
            long second = next_code(k)
            parse(k)
            ; what comes after a return or a jump, up to the next label, is never run
            if mnemonic_is("ret") or mnemonic_is("jmp") {
                long j = k + 1
                while j < count and (kinds[j] == K_CODE or kinds[j] == K_GONE) {
                    kinds[j] = K_GONE
                    j++
                }
                k++
                continue
            }
            ; a call and then the return: a jump
            if mnemonic_is("call") and second >= 0 and is(second, "ret") and lengths[second] == 7 {
                replace_line(k, "    jmp  ", a_at, a_len)
                kinds[second] = K_GONE
                continue                ; (this line again: what follows it is never run)
            }
            ; "mov P, ax / mov ax, Q / add ax, P" is "add ax, Q" (and the same for AL, and
            ; for and, or, xor): the sum does not mind which comes first
            if mnemonic_is("mov") and b_len == 2 and pool.data[b_at] == 'a' and (pool.data[b_at + 1] == 'x' or pool.data[b_at + 1] == 'l') and second >= 0 {
                classify(a_at, a_len)
                long sum_third = next_code(second)
                if o_kind == O_MEM and is_place(o_at, o_len) and sum_third >= 0 and is(second, "mov")
                        and (is(sum_third, "add") or is(sum_third, "and") or is(sum_third, "or") or is(sum_third, "xor")) {
                    long p_at = a_at
                    uword p_len = a_len
                    ubyte half = pool.data[b_at + 1]
                    parse(second)
                    long q_at = b_at
                    uword q_len = b_len
                    classify(b_at, b_len)
                    bool q_plain = o_kind == O_CONST or (o_kind == O_MEM and is_named(o_at, o_len))
                    bool same_acc = a_len == 2 and pool.data[a_at] == 'a' and pool.data[a_at + 1] == half
                    parse(sum_third)
                    if q_plain and same_acc and a_len == 2 and pool.data[a_at] == 'a' and pool.data[a_at + 1] == half
                            and b_len == p_len and buf.bytes_equal(pool.data + b_at, pool.data + p_at, p_len) {
                        buf.reserve(pool, q_len + 32)
                        long begin5 = pool.len
                        buf.add_str(pool, "    ")
                        buf.add_bytes(pool, pool.data + m_at, m_len)
                        buf.add_str(pool, "  a")
                        buf.add_byte(pool, half)
                        buf.add_str(pool, ", ")
                        buf.add_bytes(pool, pool.data + q_at, q_len)
                        starts[sum_third] = begin5
                        lengths[sum_third] = (pool.len - begin5) as uword
                        kinds[second] = K_GONE
                    }
                }
                parse(k)
            }
            ; a load of a register that gets another value before anything reads it
            if mnemonic_is("mov") {
                classify(a_at, a_len)
                if o_kind == O_REG and o_reg < 10 {
                    ubyte loaded = o_reg
                    classify(b_at, b_len)
                    if (o_kind == O_CONST or o_kind == O_REG or (o_kind == O_MEM and is_named(o_at, o_len))) and never_read(k, loaded) {
                        kinds[k] = K_GONE
                        k++
                        continue
                    }
                }
                parse(k)
            }
            ; a conditional jump over a jump: the opposite jump ("je L / jmp T / L:")
            if m_len >= 2 and m_len <= 4 and pool.data[m_at] == 'j' and not mnemonic_is("jmp") and not mnemonic_is("jcxz")
                    and not mnemonic_is("jpe") and not mnemonic_is("jpo") and second >= 0 and is(second, "jmp") and b_len == 0 {
                long over_at = a_at
                uword over_len = a_len
                long cond_at = m_at
                uword cond_len = m_len
                long after = second + 1
                while after < count and kinds[after] == K_GONE
                    after++
                parse(second)
                if after < count and kinds[after] == K_OTHER and lengths[after] == over_len + 1 and pool.data[starts[after] + over_len] == ':'
                        and buf.bytes_equal(pool.data + starts[after], pool.data + over_at, over_len)
                        and a_len != 0 and pool.data[a_at + a_len - 1] != ']' and register_number(a_at, a_len) == 255 {
                    buf.reserve(pool, a_len + 32)
                    long begin3 = pool.len
                    buf.add_str(pool, "    j")
                    uword c = 1
                    if pool.data[cond_at + 1] == 'n'
                        c = 2
                    else
                        buf.add_byte(pool, 'n')
                    while c < cond_len {
                        buf.add_byte(pool, pool.data[cond_at + c])
                        c++
                    }
                    buf.add_str(pool, "  ")
                    buf.add_bytes(pool, pool.data + a_at, a_len)
                    starts[k] = begin3
                    lengths[k] = (pool.len - begin3) as uword
                    kinds[second] = K_GONE
                    k++
                    continue
                }
                parse(k)
            }
            ; "mov ax, X / mov r, ax" and then AX gets another value: "mov r, X"
            if mnemonic_is("mov") and a_len == 2 and pool.data[a_at] == 'a' and pool.data[a_at + 1] == 'x' and second >= 0 and is(second, "mov") {
                long x_at = b_at
                uword x_len = b_len
                long third = next_code(second)
                parse(second)
                classify(a_at, a_len)
                if third >= 0 and o_kind == O_REG and o_reg >= 1 and o_reg <= 5 and b_len == 2 and pool.data[b_at] == 'a' and pool.data[b_at + 1] == 'x'
                        and is(third, "mov") {
                    ubyte into = o_reg
                    parse(third)
                    classify(a_at, a_len)
                    if o_kind == O_REG and (o_reg == R_AX or o_reg == R_AL) and not mentions(b_at, b_len, R_AX) {
                        buf.reserve(pool, x_len + 32)
                        long begin4 = pool.len
                        buf.add_str(pool, "    mov  ")
                        buf.add_str(pool, register_name(into))
                        buf.add_str(pool, ", ")
                        buf.add_bytes(pool, pool.data + x_at, x_len)
                        starts[k] = begin4
                        lengths[k] = (pool.len - begin4) as uword
                        kinds[second] = K_GONE
                        k++
                        continue
                    }
                }
                parse(k)
            }
            if mnemonic_is("mov") {
                classify(a_at, a_len)
                if o_kind == O_REG and second >= 0 {
                    ubyte r = o_reg
                    long first_b = b_at
                    uword first_b_len = b_len
                    ; a load, and then the same register (or all of what it is a part
                    ; of) is loaded again with something that does not need it
                    ; (the first must be a load that can be left out: not one of
                    ; memory that is reached through a register or is a machine's)
                    classify(first_b, first_b_len)
                    bool plain = o_kind != O_MEM or is_named(o_at, o_len)
                    parse(second)
                    if plain and mnemonic_is("mov") and not mentions(b_at, b_len, r) {
                        classify(a_at, a_len)
                        if o_kind == O_REG and (o_reg == r or (r >= 6 and r < 14 and o_reg == (r - 6) % 4)) {
                            kinds[k] = K_GONE
                            k++
                            continue
                        }
                    }
                    parse(k)
                }
            }
            if mnemonic_is("cmp") and b_len == 1 and pool.data[b_at] == '0' {
                classify(a_at, a_len)
                if o_kind == O_REG and o_reg < 14 {
                    ubyte tested = o_reg
                    long reg_at = a_at
                    ; After the instruction that left this register's flags (with only
                    ; moves of other things between), before a jump on zero or on the
                    ; sign, the compare is not needed.
                    bool needed = true
                    if second >= 0 and (is(second, "je") or is(second, "jne") or is(second, "jz") or is(second, "jnz")) {
                        long before = previous_code(k)
                        while before >= 0 and is(before, "mov") {
                            parse(before)
                            classify(a_at, a_len)
                            if o_kind == O_REG and (o_reg == tested or mentions(a_at, a_len, tested))
                                break
                            before = previous_code(before)
                        }
                        if before >= 0 and (is(before, "add") or is(before, "sub") or is(before, "and") or is(before, "or") or is(before, "xor")
                                or is(before, "inc") or is(before, "dec") or is(before, "neg")) {
                            parse(before)
                            classify(a_at, a_len)
                            if o_kind == O_REG and o_reg == tested
                                needed = false
                        }
                        parse(k)
                    }
                    if not needed
                        kinds[k] = K_GONE
                    else {
                        ; "test r, r" is a byte shorter and leaves the same flags
                        buf.reserve(pool, 32)
                        long begin = pool.len
                        buf.add_str(pool, "    test  ")
                        buf.add_bytes(pool, pool.data + reg_at, 2)
                        buf.add_str(pool, ", ")
                        buf.add_bytes(pool, pool.data + reg_at, 2)
                        starts[k] = begin
                        lengths[k] = (pool.len - begin) as uword
                    }
                    k++
                    continue
                }
            }
            ; a register made 0 where no flag is needed: "xor r, r"
            if mnemonic_is("mov") and b_len == 1 and pool.data[b_at] == '0' {
                classify(a_at, a_len)
                if o_kind == O_REG and o_reg < 14 and flags_free(k) {
                    long name_at = a_at
                    buf.reserve(pool, 32)
                    long begin2 = pool.len
                    buf.add_str(pool, "    xor  ")
                    buf.add_bytes(pool, pool.data + name_at, 2)
                    buf.add_str(pool, ", ")
                    buf.add_bytes(pool, pool.data + name_at, 2)
                    starts[k] = begin2
                    lengths[k] = (pool.len - begin2) as uword
                }
            }
            k++
        }
    }
}
