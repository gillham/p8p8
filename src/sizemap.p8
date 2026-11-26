; The map of a built program (-map, name.p8map): where every block, subroutine and
; variable is and how many bytes it takes, in one form for every CPU.  An extension
; of p8p8's; tools/p8size.py reads it.
;
; The assembler knows the addresses: it is asked for its list of symbols (64tass's
; label list, lwasm's symbol dump, z80asm's map, vasm's listing, nasm's map), a reader for each
; puts them in one table, and from there on it is the same work: what a name is (a
; block, a subroutine, a variable, a label inside a routine), the order of the
; addresses, and the bytes of each: the distance to the next one.
;
; The file, a line each, fields apart by one space:
;   p8map 1
;   program NAME / target NAME / cpu NAME
;   relocatable                         addresses are offsets in the kind's section
;   region NAME START END               (hex; END is the first address after it)
;   limit ADDRESS / free BYTES          where the program must end, and what is left
;   module BLOCK FILE                   the source file a block is from
;   code|data|var|zp ADDRESS BYTES BLOCK NAME
; NAME is a subroutine (inner ones with dots), a variable (sub.variable), or "-" for
; what is the block's own; the block "(runtime)" has what belongs to no block.

%import buf
%import mem
%import ir

sizemap {
    %option ignore_unused

    const ubyte SCOPES = 0          ; block:sub:variable with p8b_, p8s_, p8v_ (64tass, vasm)
    const ubyte UNDER = 1           ; _block__sub__variable (z80asm, lwasm)

    const ubyte K_DROP = 0          ; not a place of its own: a label inside a routine, a constant
    const ubyte K_MARK = 1          ; an end: what is before it stops here, and it is not listed
    const ubyte K_CODE = 2
    const ubyte K_DATA = 3
    const ubyte K_VAR = 4

    ubyte style = SCOPES
    ubyte separator = ':'
    bool sectioned = false          ; vasm: addresses are offsets in sections

    long count = 0
    long cap = 0
    ^^pointer names = 0             ; the name, in the bytes of the assembler's file
    ^^long lens = 0
    ^^long addrs = 0
    ^^ubyte sects = 0
    ^^ubyte kinds = 0
    ^^ubyte ranks = 0               ; of two at one address the higher is the one that has the bytes
    ^^long order = 0

    ; where the variables without a value are (not sectioned), two ranges at most
    long vars_from = -1
    long vars_to = -1
    long vars2_from = -1
    long vars2_to = -1
    ; where the values are, when the assembler's list does not say (nasm, one segment)
    long data_from = -1
    long data_to = -1

    ; vasm's sections
    ubyte[16] sect_kind
    long[16] sect_end

    ^^buf.Buf o = 0                 ; the map's text
    ^^buf.Buf blk = 0               ; the block and the name of the symbol looked at
    ^^buf.Buf nm = 0
    ^^buf.Buf owner = 0             ; entries: the block of the routine before

    sub begin(long lines) {
        cap = lines + 16
        count = 0
        names = mem.alloc(cap * sizeof(pointer))
        lens = mem.alloc(cap * sizeof(long))
        addrs = mem.alloc(cap * sizeof(long))
        order = mem.alloc(cap * sizeof(long))
        sects = mem.alloc(cap)
        kinds = mem.alloc(cap)
        ranks = mem.alloc(cap)
        vars_from = -1
        vars_to = -1
        vars2_from = -1
        vars2_to = -1
        data_from = -1
        data_to = -1
        sectioned = false
        if o == 0 {
            o = buf.new(65536)
            blk = buf.new(256)
            nm = buf.new(256)
            owner = buf.new(256)
        }
        buf.clear(o)
    }

    sub lines_of(^^ubyte data, long size) -> long {
        long n = 1
        long k
        for k in 0 to size - 1 {
            if data[k] == '\n'
                n++
        }
        return n
    }

    sub add(^^ubyte name, long length, ubyte section, long address) {
        if count >= cap or length <= 0
            return
        names[count] = name
        lens[count] = length
        addrs[count] = address
        sects[count] = section
        count++
    }

    sub hex_value(ubyte c) -> byte {
        if c >= '0' and c <= '9'
            return (c - '0') as byte
        c |= 32
        if c >= 'a' and c <= 'f'
            return (c - 'a' + 10) as byte
        return -1
    }

    ; ---- the assemblers' lists ----

    ; 64tass --vice-labels: "al 0828 .p8b_main:p8s_start"
    sub read_vice(^^ubyte data, long size) {
        begin(lines_of(data, size))
        style = SCOPES
        separator = ':'
        long k = 0
        while k < size {
            long e = k
            while e < size and data[e] != '\n'
                e++
            if e - k > 5 and data[k] == 'a' and data[k + 1] == 'l' and data[k + 2] == ' ' {
                long q = k + 3
                long value = 0
                while q < e and hex_value(data[q]) >= 0 {
                    value = value * 16 + hex_value(data[q])
                    q++
                }
                while q < e and data[q] == ' '
                    q++
                if q < e and data[q] == '.' {
                    q++
                    long last = e
                    while last > q and (data[last - 1] == '\r' or data[last - 1] == ' ')
                        last--
                    add(data + q, last - q, 0, value)
                }
            }
            k = e + 1
        }
    }

    ; lwasm --symbol-dump: "_main__start EQU $0E1A"
    sub read_lwasm(^^ubyte data, long size) {
        begin(lines_of(data, size))
        style = UNDER
        long k = 0
        while k < size {
            long e = k
            while e < size and data[e] != '\n'
                e++
            long q = k
            while q < e and data[q] != ' '
                q++
            long length = q - k
            while q < e and data[q] != '$'
                q++
            if q < e and length > 0 {
                q++
                long value = 0
                while q < e and hex_value(data[q]) >= 0 {
                    value = value * 16 + hex_value(data[q])
                    q++
                }
                add(data + k, length, 0, value)
            }
            k = e + 1
        }
    }

    ; z80asm's map: "_main__start   = $0103 ; addr, local, , t, , t.asm:26"
    ; (a constant is no place in the program; __head and __tail are the linker's)
    sub read_z80asm(^^ubyte data, long size) {
        begin(lines_of(data, size))
        style = UNDER
        long k = 0
        while k < size {
            long e = k
            while e < size and data[e] != '\n'
                e++
            long q = k
            while q < e and data[q] != ' '
                q++
            long length = q - k
            while q < e and data[q] != '$'
                q++
            if q < e and length > 0 {
                q++
                long value = 0
                while q < e and hex_value(data[q]) >= 0 {
                    value = value * 16 + hex_value(data[q])
                    q++
                }
                while q < e and data[q] != ';'
                    q++
                bool constant = q + 7 < e and buf.bytes_equal(data + q + 2, "const", 5)
                if not constant or (length == 6 and (buf.bytes_equal(data + k, "__head", 6) or buf.bytes_equal(data + k, "__tail", 6)))
                    add(data + k, length, 0, value)
            }
            k = e + 1
        }
    }

    ; nasm's map ("[map symbols]" in the assembly, which goes to its output):
    ;   ---- Section .text ----...
    ;   Real              Virtual           Name
    ;                100               100  p8_start
    ; and before them "---- No Section" with the constants, which are no places.
    ; The virtual address is the one the program has when it runs.  A .COM program
    ; is one section.  An .EXE has two segments, whose addresses both begin low: its
    ; map is one of sections (code 0, values 1, and what is set aside after the
    ; values, which nasm lists with them, 2).
    sub read_nasm(^^ubyte data, long size, bool segments) {
        begin(lines_of(data, size))
        style = UNDER
        byte section = -1
        long k = 0
        while k < size {
            long e = k
            while e < size and data[e] != '\n'
                e++
            long length = e - k
            if length >= 5 and buf.bytes_equal(data + k, "---- ", 5) {
                section = -1
                if length >= 18 and buf.bytes_equal(data + k + 5, "Section .text", 13)
                    section = 0
                else if length >= 18 and buf.bytes_equal(data + k + 5, "Section .data", 13)
                    section = 1
            }
            else if section >= 0 {
                long q = k
                while q < e and data[q] == ' '
                    q++
                long digits = q
                while q < e and hex_value(data[q]) >= 0
                    q++
                if q > digits and q < e and data[q] == ' ' {
                    while q < e and data[q] == ' '
                        q++
                    long address = 0
                    digits = q
                    while q < e and hex_value(data[q]) >= 0 {
                        address = address * 16 + hex_value(data[q])
                        q++
                    }
                    if q > digits and q < e and data[q] == ' ' {
                        while q < e and data[q] == ' '
                            q++
                        long name_end = q
                        while name_end < e and data[name_end] != ' ' and data[name_end] != '\r'
                            name_end++
                        if name_end > q {
                            if segments
                                add(data + q, name_end - q, section as ubyte, address)
                            else
                                add(data + q, name_end - q, 0, address)
                        }
                    }
                }
            }
            k = e + 1
        }
        if segments {
            sectioned = true
            sect_kind[0] = K_CODE
            sect_kind[1] = K_DATA
            sect_kind[2] = K_VAR
            long set_aside = value("p8_bss_start")
            sect_end[0] = value("p8_code_end")
            sect_end[1] = set_aside
            sect_end[2] = value("p8_bss_end")
            if set_aside >= 0 {
                for k in 0 to count - 1 {
                    if sects[k] == 1 and addrs[k] >= set_aside
                        sects[k] = 2
                }
            }
        }
    }

    ; vasm's listing (-L): first 'Sections:' with a line each, '00: ".text" (0-5BE)',
    ; at its end 'Symbols by name:' with 'p8b_main.p8s_start   00:00000018'
    ; (" E:" is an expression: a constant)
    sub read_vasm(^^ubyte data, long size) {
        begin(lines_of(data, size))
        style = SCOPES
        separator = '.'
        sectioned = true
        ubyte sn
        for sn in 0 to 15 {
            sect_kind[sn] = K_CODE
            sect_end[sn] = 0
        }
        ubyte part = 0              ; 1: in the sections, 2: in the symbols
        long k = 0
        while k < size {
            long e = k
            while e < size and data[e] != '\n'
                e++
            long length = e - k
            if length >= 9 and buf.bytes_equal(data + k, "Sections:", 9)
                part = 1
            else if length >= 16 and buf.bytes_equal(data + k, "Symbols by name:", 16)
                part = 2
            else if length >= 17 and buf.bytes_equal(data + k, "Symbols by value:", 17)
                part = 0
            else if part == 1 {
                if length > 6 and hex_value(data[k]) >= 0 and hex_value(data[k + 1]) >= 0 and data[k + 2] == ':' {
                    ubyte number = (hex_value(data[k]) * 16 + hex_value(data[k + 1])) as ubyte
                    if number < 16 {
                        long q = k + 3
                        while q < e and data[q] != '"'
                            q++
                        long name_from = q + 1
                        q = name_from
                        while q < e and data[q] != '"'
                            q++
                        if has_text(data + name_from, q - name_from, "bss")
                            sect_kind[number] = K_VAR
                        else if has_text(data + name_from, q - name_from, "data")
                            sect_kind[number] = K_DATA
                        while q < e and data[q] != '-'
                            q++
                        q++
                        long value = 0
                        while q < e and hex_value(data[q]) >= 0 {
                            value = value * 16 + hex_value(data[q])
                            q++
                        }
                        sect_end[number] = value
                    }
                }
                else if length == 0 or data[k] == 'S'
                    part = 0
            }
            else if part == 2 and length > 12 {
                long q2 = k
                while q2 < e and data[q2] != ' '
                    q2++
                long name_length = q2 - k
                while q2 < e and data[q2] == ' '
                    q2++
                if q2 + 3 < e and hex_value(data[q2]) >= 0 and hex_value(data[q2 + 1]) >= 0 and data[q2 + 2] == ':' {
                    ubyte section = (hex_value(data[q2]) * 16 + hex_value(data[q2 + 1])) as ubyte
                    q2 += 3
                    long value2 = 0
                    while q2 < e and hex_value(data[q2]) >= 0 {
                        value2 = value2 * 16 + hex_value(data[q2])
                        q2++
                    }
                    if section < 16
                        add(data + k, name_length, section, value2)
                }
            }
            k = e + 1
        }
    }

    sub has_text(^^ubyte text, long length, str part) -> bool {
        long n = buf.cstr_len(part)
        long k = 0
        while k + n <= length {
            if buf.bytes_equal(text + k, part, n)
                return true
            k++
        }
        return false
    }

    ; A name that the assembly gives a value with "equ" is no place in the program
    ; (lwasm's list does not tell them apart): a constant, or another name for a place.
    sub drop_equates(^^ubyte text, long size) {
        long k = 0
        while k < size {
            long e = k
            while e < size and text[e] != '\n'
                e++
            if text[k] != ' ' and text[k] != ';' and text[k] != '\t' {
                long q = k
                while q < e and text[q] != ' ' and text[q] != ':' and text[q] != '\t'
                    q++
                long length = q - k
                if q < e and text[q] == ':'
                    q++
                while q < e and (text[q] == ' ' or text[q] == '\t')
                    q++
                if q + 4 <= e and buf.bytes_equal(text + q, "equ", 3) and text[q + 3] == ' ' {
                    long at = find_bytes(text + k, length)
                    if at >= 0
                        kinds[at] = K_DROP + 100
                }
            }
            k = e + 1
        }
    }

    sub find_bytes(^^ubyte name, long length) -> long {
        long k
        for k in 0 to count - 1 {
            if lens[k] == length and buf.bytes_equal(names[k] as ^^ubyte, name, length)
                return k
        }
        return -1
    }

    ; the address of a symbol, -1 when there is none of that name
    sub value(str name) -> long {
        long at = find_bytes(name, buf.cstr_len(name))
        if at < 0
            return -1
        return addrs[at]
    }

    sub values(long from, long upto) {
        if from >= 0 and upto >= from {
            data_from = from
            data_to = upto
        }
    }

    sub vars(long from, long upto) {
        if from < 0 or upto < from
            return
        if vars_from < 0 {
            vars_from = from
            vars_to = upto
        }
        else {
            vars2_from = from
            vars2_to = upto
        }
    }

    ; ---- what a name is ----

    long[10] part_from
    long[10] part_len
    ubyte parts

    ; a name in its parts: SCOPES at the separator, UNDER at "__"
    sub split(^^ubyte name, long length, ubyte kind, ubyte sep) {
        parts = 0
        long from = 0
        long k = 0
        while k < length {
            bool here = false
            long skip = 1
            if kind == SCOPES
                here = name[k] == sep
            else if name[k] == '_' and k + 2 < length and name[k + 1] == '_' and name[k + 2] != '_' and k > from {
                here = true
                skip = 2
            }
            if here and parts < 9 {
                part_from[parts] = from
                part_len[parts] = k - from
                parts++
                k += skip
                from = k
            }
            else
                k++
        }
        part_from[parts] = from
        part_len[parts] = length - from
        parts++
    }

    sub starts(^^ubyte name, long length, str prefix) -> bool {
        long n = buf.cstr_len(prefix)
        return length >= n and buf.bytes_equal(name, prefix, n)
    }

    sub is_name(^^ubyte name, long length, str other) -> bool {
        long n = buf.cstr_len(other)
        return length == n and buf.bytes_equal(name, other, n)
    }

    sub is_mark(^^ubyte name, long length) -> bool {
        return is_name(name, length, "prog8_program_end") or is_name(name, length, "p8map_vars_end")
            or is_name(name, length, "p8_bss_end") or is_name(name, length, "p8_stack_top")
            or is_name(name, length, "p8_upper_end") or is_name(name, length, "p8_upper_vars_end")
            or is_name(name, length, "__tail") or is_name(name, length, "p8map_vars")
            or is_name(name, length, "p8_bss_start") or is_name(name, length, "p8_upper_start")
            or is_name(name, length, "p8_code_start") or is_name(name, length, "p8_code_end")
            or is_name(name, length, "p8_data_start") or is_name(name, length, "p8_data_end")
    }

    ; a label that is inside a routine
    sub is_local(^^ubyte name, long length) -> bool {
        return starts(name, length, "p8l_") or starts(name, length, "p8_label_gen_") or starts(name, length, "_p8_label_gen_")
            or (style == UNDER and (starts(name, length, "p8z_") or starts(name, length, "p8j_")))
    }

    sub in_vars(ubyte section, long address) -> bool {
        if sectioned
            return sect_kind[section & 15] == K_VAR
        return (vars_from >= 0 and address >= vars_from and address < vars_to)
            or (vars2_from >= 0 and address >= vars2_from and address < vars2_to)
    }

    ; is there a symbol inside the scope of this name: then it is a block
    sub has_inner(^^ubyte name, long length) -> bool {
        long k
        for k in 0 to count - 1 {
            if lens[k] > length + 1 {
                ^^ubyte other = names[k] as ^^ubyte
                if other[length] == separator and buf.bytes_equal(other, name, length)
                    return true
            }
        }
        return false
    }

    ; What the symbol is, with its block in blk and its name in nm.
    sub classify(long at) -> ubyte {
        ^^ubyte name = names[at] as ^^ubyte
        long length = lens[at]
        buf.clear(blk)
        buf.clear(nm)
        ranks[at] = 1
        if kinds[at] >= 100
            return K_DROP               ; (an equate)
        if is_mark(name, length) {
            ranks[at] = 0
            return K_MARK
        }
        if is_local(name, length)
            return K_DROP
        bool variable = in_vars(sects[at], addrs[at])
        ubyte kind = K_CODE
        if variable
            kind = K_VAR
        else if sectioned and sect_kind[sects[at] & 15] == K_DATA
            kind = K_DATA
        else if not sectioned and data_from >= 0 and addrs[at] >= data_from and addrs[at] < data_to
            kind = K_DATA
        if style == UNDER {
            if starts(name, length, "p8e_") {
                ; (where a subroutine is entered with its arguments in registers)
                name += 4
                length -= 4
            }
            else if name[0] != '_' or (length > 1 and name[1] == '_') {
                runtime(name, length)
                return kind
            }
            else {
                name++
                length--
            }
            split(name, length, UNDER, 0)
            if parts == 1 {
                runtime(names[at] as ^^ubyte, lens[at])
                return kind
            }
            buf.add_bytes(blk, name, part_len[0])
            join(name, 1)
            ranks[at] = parts + 1
            return kind
        }
        split(name, length, SCOPES, separator)
        if parts == 1 {
            if starts(name, length, "p8b_")
                buf.add_bytes(blk, name + 4, length - 4)
            else if has_inner(name, length)
                buf.add_bytes(blk, name, length)
            else {
                runtime(name, length)
                return kind
            }
            buf.add_byte(nm, '-')
            ranks[at] = 2
            return kind
        }
        ^^ubyte last = name + part_from[parts - 1]
        long last_len = part_len[parts - 1]
        if not variable and kind != K_DATA {
            if starts(last, last_len, "p8v_")
                kind = K_DATA
            else if not starts(last, last_len, "p8s_") {
                ; a label: a routine of a block that is written in assembly, or a
                ; place inside a routine
                ; (64tass: a name that begins with _ is known in its routine only)
                if parts > 2 or is_local(last, last_len) or (separator == ':' and (last[0] == '_' or last[0] == '+' or last[0] == '-'))
                    return K_DROP
            }
        }
        if starts(name, part_len[0], "p8b_")
            buf.add_bytes(blk, name + 4, part_len[0] - 4)
        else
            buf.add_bytes(blk, name, part_len[0])
        join(name, 1)
        ranks[at] = parts + 1
        return kind
    }

    sub runtime(^^ubyte name, long length) {
        buf.clear(blk)
        buf.clear(nm)
        buf.add_str(blk, "(runtime)")
        buf.add_bytes(nm, name, length)
    }

    ; the parts from the given one on into nm, with dots, without p8s_ and p8v_
    sub join(^^ubyte name, ubyte first) {
        ubyte p
        for p in first to parts - 1 {
            if p != first
                buf.add_byte(nm, '.')
            ^^ubyte part = name + part_from[p]
            long n = part_len[p]
            if starts(part, n, "p8s_") or starts(part, n, "p8v_") {
                part += 4
                n -= 4
            }
            buf.add_bytes(nm, part, n)
        }
    }

    ; ---- the map ----

    sub put(str text) {
        buf.add_str(o, text)
    }

    sub put_hex(long number) {
        ubyte digits = 4
        if number > $ffff
            digits = 6
        if number > $ffffff
            digits = 8
        while digits > 0 {
            digits--
            buf.add_byte(o, buf.hex_digit(lsb(number >> (digits * 4)) & 15))
        }
    }

    sub head(str key, ^^ubyte text) {
        put(key)
        buf.add_byte(o, ' ')
        buf.add_str(o, text)
        buf.add_byte(o, '\n')
    }

    sub region(str name, long from, long upto) {
        if from < 0 or upto < from
            return
        put("region ")
        put(name)
        buf.add_byte(o, ' ')
        put_hex(from)
        buf.add_byte(o, ' ')
        put_hex(upto)
        buf.add_byte(o, '\n')
    }

    sub number(str key, long n) {
        put(key)
        buf.add_byte(o, ' ')
        buf.add_long(o, n)
        buf.add_byte(o, '\n')
    }

    sub limit(long address) {
        put("limit ")
        put_hex(address)
        buf.add_byte(o, '\n')
    }

    ; the source file of each block, from where it is in the source: "[file: line 3 col 1-1]"
    sub modules(^^ir.Program p) {
        ^^ir.Block b = p.blocks
        while b != 0 {
            if b.pos != 0 and b.pos[0] == '[' and b.pos[1] != '~' {
                long n = buf.cstr_len(b.pos)
                long e = 1
                while e + 6 < n and not buf.bytes_equal(b.pos + e, ": line ", 7)
                    e++
                if e + 6 < n {
                    put("module ")
                    if starts(b.name, buf.cstr_len(b.name), "p8b_")
                        buf.add_str(o, b.name + 4)
                    else
                        buf.add_str(o, b.name)
                    buf.add_byte(o, ' ')
                    buf.add_bytes(o, b.pos + 1, e - 1)
                    buf.add_byte(o, '\n')
                }
            }
            b = b.next
        }
    }

    ; a line for something whose place the compiler chose itself (the 6502's zero
    ; page); its name is in scopes with dots
    sub entry(str kind, ^^ubyte name, long address, long bytes) {
        long length = buf.cstr_len(name)
        split(name, length, SCOPES, '.')
        buf.clear(blk)
        buf.clear(nm)
        if parts == 1
            runtime(name, length)
        else {
            if starts(name, part_len[0], "p8b_")
                buf.add_bytes(blk, name + 4, part_len[0] - 4)
            else
                buf.add_bytes(blk, name, part_len[0])
            join(name, 1)
        }
        line(kind, address, bytes)
    }

    sub line(str kind, long address, long bytes) {
        put(kind)
        buf.add_byte(o, ' ')
        put_hex(address)
        buf.add_byte(o, ' ')
        buf.add_long(o, bytes)
        buf.add_byte(o, ' ')
        buf.add_bytes(o, blk.data, blk.len)
        buf.add_byte(o, ' ')
        buf.add_bytes(o, nm.data, nm.len)
        buf.add_byte(o, '\n')
    }

    sub before(long a, long b) -> bool {
        if sects[a] != sects[b]
            return sects[a] < sects[b]
        if addrs[a] != addrs[b]
            return addrs[a] < addrs[b]
        return ranks[a] < ranks[b]
    }

    ; The symbols, in the order of their addresses, each with the bytes up to the next.
    sub entries() {
        long n = 0
        long k
        for k in 0 to count - 1 {
            kinds[k] = classify(k)
            if kinds[k] != K_DROP {
                order[n] = k
                n++
            }
        }
        long gap = n / 2
        while gap > 0 {
            long i = gap
            while i < n {
                long moved = order[i]
                long j = i
                while j >= gap {
                    if not before(moved, order[j - gap])
                        break
                    order[j] = order[j - gap]
                    j -= gap
                }
                order[j] = moved
                i++
            }
            gap /= 2
        }
        if style == UNDER {
            ; A label p8<block>_... after a routine of that block is a place inside
            ; it: the library's assembly names its labels so (p8conv_decimal_digit).
            long kept = 0
            buf.clear(owner)
            for k in 0 to n - 1 {
                long seen = order[k]
                bool inside = false
                if kinds[seen] == K_CODE {
                    void classify(seen)
                    if blk.data[0] == '(' {
                        inside = owner.len != 0 and nm.len > owner.len + 3 and nm.data[0] == 'p' and nm.data[1] == '8'
                            and nm.data[2 + owner.len] == '_' and buf.bytes_equal(nm.data + 2, owner.data, owner.len)
                        if not inside
                            buf.clear(owner)
                    }
                    else {
                        buf.clear(owner)
                        buf.add_bytes(owner, blk.data, blk.len)
                    }
                }
                if not inside {
                    order[kept] = seen
                    kept++
                }
            }
            n = kept
        }
        for k in 0 to n - 1 {
            long at = order[k]
            if kinds[at] != K_MARK {
                long bytes = 0
                if k + 1 < n and sects[order[k + 1]] == sects[at]
                    bytes = addrs[order[k + 1]] - addrs[at]
                else if sectioned
                    bytes = sect_end[sects[at] & 15] - addrs[at]
                if bytes > 0 {
                    void classify(at)
                    when kinds[at] {
                        K_VAR -> line("var", addrs[at], bytes)
                        K_DATA -> line("data", addrs[at], bytes)
                        else -> line("code", addrs[at], bytes)
                    }
                }
            }
        }
    }
}
