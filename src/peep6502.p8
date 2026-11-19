; The value tracking of the 6502 code generator (docs/DESIGN.md).
;
; gen6502 translates every IR instruction by itself, through the cell that each
; virtual register has in p8_regfile.  Here the instructions of one subroutine are
; collected as lines, and before they are written:
;
;   - a jump to a jump goes to its end, a jump to the label that follows is
;     dropped, a branch around a jump becomes the opposite branch, generated
;     labels nothing refers to any more go and so does code nothing can reach;
;     a call followed by a return becomes a jump;
;   - going forward, what A, X, Y, the cells and the plain variables hold is
;     followed (as value numbers): a load of what the register already holds is
;     dropped or becomes a transfer, a read of a cell becomes a read of the
;     constant or the variable the cell is a copy of, and a compare with 0 goes
;     when the flags say it already;
;   - a store to a cell that is never read, or that is written again first, is
;     dropped; a value that is computed into a cell only to be copied to a
;     variable is stored in the variable at once;
;   - going backward, a load whose register and flags nothing uses is dropped,
;     and a load of A that is only transferred becomes a load of X or Y.
;
; Only the cells and the program's own variables are followed: every other
; operand may be a hardware register or one location under several names.
; A label and any text the generator writes itself (inline assembly, local
; labels) forget everything, and so does a subroutine call for the variables.
;
; The CPU differences stay in gen6502: this only sees mnemonics.

%import buf
%import mem
%import strtab

peep6502 {
    %option ignore_unused

    bool enabled = true             ; -noopt switches the whole pass off
    bool active = false             ; collecting the lines of a region
    ; A 65C02: stz, bra, inc a / dec a, (zp), tsb / trb.  Never the bit instructions of
    ; the Rockwell and WDC 65C02 (bbr, bbs, rmb, smb): the 65816, which many
    ; Commander X16s have in place of the 65C02, does not have them.
    bool c02 = false
    bool c02z = false           ; stz is a zero and (zp) is there (not on the 45GS02)
    bool c45 = false

    ^^buf.Buf dest = 0              ; where the region is written
    ^^buf.Buf rawtext = 0           ; the text of the raw lines
    ^^buf.Buf tb = 0                ; scratch

    const ubyte L_INS = 0
    const ubyte L_LABEL = 1
    const ubyte L_RAW = 2           ; lval: where its text starts in rawtext
    const ubyte L_DEAD = 3

    const ubyte O_NONE = 0
    const ubyte O_ACC = 1           ; a
    const ubyte O_NUM = 2           ; #lval
    const ubyte O_IMMTEXT = 3       ; #<name and the like: the whole text
    const ubyte O_CELL = 4          ; p8_regfile+lval
    const ubyte O_VAR = 5           ; a plain variable: name+lval
    const ubyte O_OTHER = 6         ; any other text
    const ubyte O_POOL = 7          ; a shared zero page temporary: p8z_lval

    ; the lines
    ^^ubyte lkind = 0
    ^^ubyte lmn = 0
    ^^ubyte lok = 0
    ^^ubyte lreg = 0                ; a call or return: the registers it passes on (1 A, 2 X, 4 Y), 255: not known
    ^^long lval = 0
    ^^pointer lsym = 0              ; ^^strtab.Sym of the operand text or the label
    long count = 0
    long cap = 0

    ; the mnemonics, three letters each; the constants are the positions
    str mnemonics = "ldaldxldystastxstystzadcsbcandoraeorcmpcpxcpybitincdecasllsrrolrorinxinydexdeytaxtaytxatyatsxtxsphaplaphpplpphxplxphyplyclcseccldseiclijsrjmprtsbnebeqbmibplbccbcsbvcbvsbranoptsbtrb"
    const ubyte M_LDA = 0
    const ubyte M_LDX = 1
    const ubyte M_LDY = 2
    const ubyte M_STA = 3
    const ubyte M_STX = 4
    const ubyte M_STY = 5
    const ubyte M_STZ = 6
    const ubyte M_ADC = 7
    const ubyte M_SBC = 8
    const ubyte M_AND = 9
    const ubyte M_ORA = 10
    const ubyte M_EOR = 11
    const ubyte M_CMP = 12
    const ubyte M_CPX = 13
    const ubyte M_CPY = 14
    const ubyte M_BIT = 15
    const ubyte M_INC = 16
    const ubyte M_DEC = 17
    const ubyte M_ASL = 18
    const ubyte M_LSR = 19
    const ubyte M_ROL = 20
    const ubyte M_ROR = 21
    const ubyte M_INX = 22
    const ubyte M_INY = 23
    const ubyte M_DEX = 24
    const ubyte M_DEY = 25
    const ubyte M_TAX = 26
    const ubyte M_TAY = 27
    const ubyte M_TXA = 28
    const ubyte M_TYA = 29
    const ubyte M_TSX = 30
    const ubyte M_TXS = 31
    const ubyte M_PHA = 32
    const ubyte M_PLA = 33
    const ubyte M_PHP = 34
    const ubyte M_PLP = 35
    const ubyte M_PHX = 36
    const ubyte M_PLX = 37
    const ubyte M_PHY = 38
    const ubyte M_PLY = 39
    const ubyte M_CLC = 40
    const ubyte M_SEC = 41
    const ubyte M_CLD = 42
    const ubyte M_SEI = 43
    const ubyte M_CLI = 44
    const ubyte M_JSR = 45
    const ubyte M_JMP = 46
    const ubyte M_RTS = 47
    const ubyte M_BNE = 48          ; each branch and its opposite differ in the lowest bit
    const ubyte M_BEQ = 49
    const ubyte M_BMI = 50
    const ubyte M_BPL = 51
    const ubyte M_BCC = 52
    const ubyte M_BCS = 53
    const ubyte M_BVC = 54
    const ubyte M_BVS = 55
    const ubyte M_BRA = 56
    const ubyte M_NOP = 57
    const ubyte M_TSB = 58          ; (65C02) sets, clears the bits of A in memory; Z from A and memory
    const ubyte M_TRB = 59
    const ubyte M_COUNT = 60

    ; what an instruction does to the registers and the N and Z flags
    const ubyte RA = 1
    const ubyte WA = 2
    const ubyte RX = 4
    const ubyte WX = 8
    const ubyte RY = 16
    const ubyte WY = 32
    const ubyte SNZ = 64
    const ubyte RNZ = 128
    ubyte[] props = [
        66, 72, 96,                 ; lda ldx ldy
        1, 4, 16, 0,                ; sta stx sty stz
        67, 67, 67, 67, 67,         ; adc sbc and ora eor
        65, 68, 80, 65,             ; cmp cpx cpy bit
        64, 64, 64, 64, 64, 64,     ; inc dec asl lsr rol ror (of memory)
        76, 112, 76, 112,           ; inx iny dex dey
        73, 97, 70, 82,             ; tax tay txa tya
        72, 4,                      ; tsx txs
        1, 66, 128, 64,             ; pha pla php plp
        4, 72, 16, 96,              ; phx plx phy ply
        0, 0, 0, 0, 0,              ; clc sec cld sei cli
        0, 0, 0,                    ; jsr jmp rts
        128, 128, 128, 128,         ; bne beq bmi bpl
        0, 0, 0, 0, 0, 0,           ; bcc bcs bvc bvs bra nop
        1, 1                        ; tsb trb
    ]

    ; what is known of an operand text, in its symbol's mark
    const uword K_PLAIN = 1         ; the name of a plain variable
    const uword K_SCANNED = 2
    const uword K_ESCAPE = 4        ; mentions a generated label inside something larger
    const uword K_USEX = 8
    const uword K_USEY = 16
    const uword K_INDIRECT = 32     ; indexed or through a pointer: where it writes is not known
    const uword K_GENLABEL = 64     ; is a generated label
    const uword K_W1 = 128          ; mentions the scratch pointer P8ZP_SCRATCH_W1
    const uword K_ZPVAR = 256       ; a variable in the zero page
    const uword K_ANON = 512        ; an anonymous label, + or -
    const uword K_FOREIGN = 4096    ; (for the generator) a variable that another subroutine than its own names
    const uword K_SAFE = 2048       ; a variable that no pointer can reach: its address is never taken
    const uword K_TAKEN = 1024      ; (for the generator) a name in assembly, or one whose address is taken

    long region = 0                 ; number of the region, the stamp of what it refers to
    ^^long cellstamp = 0            ; per cell: the stamp of the last pass that saw it read
    long cellcount = 0
    ^^long cellreads = 0            ; forward_stores: the reads and the stores of each cell in the region,
    ^^long cellstores = 0
    ^^long cellline = 0             ; the line of its last store and the block that is in
    ^^long cellblock = 0
    ^^long cellkill = 0             ; backward: the stamp of the stretch in which the cell is written again
    long killseq = 0
    bool use_previous = false       ; backward: what the pass before noted at a label counts too
    long bwseq = 0                  ; the number of the backward pass, in the liveness noted at a label
    ^^long celluse = 0              ; how many instructions of the program as written name the cell (as p8r_N)
    ^^ubyte cellopaque = 0          ; 1: the cell's address is taken, so it is like any other memory
    long stampseq = 0
    bool changed = false
    bool escapes = false

    long stat_lines = 0
    long stat_removed = 0

    sub init(long cells) {
        cellcount = cells + 8
        cellstamp = mem.alloc(cellcount * 4)
        cellreads = mem.alloc(cellcount * 4)
        cellstores = mem.alloc(cellcount * 4)
        cellline = mem.alloc(cellcount * 4)
        cellblock = mem.alloc(cellcount * 4)
        cellkill = mem.alloc(cellcount * 4)
        cellopaque = mem.alloc(cellcount)
        celluse = mem.alloc(cellcount * 4)
        cfirst = mem.alloc(cellcount * 4)
        clast = mem.alloc(cellcount * 4)
        cseen = mem.alloc(cellcount * 4)
        csingle = mem.alloc(cellcount)
        stampseq = 0
        if rawtext == 0 {
            rawtext = buf.new(4096)
            tb = buf.new(256)
            mtab_kind = mem.alloc(MTAB)
            mtab_off = mem.alloc(MTAB * 4)
            mtab_value = mem.alloc(MTAB * 4)
            mtab_sym = mem.alloc(MTAB * sizeof(pointer))
            immtab = mem.alloc(IMMTAB * sizeof(pointer))
            w1lo = scanned("P8ZP_SCRATCH_W1")
            w1hi = scanned("P8ZP_SCRATCH_W1+1")
            ; (the scratch pointer is followed like a variable: only code p8p8 writes and
            ; the routines it calls change it)
            w1lo.mark |= K_PLAIN | K_SAFE
            w1ind = scanned("(P8ZP_SCRATCH_W1),y")
        }
    }

    ; a variable that only the program's own instructions read and write
    sub plain_variable(^^ubyte name) {
        ^^strtab.Sym s = strtab.intern_sym(name, buf.cstr_len(name) as uword)
        s.mark |= K_PLAIN
    }

    ; cells that are read and written through their address: not followed
    sub opaque_cells(long first, long n) {
        long k
        for k in first to first + n - 1 {
            if k < cellcount
                cellopaque[k] = 1
        }
    }

    ; a variable whose address is never taken: a store through a pointer cannot change it
    sub safe_variable(^^ubyte name) {
        ^^strtab.Sym s = strtab.intern_sym(name, buf.cstr_len(name) as uword)
        s.mark |= K_SAFE
    }

    ; a variable that is in the zero page: a pointer there needs no copy to be followed
    sub zp_variable(^^ubyte name) {
        ^^strtab.Sym s = strtab.intern_sym(name, buf.cstr_len(name) as uword)
        s.mark |= K_ZPVAR
    }

    sub begin(^^buf.Buf output) {
        dest = output
        count = 0
        buf.clear(rawtext)
        active = enabled
        pooling = true
        own_name = 0
    }

    sub add_line(ubyte kind) -> long {
        if count == cap {
            long newcap = cap * 2
            if newcap == 0
                newcap = 1024
            lkind = mem.grow(lkind, cap, newcap)
            lmn = mem.grow(lmn, cap, newcap)
            lok = mem.grow(lok, cap, newcap)
            lreg = mem.grow(lreg, cap, newcap)
            lval = mem.grow(lval, cap * 4, newcap * 4)
            lsym = mem.grow(lsym, cap * sizeof(pointer), newcap * sizeof(pointer))
            cap = newcap
        }
        lkind[count] = kind
        lmn[count] = 0
        lok[count] = O_NONE
        lreg[count] = 255
        lval[count] = 0
        lsym[count] = 0
        count++
        return count - 1
    }

    ; the buffer for text that is written as it is
    sub text() -> ^^buf.Buf {
        if count == 0 or lkind[count - 1] != L_RAW {
            long n = add_line(L_RAW)
            lval[n] = rawtext.len
        }
        return rawtext
    }

    ; the registers that the call or return just written passes on: its arguments, or
    ; the value that is returned
    sub last_uses(ubyte mask) {
        if active and count > 0 and lkind[count - 1] == L_INS
            lreg[count - 1] = mask
    }

    sub label(^^ubyte name) {
        long n = add_line(L_LABEL)
        lsym[n] = scanned(name)
    }

    ; "+" or "-": a label like any other for what is known at it, but there are many of
    ; each name, so it is never looked up by name except by the branch just before a "+"
    sub anon_label(^^ubyte which) {
        long n = add_line(L_LABEL)
        ^^strtab.Sym s = scanned(which)
        s.mark |= K_ANON
        lsym[n] = s
    }

    ; the number of a mnemonic, 255 when it is not in the table
    sub mnemonic_id(^^ubyte m) -> ubyte {
        if m[0] == 0 or m[1] == 0 or m[2] == 0 or m[3] != 0
            return 255
        ubyte k = 0
        ubyte at = 0
        while k < M_COUNT {
            if mnemonics[at] == m[0] and mnemonics[at + 1] == m[1] and mnemonics[at + 2] == m[2]
                return k
            at += 3
            k++
        }
        return 255
    }

    sub has_prefix(^^ubyte s, str prefix) -> bool {
        ubyte k = 0
        while prefix[k] != 0 {
            if s[k] != prefix[k]
                return false
            k++
        }
        return true
    }

    ; the symbol of a text, with what the text says worked out once
    sub scanned(^^ubyte t) -> ^^strtab.Sym {
        ^^strtab.Sym s = strtab.intern_sym(t, buf.cstr_len(t) as uword)
        if s.mark & K_SCANNED != 0
            return s
        uword m = s.mark | K_SCANNED
        long k = 0
        while t[k] != 0 {
            if t[k] == '(' or t[k] == ','
                m |= K_INDIRECT
            if t[k] == ',' {
                if t[k + 1] == 'x'
                    m |= K_USEX
                if t[k + 1] == 'y'
                    m |= K_USEY
            }
            if t[k] == 'P' and has_prefix(&t[k], "P8ZP_SCRATCH_W1")
                m |= K_W1
            if t[k] == 'p' and has_prefix(&t[k], "p8_label_gen_") {
                ; alone it is a label; inside a larger text its address is taken
                bool alone = k == 0
                long e = k + 13
                while t[e] >= '0' and t[e] <= '9'
                    e++
                if t[e] != 0
                    alone = false
                if alone
                    m |= K_GENLABEL
                else
                    m |= K_ESCAPE
            }
            k++
        }
        s.mark = m
        return s
    }

    ; a number as the generator writes it: decimal or $hex
    sub parse_number(^^ubyte t) -> bool, long {
        long v = 0
        long k = 0
        if t[0] == '$' {
            k = 1
            if t[1] == 0
                return false, 0
            while t[k] != 0 {
                ubyte c = t[k]
                if c >= '0' and c <= '9'
                    v = v * 16 + (c - '0')
                else if c >= 'a' and c <= 'f'
                    v = v * 16 + (c - 'a' + 10)
                else
                    return false, 0
                if v > 65535
                    return false, 0
                k++
            }
            return true, v
        }
        if t[0] == 0
            return false, 0
        while t[k] != 0 {
            if t[k] < '0' or t[k] > '9'
                return false, 0
            v = v * 10 + (t[k] - '0')
            if v > 65535
                return false, 0
            k++
        }
        return true, v
    }

    ; The virtual registers cx16.r0 to cx16.r15: 32 bytes of ordinary memory that go by
    ; many names (cx16.r3, cx16.r3L, cx16.r3sH, the address itself).  Here they are one
    ; variable, "cx16.r0", and each byte is a place in it.
    long vreg_base = -1             ; the address of cx16.r0, or -1: not followed
    ^^strtab.Sym vreg = 0

    sub virtual_registers(long address) {
        vreg_base = address
        vreg = scanned("cx16.r0")
        vreg.mark |= K_PLAIN
        if address + 31 < 256
            vreg.mark |= K_ZPVAR
    }

    ; the byte of the virtual registers that an operand text names, or -1
    sub vreg_offset(^^ubyte t) -> long {
        long off = 0
        long k = 0
        if t[0] == '$' {
            k = 1
            long a = 0
            while (t[k] >= '0' and t[k] <= '9') or (t[k] >= 'a' and t[k] <= 'f') or (t[k] >= 'A' and t[k] <= 'F') {
                ubyte d = t[k]
                if d >= 'a'
                    d -= 87
                else if d >= 'A'
                    d -= 55
                else
                    d -= '0'
                a = a * 16 + d
                if a > 65535
                    return -1
                k++
            }
            if k == 1 or a < vreg_base
                return -1
            off = a - vreg_base
        }
        else if has_prefix(t, "cx16.r") and t[6] >= '0' and t[6] <= '9' {
            k = 6
            long r = 0
            while t[k] >= '0' and t[k] <= '9' {
                r = r * 10 + (t[k] - '0')
                if r > 15
                    return -1
                k++
            }
            off = r * 2
            if t[k] == 'r' and t[k + 1] >= '0' and t[k + 1] <= '9' {
                ; two of them as a long: cx16.r0r1sl
                k++
                while t[k] >= '0' and t[k] <= '9'
                    k++
                if t[k] == 's' and t[k + 1] == 'l'
                    k += 2
            }
            else {
                ; signed and boolean names, and the two halves: cx16.r3s, cx16.r3bL, cx16.r3sH
                if t[k] == 's' or t[k] == 'b'
                    k++
                if t[k] == 'L'
                    k++
                else if t[k] == 'H' {
                    off++
                    k++
                }
            }
        }
        else
            return -1
        if t[k] == '+' {
            k++
            long plus = 0
            if t[k] < '0' or t[k] > '9'
                return -1
            while t[k] >= '0' and t[k] <= '9' {
                plus = plus * 10 + (t[k] - '0')
                if plus > 31
                    return -1
                k++
            }
            off += plus
        }
        if t[k] != 0 or off > 31
            return -1
        return off
    }

    ; what kind of operand a text is
    sub classify(long n, ^^ubyte operand) {
        if operand == 0 or operand[0] == 0
            return
        if operand[0] == 'a' and operand[1] == 0 {
            lok[n] = O_ACC
            return
        }
        bool ok
        long v
        if operand[0] == '#' {
            ok, v = parse_number(&operand[1])
            if ok and v <= 255 {
                lok[n] = O_NUM
                lval[n] = v
            }
            else {
                lok[n] = O_IMMTEXT
                lsym[n] = scanned(operand)
            }
            return
        }
        if vreg_base >= 0 {
            v = vreg_offset(operand)
            if v >= 0 {
                lok[n] = O_VAR
                lsym[n] = vreg
                lval[n] = v
                return
            }
        }
        if has_prefix(operand, "p8_regfile+") {
            ok, v = parse_number(&operand[11])
            if ok and v < cellcount and cellopaque[v] == 0 {
                lok[n] = O_CELL
                lval[n] = v
                return
            }
        }
        ^^strtab.Sym s = scanned(operand)
        if s == w1hi {
            ; (the second byte of the scratch pointer, under the name of the first)
            lok[n] = O_VAR
            lsym[n] = w1lo
            lval[n] = 1
            return
        }
        lsym[n] = s
        if s.mark & K_PLAIN != 0
            lok[n] = O_VAR
        else
            lok[n] = O_OTHER
    }

    ; an instruction this does not know is text
    sub unknown(^^ubyte mnemonic, ^^ubyte operand) {
        ^^buf.Buf t = text()
        buf.add_str(t, "    ")
        buf.add_str(t, mnemonic)
        if operand != 0 and operand[0] != 0 {
            buf.add_str(t, "  ")
            buf.add_str(t, operand)
        }
        buf.add_byte(t, '\n')
    }

    sub ins(^^ubyte mnemonic, ^^ubyte operand) {
        ubyte m = mnemonic_id(mnemonic)
        if m == 255 {
            unknown(mnemonic, operand)
            return
        }
        long n = add_line(L_INS)
        lmn[n] = m
        classify(n, operand)
    }

    sub ins_imm(^^ubyte mnemonic, long value) {
        ubyte m = mnemonic_id(mnemonic)
        long n = add_line(L_INS)
        lmn[n] = m
        lok[n] = O_NUM
        lval[n] = value & 255
    }

    ; symbol+offset
    sub ins_at(^^ubyte mnemonic, ^^ubyte symbol, long offset) {
        ubyte m = mnemonic_id(mnemonic)
        ^^strtab.Sym s = scanned(symbol)
        if m != 255 and s.mark & K_PLAIN != 0 {
            long n = add_line(L_INS)
            lmn[n] = m
            lok[n] = O_VAR
            lsym[n] = s
            lval[n] = offset
            return
        }
        buf.clear(tb)
        buf.add_str(tb, symbol)
        if offset != 0 {
            buf.add_byte(tb, '+')
            buf.add_long(tb, offset)
        }
        buf.add_byte(tb, 0)
        ins(mnemonic, tb.data)
    }

    ; ---- writing the region ----

    sub flush() {
        if not active
            return
        active = false
        stat_lines += count
        optimize()
        share_cells()
        if c02z and zero_index() {
            ; (the "ldy #0" may be for nothing now)
            use_previous = true
            backward()
            use_previous = false
        }
        long i = 0
        while i < count {
            when lkind[i] {
                L_INS -> write_ins(i)
                L_LABEL -> {
                    ^^strtab.Sym s = lsym[i]
                    buf.add_str(dest, s.text)
                    if s.mark & K_ANON != 0
                        buf.add_byte(dest, '\n')
                    else
                        buf.add_str(dest, ":\n")
                }
                L_RAW -> {
                    ; up to the text of the next raw line
                    long from = lval[i]
                    long upto = rawtext.len
                    long j = i + 1
                    while j < count {
                        if lkind[j] == L_RAW {
                            upto = lval[j]
                            break
                        }
                        j++
                    }
                    if upto > from
                        buf.add_bytes(dest, &rawtext.data[from], upto - from)
                }
                else -> stat_removed++
            }
            i++
        }
        count = 0
        buf.clear(rawtext)
    }

    sub write_ins(long i) {
        ubyte at = lmn[i] * 3
        if c02 and lmn[i] == M_JMP and lok[i] == O_OTHER {
            ; a byte shorter where it reaches; the assembler makes a jump of it where it does not
            ^^strtab.Sym js = lsym[i]
            if js.mark & K_INDIRECT == 0
                at = M_BRA * 3
        }
        buf.add_str(dest, "    ")
        buf.add_byte(dest, mnemonics[at])
        buf.add_byte(dest, mnemonics[at + 1])
        buf.add_byte(dest, mnemonics[at + 2])
        ^^strtab.Sym s = lsym[i]
        when lok[i] {
            O_ACC -> buf.add_str(dest, "  a")
            O_NUM -> {
                buf.add_str(dest, "  #")
                buf.add_long(dest, lval[i])
            }
            O_POOL -> {
                buf.add_str(dest, "  p8z_")
                buf.add_long(dest, lval[i])
            }
            O_CELL -> {
                ; by its own name: the generator places the cells that are left when all is written
                buf.add_str(dest, "  p8r_")
                buf.add_long(dest, lval[i])
                celluse[lval[i]]++
            }
            O_VAR -> {
                buf.add_str(dest, "  ")
                buf.add_str(dest, s.text)
                if lval[i] != 0 {
                    buf.add_byte(dest, '+')
                    buf.add_long(dest, lval[i])
                }
            }
            O_IMMTEXT, O_OTHER -> {
                buf.add_str(dest, "  ")
                buf.add_str(dest, s.text)
            }
        }
        buf.add_byte(dest, '\n')
    }

    ; ---- temporaries that share the zero page ----
    ;
    ; The cells that are left are mostly short lived: a value is made, used a few
    ; lines on, and never again.  Cells that are not in use at the same time can be
    ; the same byte, and a handful of zero page bytes then serves a whole
    ; subroutine with instructions a byte shorter.
    ;
    ; A cell is in use from its first line to its last.  A loop that touches it
    ; stretches that over the whole loop (the value may come round).  A cell that is
    ; in use over a call stays where it was: the subroutine that is called shares
    ; the same bytes.  For the same reason a subroutine that may run from an
    ; interrupt does not take part at all (the generator says so: pooling).

    ubyte pool_size = 0             ; how many bytes there are (p8z_0 ...), set by the generator
    bool pooling = true             ; this region may use them
    ^^long cfirst = 0
    ^^long clast = 0
    ^^long cseen = 0                ; the region a cell was last seen in
    ^^long clist = 0                ; the cells of the region
    long clist_cap = 0
    long clist_len = 0
    ^^long callsum = 0              ; per line: the calls (and unknown text) before it
    long callsum_cap = 0
    long poolseq = 0
    long[32] slot_until
    ^^ubyte csingle = 0             ; 1: every use of the cell comes after its first line, a store
    ^^long jlo = 0                  ; per label line: the first and the last line that goes to it
    ^^long jhi = 0                  ; (jlo -1: it cannot be known where it is come to from)
    long[48] own_until              ; cells in use over a call: the last line of each that others share
    long[48] own_cell
    const long SHARE_OWN = $40000000
    long stat_pooled = 0

    sub share_cells() {
        poolseq++
        clist_len = 0
        if callsum_cap < count + 1 {
            callsum_cap = count + 1024
            callsum = mem.alloc(callsum_cap * 4)
            jlo = mem.alloc(callsum_cap * 4)
            jhi = mem.alloc(callsum_cap * 4)
        }
        long i = 0
        long calls = 0
        long c
        ^^strtab.Sym s
        while i < count {
            callsum[i] = calls
            if lkind[i] == L_INS {
                if lmn[i] == M_JSR
                    calls++
                if lok[i] == O_CELL {
                    c = lval[i]
                    if cseen[c] != poolseq {
                        cseen[c] = poolseq
                        cfirst[c] = i
                        if clist_len == clist_cap {
                            long newcap = clist_cap * 2 + 256
                            clist = mem.grow(clist, clist_cap * 4, newcap * 4)
                            clist_cap = newcap
                        }
                        clist[clist_len] = c
                        clist_len++
                    }
                    clast[c] = i
                }
            }
            else if lkind[i] == L_RAW
                calls++             ; (text the generator wrote itself may call anything)
            else if lkind[i] == L_LABEL {
                s = lsym[i]
                if s.mark & K_ANON == 0
                    s.extra = i + 1
            }
            i++
        }
        callsum[count] = calls
        if clist_len == 0 {
            clear_label_lines()
            return
        }
        long k
        single_entry()
        ; loops: a branch back to a label stretches every cell it touches over the loop
        bool grew = true
        ubyte rounds = 0
        while grew and rounds < 20 {
            grew = false
            rounds++
            i = 0
            while i < count {
                if lkind[i] == L_INS and lok[i] == O_OTHER and (lmn[i] == M_JMP or (lmn[i] >= M_BNE and lmn[i] <= M_BRA)) {
                    long t = -1
                    s = lsym[i]
                    if s.mark & K_ANON != 0 {
                        if s.text[0] == '-' {
                            ; the nearest "-" before it
                            t = i
                            while t > 0 {
                                t--
                                if lkind[t] == L_LABEL and lsym[t] == s
                                    break
                            }
                            if lkind[t] != L_LABEL or lsym[t] != s
                                t = 0           ; (not found: the whole text before it, to be safe)
                        }
                    }
                    else if s.extra != 0 and s.extra - 1 < i
                        t = s.extra - 1
                    if t >= 0 {
                        for k in 0 to clist_len - 1 {
                            c = clist[k]
                            if csingle[c] == 0 and cfirst[c] <= i and clast[c] >= t {
                                if cfirst[c] > t {
                                    cfirst[c] = t
                                    grew = true
                                }
                                if clast[c] < i {
                                    clast[c] = i
                                    grew = true
                                }
                            }
                        }
                    }
                }
                i++
            }
        }
        clear_label_lines()
        if grew
            return                  ; (it did not settle: leave everything as it is)
        ; in the order they start (the list is in the order of the first lines, but the
        ; loops may have moved some: an insertion sort, which is quick on what is nearly sorted)
        for k in 1 to clist_len - 1 {
            c = clist[k]
            long at = k
            while at > 0 and cfirst[clist[at - 1]] > cfirst[c] {
                clist[at] = clist[at - 1]
                at--
            }
            clist[at] = c
        }
        ubyte own_count = 0
        ; (a subroutine that may run from an interrupt keeps off the bytes of the pool, but
        ; its cells share among themselves as those do that are in use over a call)
        ubyte usable = pool_size
        if not pooling
            usable = 0
        ubyte slot = 0
        while slot < usable {
            slot_until[slot] = -1
            slot++
        }
        for k in 0 to clist_len - 1 {
            c = clist[k]
            cseen[c] = -poolseq - 1         ; not shared, until a place is found
            if usable == 0 or callsum[clast[c]] != callsum[cfirst[c]] {
                ; In use over a call: not a byte of the pool, but two such cells of this
                ; subroutine that are not in use at the same time can still be one cell.
                slot = 0
                while slot < own_count {
                    if own_until[slot] < cfirst[c] {
                        own_until[slot] = clast[c]
                        cseen[c] = poolseq + SHARE_OWN
                        cfirst[c] = own_cell[slot]
                        stat_pooled++
                        break
                    }
                    slot++
                }
                if slot == own_count and own_count < len(own_until) {
                    own_until[own_count] = clast[c]
                    own_cell[own_count] = c
                    own_count++
                }
                continue
            }
            slot = 0
            while slot < usable {
                if slot_until[slot] < cfirst[c] {
                    slot_until[slot] = clast[c]
                    cseen[c] = poolseq
                    cfirst[c] = slot        ; (the first line is not needed any more: the place)
                    stat_pooled++
                    break
                }
                slot++
            }
        }
        i = 0
        while i < count {
            if lkind[i] == L_INS and lok[i] == O_CELL {
                c = lval[i]
                if cseen[c] == poolseq {
                    lok[i] = O_POOL
                    lval[i] = cfirst[c]
                }
                else if cseen[c] == poolseq + SHARE_OWN
                    lval[i] = cfirst[c]
            }
            i++
        }
        ; two cells that became one: a copy from the one to the other is nothing now
        bool copies = false
        i = 0
        while i < count {
            if lkind[i] == L_INS and lmn[i] == M_STA and (lok[i] == O_POOL or lok[i] == O_CELL) {
                k = previous_live(i)
                if k < i and lkind[k] == L_INS and lmn[k] == M_LDA and lok[k] == lok[i] and lval[k] == lval[i] {
                    lkind[i] = L_DEAD
                    copies = true
                }
            }
            i++
        }
        if copies {
            ; (the load may be for nothing as well)
            use_previous = true
            backward()
            use_previous = false
        }
    }

    ; Which cells are only ever read after the store in their first line?  Those whose
    ; lines, from the first to the last, are entered at the first line only: every label
    ; in between is come to from in between.  Such a cell holds nothing outside those
    ; lines, whatever loop goes round them.
    sub single_entry() {
        long i = 0
        long t
        ^^strtab.Sym s
        bool escapes = false
        while i < count {
            jlo[i] = count
            jhi[i] = -1
            if lkind[i] == L_LABEL {
                s = lsym[i]
                if s.mark & (K_ANON | K_GENLABEL) == 0
                    jlo[i] = -1             ; a name of the program: anything may come to it
            }
            i++
        }
        i = 0
        while i < count {
            if lkind[i] == L_INS and (lok[i] == O_OTHER or lok[i] == O_IMMTEXT) {
                s = lsym[i]
                if s.mark & K_ESCAPE != 0
                    escapes = true
                t = -1
                if s.mark & K_ANON != 0 {
                    t = i
                    if s.text[0] == '-' {
                        while t > 0 {
                            t--
                            if lkind[t] == L_LABEL and lsym[t] == s
                                break
                        }
                        if lkind[t] != L_LABEL or lsym[t] != s
                            escapes = true
                    }
                    else {
                        t++
                        while t < count {
                            if lkind[t] == L_LABEL and lsym[t] == s
                                break
                            t++
                        }
                        if t >= count
                            escapes = true
                    }
                    if escapes
                        t = -1
                }
                else if s.extra != 0
                    t = s.extra - 1
                if t >= 0 {
                    if lok[i] == O_IMMTEXT or not (lmn[i] == M_JMP or (lmn[i] >= M_BNE and lmn[i] <= M_BRA))
                        jlo[t] = -1         ; its address is used: it is not known from where
                    else if jlo[t] >= 0 {
                        if i < jlo[t]
                            jlo[t] = i
                        if i > jhi[t]
                            jhi[t] = i
                    }
                }
            }
            i++
        }
        long k
        long c
        for k in 0 to clist_len - 1 {
            c = clist[k]
            csingle[c] = 0
            if escapes
                continue
            i = cfirst[c]
            if lmn[i] != M_STA and lmn[i] != M_STX and lmn[i] != M_STY and lmn[i] != M_STZ
                continue
            csingle[c] = 1
            i++
            while i <= clast[c] {
                if lkind[i] == L_RAW or (lkind[i] == L_LABEL and (jlo[i] < cfirst[c] or jhi[i] > clast[c])) {
                    csingle[c] = 0
                    break
                }
                i++
            }
        }
    }

    ; The 65C02 follows a zero page pointer without an index: "(pointer),y" with a zero
    ; in Y is "(pointer)", and Y is free.
    sub zero_index() -> bool {
        bool any = false
        bool zero = false
        long i = 0
        while i < count {
            if lkind[i] == L_INS {
                ubyte m = lmn[i]
                if m == M_LDY
                    zero = lok[i] == O_NUM and lval[i] == 0
                else if m == M_INY or m == M_DEY or m == M_TAY or m == M_PLY or m == M_JSR
                    zero = false
                else if zero and lok[i] == O_OTHER and (m == M_LDA or m == M_STA or (m >= M_ADC and m <= M_CMP)) {
                    ^^strtab.Sym s = lsym[i]
                    if s.mark & K_USEY != 0 and s.text[0] == '(' {
                        long n = buf.cstr_len(s.text)
                        if n > 3 and s.text[n - 3] == ')' and s.text[n - 2] == ',' and s.text[n - 1] == 'y' {
                            buf.clear(tb)
                            buf.add_bytes(tb, s.text, n - 2)
                            buf.add_byte(tb, 0)
                            lsym[i] = scanned(tb.data)
                            any = true
                        }
                    }
                }
            }
            else if lkind[i] != L_DEAD
                zero = false
            i++
        }
        return any
    }

    sub clear_label_lines() {
        long i = 0
        while i < count {
            if lkind[i] == L_LABEL {
                ^^strtab.Sym s = lsym[i]
                s.extra = 0
            }
            i++
        }
    }

    ; ---- the passes ----

    sub optimize() {
        thread_jumps()
        repeat 3 {
            changed = false
            region++
            jumps()
            unused_labels()
            unreachable()
            if not changed
                break
        }
        tail_calls()
        repeat 4 {
            changed = false
            forward()
            dead_stores()
            forward_stores()
            fold_operands()
            fold_swapped()
            argument_order()
            word_increment()
            backward()
            if not changed
                break
        }
        if merge_arms() {
            ; (what was stored on both arms may be in A still where it is read)
            forward()
            dead_stores()
            backward()
        }
        ; Once more backward, twice at most, now with what the pass before found at the
        ; labels: a branch back to a label that comes earlier (a loop) then knows what
        ; the loop needs, where the first time it had to assume everything.  (Nothing
        ; else may run in between: the forward pass can make a register needed.)
        repeat 2 {
            changed = false
            use_previous = true
            backward()
            use_previous = false
            if not changed
                break
        }
    }

    sub is_branch(ubyte m) -> bool {
        return m >= M_BNE and m <= M_BVS
    }

    ; is this label one of the labels that directly follow line i?
    sub label_follows(long i, ^^strtab.Sym name) -> bool {
        long j = i + 1
        while j < count {
            if lkind[j] == L_LABEL {
                if lsym[j] == name
                    return true
            }
            else if lkind[j] != L_DEAD
                return false
            j++
        }
        return false
    }

    ; the line before that is still there (the same line when there is none)
    sub previous_live(long i) -> long {
        long j = i
        while j > 0 {
            j--
            if lkind[j] != L_DEAD
                return j
        }
        return i
    }

    sub next_live(long i) -> long {
        i++
        while i < count and lkind[i] == L_DEAD
            i++
        return i
    }

    ; a jump or branch to a label where only a jump stands goes to that jump's target
    sub thread_jumps() {
        long i = 0
        ^^strtab.Sym s
        while i < count {
            if lkind[i] == L_LABEL {
                s = lsym[i]
                if s.mark & K_ANON == 0
                    s.extra = i + 1
            }
            i++
        }
        i = 0
        while i < count {
            if lkind[i] == L_INS and lok[i] == O_OTHER and (lmn[i] == M_JMP or (lmn[i] >= M_BNE and lmn[i] <= M_BRA)) {
                repeat 4 {
                    s = lsym[i]
                    if s.extra == 0 or s.mark & K_ANON != 0
                        break
                    ; the first instruction after the label
                    long j = s.extra
                    while j < count and (lkind[j] == L_LABEL or lkind[j] == L_DEAD)
                        j++
                    if j >= count or lkind[j] != L_INS or lmn[j] != M_JMP or lok[j] != O_OTHER or j == i
                        break
                    ^^strtab.Sym target = lsym[j]
                    if target.mark & K_INDIRECT != 0 or target == s
                        break
                    lsym[i] = target
                }
            }
            i++
        }
        i = 0
        while i < count {
            if lkind[i] == L_LABEL {
                s = lsym[i]
                s.extra = 0
            }
            i++
        }
    }

    ; what follows a jump or a return, up to the next label, is never reached
    sub unreachable() {
        bool reached = true
        long i = 0
        while i < count {
            if lkind[i] == L_INS {
                if not reached
                    drop(i)
                else if lmn[i] == M_JMP or lmn[i] == M_RTS or lmn[i] == M_BRA
                    reached = false
            }
            else if lkind[i] != L_DEAD
                reached = true
            i++
        }
    }

    ; jsr and rts: the subroutine returns for both
    sub tail_calls() {
        long i = 0
        while i < count {
            if lkind[i] == L_INS and lmn[i] == M_JSR and lok[i] == O_OTHER {
                long j = next_live(i)
                if j < count and lkind[j] == L_INS and lmn[j] == M_RTS {
                    lmn[i] = M_JMP
                    lkind[j] = L_DEAD
                }
            }
            i++
        }
    }

    sub jumps() {
        long i = 0
        while i < count {
            if lkind[i] == L_INS and lok[i] == O_OTHER {
                ubyte m = lmn[i]
                if m == M_JMP {
                    if label_follows(i, lsym[i])
                        drop(i)
                }
                else if is_branch(m) {
                    ^^strtab.Sym bs = lsym[i]
                    if (bs.mark & K_ANON == 0 or bs.text[0] == '+') and label_follows(i, bs) {
                        ; to the next line: whatever the condition
                        drop(i)
                        i++
                        continue
                    }
                    ; a branch around a jump (64tass makes a branch that is too far a long one)
                    long j = next_live(i)
                    if j < count and lkind[j] == L_INS and lmn[j] == M_JMP and lok[j] == O_OTHER {
                        ^^strtab.Sym target = lsym[j]
                        if target.mark & K_INDIRECT == 0 and label_follows(j, lsym[i]) {
                            lmn[i] = m ^ 1
                            lsym[i] = target
                            drop(j)
                        }
                    }
                }
            }
            i++
        }
    }

    ; a generated label that no instruction of the region names is not needed, and
    ; without it what the registers hold is known across it
    sub unused_labels() {
        escapes = false
        long i = 0
        ^^strtab.Sym s
        while i < count {
            if lkind[i] == L_INS and (lok[i] == O_OTHER or lok[i] == O_IMMTEXT) {
                s = lsym[i]
                s.stamp = region
                if s.mark & K_ESCAPE != 0
                    escapes = true
            }
            i++
        }
        if escapes
            return
        i = 0
        while i < count {
            if lkind[i] == L_LABEL {
                s = lsym[i]
                if s.mark & K_GENLABEL != 0 and s.stamp != region
                    drop(i)
            }
            i++
        }
    }

    ; -- what the registers and the memory hold: value numbers --
    ; above 0 a constant: 1 to 256 the numbers 0 to 255, from 1000 the texts in immtab;
    ; below 0 a value that is not known, each different

    const ubyte MTAB = 64
    ^^ubyte mtab_kind = 0           ; O_CELL, O_VAR or 0: free
    ^^long mtab_off = 0
    ^^long mtab_value = 0
    ^^pointer mtab_sym = 0
    ubyte mtab_next = 0             ; the entry to give up when the table is full
    const ubyte IMMTAB = 32
    ^^pointer immtab = 0
    ubyte immcount = 0
    long va = 0
    long vx = 0
    long vy = 0
    long freshseq = 0
    bool flags_of_a = false         ; N and Z are those of the value in A
    long flag_line = -1             ; the inc or dec of memory whose N and Z still stand, or -1

    ; the scratch pointer: while it is a copy of a pointer variable in the zero page
    ; (and that still holds what was copied), "(P8ZP_SCRATCH_W1),y" can be "(variable),y"
    ^^strtab.Sym w1lo = 0
    ^^strtab.Sym w1hi = 0
    ^^strtab.Sym w1ind = 0
    pointer w1_sym = 0              ; the variable, or 0
    long w1_off = 0
    long w1_vlo = 0
    long w1_vhi = 0
    pointer pend_sym = 0            ; the low byte was copied from this one
    long pend_off = 0
    long pend_v = 0

    ; the value a variable's byte is known to hold, or 0
    sub variable_value(pointer sym, long off) -> long {
        ubyte k
        for k in 0 to MTAB - 1 {
            if mtab_kind[k] == O_VAR and mtab_off[k] == off and mtab_sym[k] == sym
                return mtab_value[k]
        }
        return 0
    }

    ; what an instruction with an operand that is not followed does to the scratch pointer
    sub scratch_pointer(long i, ubyte m) {
        pointer sym = lsym[i]
        if sym == w1ind {
            if w1_sym != 0 and variable_value(w1_sym, w1_off) == w1_vlo and variable_value(w1_sym, w1_off + 1) == w1_vhi {
                ^^strtab.Sym vs = w1_sym
                buf.clear(tb)
                buf.add_byte(tb, '(')
                buf.add_str(tb, vs.text)
                if w1_off != 0 {
                    buf.add_byte(tb, '+')
                    buf.add_long(tb, w1_off)
                }
                buf.add_str(tb, "),y")
                buf.add_byte(tb, 0)
                lsym[i] = scanned(tb.data)
                changed = true
            }
            return
        }
        ^^strtab.Sym s = sym
        if s.mark & K_W1 == 0
            return
        if m == M_STA and sym == w1lo and lok[i] == O_VAR and lval[i] == 0 {
            w1_sym = 0
            pend_sym = 0
            ubyte k
            for k in 0 to MTAB - 1 {
                if mtab_kind[k] == O_VAR and mtab_value[k] == va {
                    ^^strtab.Sym ks = mtab_sym[k]
                    if ks.mark & K_ZPVAR != 0 {
                        pend_sym = mtab_sym[k]
                        pend_off = mtab_off[k]
                        pend_v = va
                        break
                    }
                }
            }
        }
        else if m == M_STA and sym == w1lo and lok[i] == O_VAR and lval[i] == 1 {
            w1_sym = 0
            if pend_sym != 0 and variable_value(pend_sym, pend_off + 1) == va {
                w1_sym = pend_sym
                w1_off = pend_off
                w1_vlo = pend_v
                w1_vhi = va
            }
            pend_sym = 0
        }
        else if m != M_LDA and m != M_LDX and m != M_LDY and m != M_CMP and m != M_ADC and m != M_SBC {
            ; (anything that may write it)
            w1_sym = 0
            pend_sym = 0
        }
    }

    sub fresh() -> long {
        freshseq--
        return freshseq
    }

    sub forget() {
        va = fresh()
        vx = fresh()
        vy = fresh()
        flags_of_a = false
        flag_line = -1
        w1_sym = 0
        pend_sym = 0
        ubyte k
        for k in 0 to MTAB - 1
            mtab_kind[k] = 0
        mtab_next = 0
    }

    ; A call: the subroutine that is called may change any variable, except the ones
    ; of this subroutine that nothing else names (and whose address nothing has) - when
    ; this subroutine cannot be running a second time inside the call.
    ^^ubyte own_name = 0            ; the subroutine of the region, or 0: nothing is known to stay
    long own_len = 0

    sub own_scope(^^ubyte name) {
        own_name = name
        own_len = 0
        if name != 0
            own_len = buf.cstr_len(name)
    }

    sub own_variable(^^strtab.Sym s) -> bool {
        if own_name == 0 or s.mark & K_SAFE == 0 or s.mark & (K_FOREIGN | K_TAKEN) != 0
            return false
        ^^ubyte t = s.text
        long k = 0
        while k < own_len {
            if t[k] != own_name[k]
                return false
            k++
        }
        if t[k] != '.'
            return false
        k++
        while t[k] != 0 {
            if t[k] == '.'
                return false        ; (of a subroutine inside this one)
            k++
        }
        return true
    }

    sub forget_variables(bool arithmetic) {
        ubyte k
        for k in 0 to MTAB - 1 {
            if mtab_kind[k] == O_VAR {
                ^^strtab.Sym vs = mtab_sym[k]
                ; (the library's multiply and divide routines know nothing of the program's variables)
                if not own_variable(vs) and not (arithmetic and has_prefix(vs.text, "p8b_"))
                    mtab_kind[k] = 0
            }
        }
    }

    ; a store through a pointer or into an array: the variables it could reach
    sub forget_reachable() {
        ubyte k
        for k in 0 to MTAB - 1 {
            if mtab_kind[k] == O_VAR {
                ^^strtab.Sym s = mtab_sym[k]
                if s.mark & K_SAFE == 0
                    mtab_kind[k] = 0
            }
        }
    }

    ; the entry of the memory operand of line i, or -1
    sub find(long i) -> long {
        ubyte kind = lok[i]
        long off = lval[i]
        pointer sym = lsym[i]
        ubyte k
        for k in 0 to MTAB - 1 {
            if mtab_kind[k] == kind and mtab_off[k] == off {
                if kind == O_CELL or mtab_sym[k] == sym
                    return k
            }
        }
        return -1
    }

    sub remember(long i, long value) {
        long at = find(i)
        if at < 0 {
            ubyte k
            for k in 0 to MTAB - 1 {
                if mtab_kind[k] == 0 {
                    at = k
                    break
                }
            }
            if at < 0 {
                at = mtab_next
                mtab_next++
                if mtab_next == MTAB
                    mtab_next = 0
            }
            mtab_kind[at] = lok[i]
            mtab_off[at] = lval[i]
            mtab_sym[at] = lsym[i]
        }
        mtab_value[at] = value
    }

    ; a variable that holds this value, or -1
    sub variable_with(long value) -> long {
        ubyte k
        for k in 0 to MTAB - 1 {
            if mtab_kind[k] == O_VAR and mtab_value[k] == value
                return k
        }
        return -1
    }

    ; Another cell that holds this value: the one with the lowest number, so that every
    ; read of a copy goes to the same cell and the copies are never read (-1: none, or
    ; this cell is that one).
    sub older_cell_with(long value, long cell) -> long {
        long best = -1
        long lowest = cell
        ubyte k
        for k in 0 to MTAB - 1 {
            if mtab_kind[k] == O_CELL and mtab_value[k] == value and mtab_off[k] < lowest {
                lowest = mtab_off[k]
                best = k
            }
        }
        return best
    }

    sub immediate_value(long i) -> long {
        if lok[i] == O_NUM
            return lval[i] + 1
        pointer sym = lsym[i]
        ubyte k = 0
        while k < immcount {
            if immtab[k] == sym
                return 1000 + k
            k++
        }
        if immcount == IMMTAB
            return fresh()
        immtab[immcount] = sym
        immcount++
        return 999 + immcount
    }

    ; the value the operand of line i has, known or new
    sub operand_value(long i) -> long {
        when lok[i] {
            O_NUM, O_IMMTEXT -> return immediate_value(i)
            O_CELL, O_VAR -> {
                long at = find(i)
                if at >= 0
                    return mtab_value[at]
                long v = fresh()
                remember(i, v)
                return v
            }
        }
        return fresh()
    }

    ; a value is written to the operand of line i; a plain store of what is there already is dropped
    sub written(long i, long value, bool plain_store) {
        ubyte ok = lok[i]
        if ok == O_CELL or ok == O_VAR {
            if plain_store {
                long at = find(i)
                if at >= 0 and mtab_value[at] == value {
                    lkind[i] = L_DEAD
                    changed = true
                    return
                }
            }
            remember(i, value)
        }
        else if ok == O_OTHER {
            ^^strtab.Sym s = lsym[i]
            if s.mark & K_INDIRECT != 0 {
                if s.text[0] == '('
                    forget_reachable()
                else
                    forget_indexed(s.text)
            }
        }
    }

    ; A store to "name,x" or "name+2,y": it reaches the bytes after the name, which is
    ; an array.  Only a variable of that very name (or the virtual registers, when it is
    ; one of them) could be what changes.
    sub forget_indexed(^^ubyte t) {
        long n = 0
        while t[n] != 0 and t[n] != ',' and t[n] != '+'
            n++
        bool registers = false
        if vreg_base >= 0 {
            buf.clear(tb)
            buf.add_bytes(tb, t, n)
            buf.add_byte(tb, 0)
            registers = vreg_offset(tb.data) >= 0
        }
        ubyte k
        for k in 0 to MTAB - 1 {
            if mtab_kind[k] == O_VAR {
                ^^strtab.Sym vs = mtab_sym[k]
                if registers and mtab_sym[k] == vreg
                    mtab_kind[k] = 0
                else if buf.cstr_len(vs.text) == n and buf.bytes_equal(vs.text, t, n)
                    mtab_kind[k] = 0
            }
        }
    }

    ; are the N and Z flags that line i sets used by nothing?
    sub flags_unused_after(long i) -> bool {
        long j = i + 1
        while j < count {
            if lkind[j] == L_INS {
                ubyte m = lmn[j]
                if m == M_JSR or m == M_RTS
                    return true
                if m == M_JMP and lreg[j] != 255
                    return true             ; (a call that ends the subroutine)
                if m == M_JMP or (m >= M_BNE and m <= M_BRA)
                    return false
                ubyte p = props[m]
                if p & RNZ != 0
                    return false
                if p & SNZ != 0
                    return true
            }
            else if lkind[j] != L_DEAD
                return false
            j++
        }
        return false
    }

    ; is the carry that line i sets used by nothing?  (Generated code does not carry
    ; it over a label; text the generator wrote itself may do anything.)
    sub carry_unused_after(long i) -> bool {
        long j = i + 1
        while j < count {
            if lkind[j] == L_INS {
                when lmn[j] {
                    M_ADC, M_SBC, M_ROL, M_ROR, M_BCC, M_BCS, M_PHP -> return false
                    ; (a carry argument of a call is set just before the call)
                    M_CMP, M_CPX, M_CPY, M_CLC, M_SEC, M_ASL, M_LSR, M_PLP, M_RTS, M_JMP, M_BRA, M_JSR -> return true
                }
            }
            else if lkind[j] == L_LABEL
                return true
            else if lkind[j] == L_RAW
                return false
            j++
        }
        return false
    }

    sub drop(long i) {
        lkind[i] = L_DEAD
        changed = true
    }

    sub transfer(long i, ubyte m) {
        lmn[i] = m
        lok[i] = O_NONE
        lval[i] = 0
        lsym[i] = 0
        changed = true
    }

    sub forward() {
        forget()
        immcount = 0
        long i = 0
        while i < count {
            if lkind[i] == L_INS
                forward_ins(i)
            else if lkind[i] != L_DEAD
                forget()
            i++
        }
    }

    sub forward_ins(long i) {
        ubyte m = lmn[i]
        ubyte ok = lok[i]
        long v
        long at
        if m <= M_LDY or (m >= M_ADC and m <= M_CPY) {
            ; reads its operand
            v = 0
            if ok == O_NUM or ok == O_IMMTEXT
                v = immediate_value(i)
            else if ok == O_CELL or ok == O_VAR {
                at = find(i)
                if at >= 0
                    v = mtab_value[at]
            }
            if v != 0 {
                when m {
                    M_LDA -> {
                        if va == v {
                            if flags_of_a or flags_unused_after(i) {
                                drop(i)
                                return
                            }
                        }
                        else if vy == v
                            transfer(i, M_TYA)
                        else if vx == v
                            transfer(i, M_TXA)
                    }
                    M_LDY -> {
                        if vy == v {
                            if flags_unused_after(i) {
                                drop(i)
                                return
                            }
                        }
                        else if va == v
                            transfer(i, M_TAY)
                    }
                    M_LDX -> {
                        if vx == v {
                            if flags_unused_after(i) {
                                drop(i)
                                return
                            }
                        }
                        else if va == v
                            transfer(i, M_TAX)
                    }
                }
                m = lmn[i]
                ok = lok[i]
                if ok == O_CELL or ok == O_VAR {
                    if v > 0 {
                        ; the constant itself
                        if v <= 256 {
                            lok[i] = O_NUM
                            lval[i] = v - 1
                            lsym[i] = 0
                        }
                        else {
                            lok[i] = O_IMMTEXT
                            lval[i] = 0
                            lsym[i] = immtab[v - 1000]
                        }
                        changed = true
                    }
                    else if ok == O_CELL {
                        ; the variable the cell is a copy of, or the cell it was copied from
                        at = variable_with(v)
                        if at >= 0 {
                            lok[i] = O_VAR
                            lval[i] = mtab_off[at]
                            lsym[i] = mtab_sym[at]
                            changed = true
                        }
                        else {
                            at = older_cell_with(v, lval[i])
                            if at >= 0 {
                                lval[i] = mtab_off[at]
                                changed = true
                            }
                        }
                    }
                }
            }
        }
        if ((m == M_ORA or m == M_EOR) and ok == O_NUM and lval[i] == 0) or (m == M_AND and ok == O_NUM and lval[i] == 255) {
            ; changes nothing but the flags
            if flags_of_a or flags_unused_after(i) {
                drop(i)
                return
            }
        }
        if m == M_ADC and va == 1 {
            ; zero plus the operand, with the carry just cleared: a load (the carry stays clear)
            long zl = previous_live(i)
            long cl = previous_live(zl)
            if zl < i and cl < zl and lkind[zl] == L_INS and lmn[zl] == M_LDA and lok[zl] == O_NUM
                    and lkind[cl] == L_INS and lmn[cl] == M_CLC {
                lmn[i] = M_LDA
                m = M_LDA
                drop(zl)
            }
        }
        if ((m == M_ORA or m == M_EOR) and va == 1) or (m == M_AND and va == 256) {
            ; with a zero (or all ones) in A the operation is a load of the operand
            lmn[i] = M_LDA
            m = M_LDA
            changed = true
        }
        if m == M_LDA and (lok[i] == O_CELL or lok[i] == O_VAR) and flag_line >= 0 and lok[flag_line] == lok[i]
                and lval[flag_line] == lval[i] and lsym[flag_line] == lsym[i] and a_unused_after(i) {
            ; the flags are those of this operand already (it was just incremented or
            ; decremented), and that is all the load is for
            drop(i)
            return
        }
        if m == M_CMP and lok[i] == O_NUM and lval[i] == 0 and flags_of_a {
            ; only the carry is new, and it is 1
            if carry_unused_after(i) {
                drop(i)
                return
            }
        }
        if lok[i] == O_OTHER or (lok[i] == O_VAR and lsym[i] == w1lo)
            scratch_pointer(i, m)
        ubyte p = props[m]
        if p & SNZ != 0 or m == M_JSR or is_store(m) {
            flag_line = -1
            if (m == M_INC or m == M_DEC) and (ok == O_CELL or ok == O_VAR)
                flag_line = i
        }
        if p & SNZ != 0 {
            ; (the transfers out of A and the operations on A set them from A's value too)
            flags_of_a = p & WA != 0 or m == M_TAX or m == M_TAY
            if m >= M_INC and m <= M_ROR
                flags_of_a = ok == O_ACC or ok == O_NONE
        }
        if m == M_JSR
            flags_of_a = false
        when m {
            M_LDA -> va = operand_value(i)
            M_LDX -> vx = operand_value(i)
            M_LDY -> vy = operand_value(i)
            M_STA -> {
                if c02z and va == 1 and direct_operand(i) {
                    ; a zero: stz leaves A free
                    lmn[i] = M_STZ
                    changed = true
                }
                written(i, va, true)
            }
            M_STX -> written(i, vx, true)
            M_STY -> written(i, vy, true)
            M_STZ -> written(i, 1, true)
            M_ADC, M_SBC, M_AND, M_ORA, M_EOR, M_PLA -> va = fresh()
            M_INC, M_DEC, M_ASL, M_LSR, M_ROL, M_ROR -> {
                if ok == O_ACC or ok == O_NONE
                    va = fresh()
                else
                    written(i, fresh(), false)
            }
            M_TSB, M_TRB -> {
                written(i, fresh(), false)
                flags_of_a = false
            }
            M_INX, M_DEX, M_TSX, M_PLX -> vx = fresh()
            M_INY, M_DEY, M_PLY -> vy = fresh()
            M_TAX -> vx = va
            M_TAY -> vy = va
            M_TXA -> va = vx
            M_TYA -> va = vy
            M_JSR -> {
                va = fresh()
                vx = fresh()
                vy = fresh()
                bool arithmetic = false
                if ok == O_OTHER {
                    ^^strtab.Sym callee = lsym[i]
                    arithmetic = has_prefix(callee.text, "prog8_math.")
                }
                forget_variables(arithmetic)
                w1_sym = 0
                pend_sym = 0
            }
        }
    }

    ; an operand that is a plain address
    sub direct_operand(long i) -> bool {
        when lok[i] {
            O_CELL, O_VAR -> return true
            O_OTHER -> {
                ^^strtab.Sym s = lsym[i]
                return s.mark & K_INDIRECT == 0
            }
        }
        return false
    }

    sub is_store(ubyte m) -> bool {
        return m >= M_STA and m <= M_STZ
    }

    ; "lda m / sta cell / lda x / cmp cell", where that is all the cell is for: "lda x /
    ; cmp m".  What is in between only loads and computes in A (so neither the memory
    ; nor an index register changes), and starts with a load, so that m is still read
    ; once.
    sub fold_operands() {
        long i = 1
        while i < count {
            if lkind[i] == L_INS and lmn[i] == M_STA and lok[i] == O_CELL {
                long from = previous_live(i)
                long c = lval[i]
                if from < i and lkind[from] == L_INS and lmn[from] == M_LDA and lok[from] != O_NONE and lok[from] != O_ACC
                        and lok[from] != O_NUM and lok[from] != O_IMMTEXT and not (lok[from] == O_CELL and lval[from] == c) {
                    long k = next_live(i)
                    long use = -1
                    if k < count and lkind[k] == L_INS and lmn[k] == M_LDA and not (lok[k] == O_CELL and lval[k] == c) {
                        k = next_live(k)
                        ubyte steps = 0
                        while k < count and steps < 6 and lkind[k] == L_INS {
                            ubyte km = lmn[k]
                            if not (km == M_LDA or km == M_CLC or km == M_SEC or (km >= M_ADC and km <= M_CMP))
                                break
                            if lok[k] == O_CELL and lval[k] == c {
                                if km != M_LDA
                                    use = k
                                break
                            }
                            k = next_live(k)
                            steps++
                        }
                    }
                    if use >= 0 {
                        ; nothing else reads the cell
                        long reads = 0
                        long j = 0
                        while j < count {
                            if lkind[j] == L_INS and lok[j] == O_CELL and lval[j] == c and not is_store(lmn[j])
                                reads++
                            j++
                        }
                        if reads == 1 {
                            lok[use] = lok[from]
                            lval[use] = lval[from]
                            lsym[use] = lsym[from]
                            drop(i)
                        }
                    }
                }
            }
            i++
        }
    }

    ; "sta cell / clc / lda x / adc cell", with the cell for nothing else: "clc / adc x"
    ; (the same for and, ora and eor, where the order of the two does not matter either).
    sub fold_swapped() {
        long i = 0
        while i < count {
            if lkind[i] == L_INS and lmn[i] == M_STA and lok[i] == O_CELL {
                long c = lval[i]
                long l1 = next_live(i)
                long l2 = l1
                bool carry = false
                if l1 < count and lkind[l1] == L_INS and lmn[l1] == M_CLC {
                    carry = true
                    l1 = next_live(l1)
                }
                if l1 < count
                    l2 = next_live(l1)
                if l2 < count and l2 > l1 and lkind[l1] == L_INS and lmn[l1] == M_LDA and lok[l1] != O_NONE and lok[l1] != O_ACC
                        and not (lok[l1] == O_CELL and lval[l1] == c)
                        and lkind[l2] == L_INS and lok[l2] == O_CELL and lval[l2] == c
                        and ((lmn[l2] == M_ADC and carry) or (not carry and (lmn[l2] == M_AND or lmn[l2] == M_ORA or lmn[l2] == M_EOR))) {
                    if cell_lines(c) == 2 {
                        lok[l2] = lok[l1]
                        lval[l2] = lval[l1]
                        lsym[l2] = lsym[l1]
                        drop(l1)
                        drop(i)
                    }
                }
            }
            i++
        }
    }

    ; Two arguments, the first computed into a cell because the second needs A:
    ; "lda m1 / dec a / sta cell / lda m2 / dec a / tay / lda cell / jsr".  The second
    ; first, and the cell is not needed: "lda m2 / dec a / tay / lda m1 / dec a / jsr".
    long[12] arg_lines
    ubyte[12] arg_mn
    ubyte[12] arg_ok
    long[12] arg_val
    pointer[12] arg_sym

    sub argument_order() {
        long i = 0
        while i < count {
            if lkind[i] == L_INS and lmn[i] == M_LDA and plain_operand(i) {
                ; the first block: a load, operations on A, the store to a cell
                ubyte n = 0
                long k = i
                long store = -1
                while n < 5 and k < count and lkind[k] == L_INS {
                    if n > 0 and lmn[k] == M_STA and lok[k] == O_CELL {
                        store = k
                        break
                    }
                    if n > 0 and not accumulator_step(k)
                        break
                    arg_lines[n] = k
                    n++
                    k = next_live(k)
                }
                if store >= 0 {
                    ubyte first = n
                    long c = lval[store]
                    arg_lines[n] = store
                    n++
                    ; the second block: a load, operations on A, tay
                    k = next_live(store)
                    long transfer = -1
                    if k < count and lkind[k] == L_INS and lmn[k] == M_LDA and plain_operand(k) and not (lok[k] == O_CELL and lval[k] == c) {
                        while n < 11 and k < count and lkind[k] == L_INS {
                            arg_lines[n] = k
                            n++
                            if lmn[k] == M_TAY {
                                transfer = k
                                break
                            }
                            if k != arg_lines[first + 1] and not accumulator_step(k)
                                break
                            k = next_live(k)
                        }
                    }
                    if transfer >= 0 {
                        long reload = next_live(transfer)
                        long callat = reload
                        if reload < count
                            callat = next_live(reload)
                        if callat < count and callat > reload and lkind[reload] == L_INS and lmn[reload] == M_LDA and lok[reload] == O_CELL and lval[reload] == c
                                and lkind[callat] == L_INS and (lmn[callat] == M_JSR or (lmn[callat] == M_JMP and lreg[callat] != 255))
                                and cell_lines(c) == 2 {
                            arg_lines[n] = reload
                            n++
                            ; the lines of the second block, then those of the first without the store
                            ubyte j
                            for j in 0 to n - 1 {
                                arg_mn[j] = lmn[arg_lines[j]]
                                arg_ok[j] = lok[arg_lines[j]]
                                arg_val[j] = lval[arg_lines[j]]
                                arg_sym[j] = lsym[arg_lines[j]]
                            }
                            ubyte at = 0
                            for j in first + 1 to n - 2 {
                                set_line(arg_lines[at], arg_mn[j], arg_ok[j], arg_val[j], arg_sym[j])
                                at++
                            }
                            for j in 0 to first - 1 {
                                set_line(arg_lines[at], arg_mn[j], arg_ok[j], arg_val[j], arg_sym[j])
                                at++
                            }
                            while at < n {
                                drop(arg_lines[at])
                                at++
                            }
                            changed = true
                            i = callat
                        }
                    }
                }
            }
            i++
        }
    }

    ; an operation on A alone, with a constant or none: inc a, asl a, clc, adc #1, and #15
    sub accumulator_step(long k) -> bool {
        ubyte m = lmn[k]
        if m == M_CLC or m == M_SEC
            return true
        if m >= M_INC and m <= M_LSR
            return lok[k] == O_ACC or lok[k] == O_NONE
        if m == M_ADC or m == M_SBC {
            ; (with its own carry: the blocks change places)
            long before = previous_live(k)
            return lok[k] == O_NUM and before < k and lkind[before] == L_INS and (lmn[before] == M_CLC or lmn[before] == M_SEC)
        }
        if m >= M_AND and m <= M_EOR
            return lok[k] == O_NUM
        return false
    }

    ; A word plus one that is only an argument: "sta c0 / sty c1 / inc c0 / bne + /
    ; inc c1 / + / ldy c1 / lda c0 / jsr" is "clc / adc #1 / bcc + / iny / + / jsr", and
    ; when the word was loaded into the cells from two plain operands they are loaded
    ; into A and Y instead.  The cells are for nothing else.
    sub word_increment() {
        long i = 2
        while i < count {
            if lkind[i] == L_INS and lmn[i] == M_INC and lok[i] == O_CELL {
                long c0 = lval[i]
                long l1 = next_live(i)
                long l2 = l1
                long l3 = l1
                long l4 = l1
                long l5 = l1
                long l6 = l1
                if l1 < count
                    l2 = next_live(l1)
                if l2 < count
                    l3 = next_live(l2)
                if l3 < count
                    l4 = next_live(l3)
                if l4 < count
                    l5 = next_live(l4)
                if l5 < count
                    l6 = next_live(l5)
                if l6 < count and increment_shape(i, l1, l2, l3, l4, l5, l6) {
                    long c1 = lval[l2]
                    long p1 = previous_live(i)
                    long p2 = previous_live(p1)
                    long p3 = previous_live(p2)
                    long p4 = previous_live(p3)
                    bool done = false
                    if cell_lines(c0) == 3 and cell_lines(c1) == 3 and c0 != c1 {
                        if lkind[p1] == L_INS and lkind[p2] == L_INS and p2 < p1
                                and ((lmn[p1] == M_STY and lok[p1] == O_CELL and lval[p1] == c1 and lmn[p2] == M_STA and lok[p2] == O_CELL and lval[p2] == c0)
                                or (lmn[p2] == M_STY and lok[p2] == O_CELL and lval[p2] == c1 and lmn[p1] == M_STA and lok[p1] == O_CELL and lval[p1] == c0)) {
                            ; in A and Y already
                            drop(p1)
                            drop(p2)
                            done = true
                        }
                        else if p4 < p3 and lkind[p1] == L_INS and lkind[p2] == L_INS and lkind[p3] == L_INS and lkind[p4] == L_INS
                                and lmn[p1] == M_STA and lok[p1] == O_CELL and lval[p1] == c1 and lmn[p2] == M_LDA and plain_operand(p2)
                                and lmn[p3] == M_STA and lok[p3] == O_CELL and lval[p3] == c0 and lmn[p4] == M_LDA and plain_operand(p4) {
                            ; "lda m0 / sta c0 / lda m1 / sta c1": "ldy m1 / lda m0"
                            ubyte k0 = lok[p4]
                            long v0 = lval[p4]
                            pointer s0 = lsym[p4]
                            lmn[p4] = M_LDY
                            lok[p4] = lok[p2]
                            lval[p4] = lval[p2]
                            lsym[p4] = lsym[p2]
                            lmn[p3] = M_LDA
                            lok[p3] = k0
                            lval[p3] = v0
                            lsym[p3] = s0
                            drop(p2)
                            drop(p1)
                            done = true
                        }
                    }
                    if done {
                        ^^strtab.Sym plus = lsym[l1]
                        lmn[i] = M_CLC
                        lok[i] = O_NONE
                        lval[i] = 0
                        lsym[i] = 0
                        lmn[l1] = M_ADC
                        lok[l1] = O_NUM
                        lval[l1] = 1
                        lsym[l1] = 0
                        lmn[l2] = M_BCC
                        lok[l2] = O_OTHER
                        lval[l2] = 0
                        lsym[l2] = plus
                        lkind[l3] = L_INS
                        lmn[l3] = M_INY
                        lok[l3] = O_NONE
                        lval[l3] = 0
                        lsym[l3] = 0
                        lreg[l3] = 255
                        lkind[l4] = L_LABEL
                        lsym[l4] = plus
                        drop(l5)
                    }
                }
            }
            i++
        }
    }

    ; inc c0 (i) / bne + / inc c1 / + / ldy c1 / lda c0 / a call or the return
    sub increment_shape(long i, long l1, long l2, long l3, long l4, long l5, long l6) -> bool {
        if lkind[l1] != L_INS or lmn[l1] != M_BNE or lok[l1] != O_OTHER
            return false
        ^^strtab.Sym plus = lsym[l1]
        if plus.mark & K_ANON == 0 or plus.text[0] != '+'
            return false
        if lkind[l2] != L_INS or lmn[l2] != M_INC or lok[l2] != O_CELL
            return false
        if lkind[l3] != L_LABEL or lsym[l3] != plus
            return false
        if lkind[l4] != L_INS or lmn[l4] != M_LDY or lok[l4] != O_CELL or lval[l4] != lval[l2]
            return false
        if lkind[l5] != L_INS or lmn[l5] != M_LDA or lok[l5] != O_CELL or lval[l5] != lval[i]
            return false
        if lkind[l6] != L_INS
            return false
        return lmn[l6] == M_JSR or lmn[l6] == M_RTS or (lmn[l6] == M_JMP and lreg[l6] != 255)
    }

    ; a number, an address, a variable or a cell: an operand that any register loads
    sub plain_operand(long i) -> bool {
        return lok[i] == O_NUM or lok[i] == O_IMMTEXT or lok[i] == O_VAR or lok[i] == O_CELL
    }

    ; on how many lines is the cell named?
    sub cell_lines(long c) -> long {
        long n = 0
        long j = 0
        while j < count {
            if lkind[j] == L_INS and lok[j] == O_CELL and lval[j] == c
                n++
            j++
        }
        return n
    }

    ; stores to the cells that nothing in the region reads
    sub dead_stores() {
        stampseq++
        long i = 0
        while i < count {
            if lkind[i] == L_INS and lok[i] == O_CELL and not is_store(lmn[i])
                cellstamp[lval[i]] = stampseq
            i++
        }
        i = 0
        while i < count {
            if lkind[i] == L_INS and lok[i] == O_CELL and is_store(lmn[i]) {
                if cellstamp[lval[i]] != stampseq
                    drop(i)
            }
            i++
        }
    }

    ; is A used by nothing after line i?
    sub a_unused_after(long i) -> bool {
        long j = i + 1
        while j < count {
            if lkind[j] == L_INS {
                ubyte m = lmn[j]
                if m == M_JSR or m == M_RTS or m == M_JMP or (m >= M_BNE and m <= M_BRA)
                    return false
                ubyte p = props[m]
                if p & RA != 0
                    return false
                if m >= M_INC and m <= M_ROR and (lok[j] == O_ACC or lok[j] == O_NONE)
                    return false
                if p & WA != 0
                    return true
            }
            else if lkind[j] != L_DEAD
                return false
            j++
        }
        return false
    }

    ; "sta cell ... lda cell / sta variable", the cell used for nothing else: the first
    ; store goes to the variable.  Nothing in between may touch the variable, so no
    ; call, no label, and no indexed or indirect operand.
    sub forward_stores() {
        stampseq++
        long i = 0
        long c
        while i < count {
            if lkind[i] == L_INS and lok[i] == O_CELL {
                c = lval[i]
                if cellstamp[c] != stampseq {
                    cellstamp[c] = stampseq
                    cellreads[c] = 0
                    cellstores[c] = 0
                }
                if is_store(lmn[i])
                    cellstores[c]++
                else
                    cellreads[c]++
            }
            i++
        }
        long block = 1
        i = 0
        while i < count {
            if lkind[i] == L_DEAD {
                i++
                continue
            }
            if lkind[i] != L_INS {
                block++
                i++
                continue
            }
            ubyte m = lmn[i]
            if m == M_JSR or m == M_RTS or m == M_JMP or (m >= M_BNE and m <= M_BRA)
                block++
            else if lok[i] == O_CELL {
                c = lval[i]
                if m == M_STA or m == M_STX or m == M_STY {
                    cellline[c] = i
                    cellblock[c] = block
                }
                else if m == M_LDA and cellreads[c] == 1 and cellstores[c] == 1 and cellblock[c] == block {
                    long j = next_live(i)
                    if j < count and lkind[j] == L_INS and lmn[j] == M_STA and lok[j] == O_VAR {
                        if untouched_between(cellline[c], i, j) and a_unused_after(j) and flags_unused_after(j) {
                            long first = cellline[c]
                            lok[first] = O_VAR
                            lval[first] = lval[j]
                            lsym[first] = lsym[j]
                            drop(i)
                            drop(j)
                        }
                    }
                }
                else if m == M_LDA and cellreads[c] == 1 and cellstores[c] >= 2 and arms_enabled
                    forward_arms(i, c)
            }
            i++
        }
    }

    ; "lda #a / sta x / jmp done / other: / lda #b / sta x / done:" - two constants into
    ; the same place - with one store for both and a short branch that is always taken:
    ; "lda #a / beq-or-bne done / other: / lda #b / done: / sta x".  The label "done"
    ; moves in front of the store, so nothing else may jump to it.
    sub merge_arms() -> bool {
        bool any = false
        long[8] at
        long i = 0
        while i < count {
            if lkind[i] == L_INS and lmn[i] == M_LDA and lok[i] == O_NUM {
                ; the seven lines of the pattern, from this load
                at[0] = i
                ubyte n = 1
                while n < 7 {
                    at[n] = next_live(at[n - 1])
                    if at[n] >= count
                        break
                    n++
                }
                if n == 7 and arms_shape(at[0], at[1], at[2], at[3], at[4], at[5], at[6]) {
                    long first_value = lval[at[0]]
                    ^^strtab.Sym done = lsym[at[2]]
                    ^^strtab.Sym other = lsym[at[3]]
                    long second_value = lval[at[4]]
                    ; line 1: the branch; 2: the other label; 3: the second load; 4: done; 5: the store
                    ; (the store of line 5 is the same as that of line 1, and stays where it is)
                    lkind[at[1]] = L_INS
                    if first_value == 0
                        lmn[at[1]] = M_BEQ
                    else
                        lmn[at[1]] = M_BNE
                    lok[at[1]] = O_OTHER
                    lsym[at[1]] = done
                    lval[at[1]] = 0
                    lreg[at[1]] = 255
                    lkind[at[2]] = L_LABEL
                    lsym[at[2]] = other
                    lkind[at[3]] = L_INS
                    lmn[at[3]] = M_LDA
                    lok[at[3]] = O_NUM
                    lval[at[3]] = second_value
                    lsym[at[3]] = 0
                    lreg[at[3]] = 255
                    lkind[at[4]] = L_LABEL
                    lsym[at[4]] = done
                    lkind[at[6]] = L_DEAD
                    any = true
                    changed = true
                    i = at[6]
                }
            }
            if c02z and lkind[i] == L_INS and (lmn[i] == M_STZ or (lmn[i] == M_LDA and lok[i] == O_NUM)) {
                ; the same where one of the two stores a zero with stz: six lines
                at[0] = i
                n = 1
                while n < 6 {
                    at[n] = next_live(at[n - 1])
                    if at[n] >= count
                        break
                    n++
                }
                if n == 6 and lkind[at[5]] == L_LABEL {
                    ^^strtab.Sym done6 = lsym[at[5]]
                    long store = -1
                    long jump = -1
                    if lmn[i] == M_STZ and line_is(at[1], M_JMP) and lkind[at[2]] == L_LABEL and line_is(at[3], M_LDA)
                            and lok[at[3]] == O_NUM and line_is(at[4], M_STA) {
                        ; stz x / jmp done / other: / lda #b / sta x / done:
                        store = at[4]
                        jump = at[1]
                    }
                    else if lmn[i] == M_LDA and line_is(at[1], M_STA) and line_is(at[2], M_JMP) and lkind[at[3]] == L_LABEL
                            and line_is(at[4], M_STZ) {
                        ; lda #a / sta x / jmp done / other: / stz x / done:
                        store = at[1]
                        jump = at[2]
                    }
                    if store >= 0 and lok[jump] == O_OTHER and lsym[jump] == done6 and direct_operand(store)
                            and lok[at[0]] != O_NONE and only_jump_to(done6, jump) {
                        long zero = at[4]
                        if lmn[i] == M_STZ
                            zero = at[0]
                        if lok[zero] == lok[store] and lval[zero] == lval[store] and lsym[zero] == lsym[store] {
                            ubyte sk = lok[store]
                            long sv = lval[store]
                            pointer ss = lsym[store]
                            if lmn[i] == M_STZ {
                                ^^strtab.Sym other6 = lsym[at[2]]
                                long b6 = lval[at[3]]
                                set_line(at[0], M_LDA, O_NUM, 0, 0)
                                set_line(at[1], M_BEQ, O_OTHER, 0, done6)
                                lkind[at[2]] = L_LABEL
                                lsym[at[2]] = other6
                                set_line(at[3], M_LDA, O_NUM, b6, 0)
                            }
                            else {
                                ^^strtab.Sym other7 = lsym[at[3]]
                                if lval[at[0]] == 0
                                    set_line(at[1], M_BEQ, O_OTHER, 0, done6)
                                else
                                    set_line(at[1], M_BNE, O_OTHER, 0, done6)
                                lkind[at[2]] = L_LABEL
                                lsym[at[2]] = other7
                                set_line(at[3], M_LDA, O_NUM, 0, 0)
                            }
                            lkind[at[4]] = L_LABEL
                            lsym[at[4]] = done6
                            set_line(at[5], M_STA, sk, sv, ss)
                            any = true
                            changed = true
                            i = at[5]
                        }
                    }
                }
            }
            i++
        }
        return any
    }

    sub line_is(long i, ubyte m) -> bool {
        return lkind[i] == L_INS and lmn[i] == m
    }

    sub set_line(long i, ubyte m, ubyte kind, long value, pointer sym) {
        lkind[i] = L_INS
        lmn[i] = m
        lok[i] = kind
        lval[i] = value
        lsym[i] = sym
        lreg[i] = 255
    }

    ; is the jump on this line all that goes to the label (one that the generator made)?
    sub only_jump_to(^^strtab.Sym done, long jump) -> bool {
        if done.mark & K_ANON != 0 or done.mark & K_GENLABEL == 0
            return false
        long k = 0
        while k < count {
            if k != jump and lkind[k] == L_INS and (lok[k] == O_OTHER or lok[k] == O_IMMTEXT) and lsym[k] == done
                return false
            k++
        }
        return true
    }

    sub copy_line(long from, long dst) {
        lkind[dst] = lkind[from]
        lmn[dst] = lmn[from]
        lok[dst] = lok[from]
        lval[dst] = lval[from]
        lsym[dst] = lsym[from]
        lreg[dst] = lreg[from]
    }

    ; lda #a (l0) / sta x (l1) / jmp done (l2) / other: (l3) / lda #b (l4) / sta x (l5) / done: (l6)
    sub arms_shape(long l0, long l1, long l2, long l3, long l4, long l5, long l6) -> bool {
        if lkind[l1] != L_INS or lmn[l1] != M_STA or not direct_operand(l1)
            return false
        if lkind[l2] != L_INS or lmn[l2] != M_JMP or lok[l2] != O_OTHER
            return false
        if lkind[l3] != L_LABEL or lkind[l4] != L_INS or lmn[l4] != M_LDA or lok[l4] != O_NUM
            return false
        if lkind[l5] != L_INS or lmn[l5] != M_STA or lok[l5] != lok[l1] or lval[l5] != lval[l1] or lsym[l5] != lsym[l1]
            return false
        if lkind[l6] != L_LABEL or lsym[l6] != lsym[l2]
            return false
        ^^strtab.Sym done = lsym[l2]
        if done.mark & K_ANON != 0 or done.mark & K_GENLABEL == 0
            return false
        ; nothing else goes to "done"
        long k = 0
        while k < count {
            if k != l2 and lkind[k] == L_INS and (lok[k] == O_OTHER or lok[k] == O_IMMTEXT) and lsym[k] == done
                return false
            k++
        }
        return true
    }

    ; The same when the cell is stored on several ways that meet before the copy (the
    ; two arms of a condition that makes a 0 or a 1): every one of them stores into
    ; the variable.  All of it must be a closed piece of code: no call, no branch out
    ; of it, nothing that touches the variable.
    bool arms_enabled = true

    sub forward_arms(long i, long c) {
        long j = next_live(i)
        if j >= count or lkind[j] != L_INS or lmn[j] != M_STA or lok[j] != O_VAR
            return
        if not a_unused_after(j) or not flags_unused_after(j)
            return
        ; the stores, going back
        long first = i
        long found = 0
        ubyte steps = 0
        while first > 0 and found < cellstores[c] and steps < 64 {
            first--
            steps++
            if lkind[first] == L_INS and lok[first] == O_CELL and lval[first] == c {
                if lmn[first] != M_STA
                    return
                found++
            }
        }
        if found != cellstores[c]
            return
        long k = first + 1
        ^^strtab.Sym s
        while k < i {
            if lkind[k] == L_RAW
                return
            if lkind[k] == L_INS {
                ubyte m = lmn[k]
                if m == M_JSR or m == M_RTS
                    return
                if lok[k] == O_VAR and lsym[k] == lsym[j] and lval[k] == lval[j]
                    return
                if lok[k] == O_OTHER {
                    s = lsym[k]
                    if m == M_JMP or (m >= M_BNE and m <= M_BRA) {
                        ; it must stay inside
                        if s.mark & K_ANON != 0
                            return
                        bool inside = false
                        long t = first + 1
                        while t <= i {
                            if lkind[t] == L_LABEL and lsym[t] == s {
                                inside = true
                                break
                            }
                            t++
                        }
                        if not inside
                            return
                    }
                    else if s.mark & K_INDIRECT != 0
                        return
                }
            }
            k++
        }
        ; each store must be on a way of its own: after it, a jump comes before the next
        ; store (else the first is one that is overwritten, and about to be removed)
        bool jumped = true
        k = first
        while k < i {
            if lkind[k] == L_INS {
                if lok[k] == O_CELL and lval[k] == c {
                    if not jumped
                        return
                    jumped = false
                }
                else if lmn[k] == M_JMP or lmn[k] == M_BRA
                    jumped = true
            }
            k++
        }
        k = first
        while k < i {
            if lkind[k] == L_INS and lok[k] == O_CELL and lval[k] == c {
                lok[k] = O_VAR
                lval[k] = lval[j]
                lsym[k] = lsym[j]
            }
            k++
        }
        drop(i)
        drop(j)
    }

    ; does nothing between the two lines touch the variable of line v?
    sub untouched_between(long from, long upto, long v) -> bool {
        long k = from + 1
        while k < upto {
            if lkind[k] == L_INS {
                if lok[k] == O_VAR and lsym[k] == lsym[v] and lval[k] == lval[v]
                    return false
                if lok[k] == O_OTHER {
                    ^^strtab.Sym s = lsym[k]
                    if s.mark & K_INDIRECT != 0
                        return false
                }
            }
            k++
        }
        return true
    }

    ; loads and transfers into a register that nothing uses before it is loaded again,
    ; and stores to a cell that is written again before anything reads it
    ; "name,x" or "name+2,y" of a plain variable (an array of the program): reading it
    ; is reading memory and nothing else
    sub indexed_plain(^^strtab.Sym s) -> bool {
        ^^ubyte t = s.text
        if t[0] == '('
            return false
        long n = 0
        while t[n] != 0 and t[n] != ',' and t[n] != '+'
            n++
        long comma = n
        while t[comma] != 0 and t[comma] != ','
            comma++
        if t[comma] == 0 or n == 0
            return false
        ^^strtab.Sym base = strtab.intern_sym(t, n as uword)
        return base.mark & K_PLAIN != 0
    }

    ; may a "+" be put after this line?  Not when a branch before it goes to a "+"
    ; further on, which would then stop at the new one.
    sub no_open_plus(long at_line) -> bool {
        long j = at_line
        while j > 0 {
            j--
            if lkind[j] == L_RAW
                return false
            if lkind[j] == L_LABEL {
                ^^strtab.Sym ls = lsym[j]
                if ls.mark & K_ANON != 0 and ls.text[0] == '+'
                    return true
            }
            if lkind[j] == L_INS and lok[j] == O_OTHER and lsym[j] != 0 {
                ^^strtab.Sym bs = lsym[j]
                if bs.mark & K_ANON != 0 and bs.text[0] == '+'
                    return false
            }
        }
        return true
    }

    sub backward() {
        bool la = true
        bool lx = true
        bool ly = true
        bool lnz = true
        bool lc = true                  ; the carry
        bool w1lo_live = true
        bool w1hi_live = true
        long i = count
        killseq++
        bwseq++
        while i > 0 {
            i--
            if lkind[i] == L_DEAD
                continue
            if lkind[i] == L_LABEL {
                ; What the code after a label needs is what every way into it has to
                ; provide, so nothing changes here; it is noted for the branches to
                ; the label that come before it in the text.
                ^^strtab.Sym ls = lsym[i]
                if ls.mark & K_ANON != 0 and ls.text[0] == '-'
                    continue            ; (branches to it come later in the text: they assume everything)
                long bits = 0
                if la
                    bits |= 1
                if lx
                    bits |= 2
                if ly
                    bits |= 4
                if lnz
                    bits |= 8
                if w1lo_live
                    bits |= 16
                if w1hi_live
                    bits |= 32
                if lc
                    bits |= 64
                ls.live = (bwseq << 8) | bits
                continue
            }
            if lkind[i] != L_INS {
                la = true
                lx = true
                ly = true
                lnz = true
                lc = true
                w1lo_live = true
                w1hi_live = true
                killseq++
                continue
            }
            ubyte m = lmn[i]
            ubyte ok = lok[i]
            ; what a jump's or branch's target needs: known when the label was passed already
            ubyte tb = 127
            if (m == M_JMP or (m >= M_BNE and m <= M_BRA)) and ok == O_OTHER {
                ^^strtab.Sym ts = lsym[i]
                if (ts.live >> 8) == bwseq or (use_previous and (ts.live >> 8) == bwseq - 1)
                    tb = (ts.live & 127) as ubyte
            }
            if m == M_JMP and lreg[i] != 255 {
                tb = (lreg[i] & 7) | 48         ; a call that ends the subroutine: its arguments
                if lreg[i] & 8 != 0
                    tb |= 64
            }
            if m == M_RTS {
                ; (the scratch pointer means nothing to a caller)
                w1lo_live = false
                w1hi_live = false
            }
            else if m == M_JSR {
                ; the scratch pointer is an argument of some routines of the runtime library
                ; only; a subroutine of the program does not look at what is in it
                bool takes = true
                if ok == O_OTHER {
                    ^^strtab.Sym js2 = lsym[i]
                    takes = has_prefix(js2.text, "prog8_") or has_prefix(js2.text, "floats.") or js2.mark & K_INDIRECT != 0
                }
                w1lo_live = takes
                w1hi_live = takes
            }
            else if m == M_JMP or m == M_BRA {
                w1lo_live = tb & 16 != 0
                w1hi_live = tb & 32 != 0
            }
            else if m >= M_BNE and m <= M_BVS {
                if tb & 16 != 0
                    w1lo_live = true
                if tb & 32 != 0
                    w1hi_live = true
            }
            else if ok == O_OTHER or (ok == O_VAR and lsym[i] == w1lo) {
                ^^strtab.Sym ws = lsym[i]
                if ws.mark & K_W1 != 0 {
                    if m == M_STA and ok == O_VAR and lval[i] == 0 {
                        if not w1lo_live {
                            drop(i)
                            continue
                        }
                        w1lo_live = false
                    }
                    else if m == M_STA and ok == O_VAR and lval[i] == 1 {
                        if not w1hi_live {
                            drop(i)
                            continue
                        }
                        w1hi_live = false
                    }
                    else {
                        w1lo_live = true
                        w1hi_live = true
                    }
                }
            }
            if ok == O_CELL {
                if is_store(m) {
                    if cellkill[lval[i]] == killseq {
                        drop(i)
                        continue
                    }
                    cellkill[lval[i]] = killseq
                }
                else
                    cellkill[lval[i]] = 0
            }
            if m == M_RTS or m == M_JMP or (m >= M_BNE and m <= M_BRA)
                killseq++           ; (the cells are still read where a branch goes)
            if m == M_JSR or m == M_RTS {
                ; the registers are arguments or results (all of them when it is not known
                ; which); the flags are neither
                ubyte passed = lreg[i]
                ; the carry: a subroutine of the program neither takes nor gives it (8: it may)
                lc = false
                if passed == 255
                    lc = true
                else if m == M_JSR and passed & 8 != 0
                    lc = true
                if passed == 255
                    passed = 7
                la = passed & 1 != 0
                lx = passed & 2 != 0
                ly = passed & 4 != 0
                lnz = false
                continue
            }
            if m == M_JMP or m == M_BRA {
                la = tb & 1 != 0
                lx = tb & 2 != 0
                ly = tb & 4 != 0
                lnz = tb & 8 != 0
                lc = tb & 64 != 0
                continue
            }
            if m >= M_BNE and m <= M_BVS {
                ; what follows, and what the target needs
                if tb & 1 != 0
                    la = true
                if tb & 2 != 0
                    lx = true
                if tb & 4 != 0
                    ly = true
                if tb & 8 != 0 or m <= M_BPL
                    lnz = true          ; (bne, beq, bmi and bpl read the flags themselves)
                if tb & 64 != 0 or m == M_BCC or m == M_BCS
                    lc = true
                continue
            }
            if m == M_LDA and not la and (ok == O_CELL or ok == O_VAR) {
                ; a load only for the flags, of what was just incremented or decremented:
                ; they are set already
                long qj = i
                while qj > 0 {
                    qj--
                    if lkind[qj] != L_DEAD
                        break
                }
                if qj < i and lkind[qj] == L_INS and (lmn[qj] == M_INC or lmn[qj] == M_DEC) and lok[qj] == ok
                        and lval[qj] == lval[i] and lsym[qj] == lsym[i] {
                    drop(i)
                    continue
                }
            }
            if use_previous and m == M_STA and not la and not lc and not lnz and (ok == O_CELL or ok == O_VAR or ok == O_POOL) {
                ; "lda hi / adc #0 / sta hi", the carry of a byte added to a word, with
                ; neither A nor the flags wanted after it: "bcc + / inc hi / +"; and
                ; "bcs + / dec hi / +" for sbc #0.  Only in the last runs: a label makes
                ; the forward pass forget what it knows.
                long h1 = previous_live(i)
                long h2 = previous_live(h1)
                if h2 < h1 and h1 < i and lkind[h1] == L_INS and (lmn[h1] == M_ADC or lmn[h1] == M_SBC)
                        and lok[h1] == O_NUM and lval[h1] == 0
                        and lkind[h2] == L_INS and lmn[h2] == M_LDA and lok[h2] == ok
                        and lval[h2] == lval[i] and lsym[h2] == lsym[i] and no_open_plus(h2) {
                    ^^strtab.Sym plus = scanned("+")
                    plus.mark |= K_ANON
                    ubyte carry_branch = M_BCC
                    ubyte carry_step = M_INC
                    if lmn[h1] == M_SBC {
                        carry_branch = M_BCS
                        carry_step = M_DEC
                    }
                    set_line(h1, carry_step, ok, lval[i], lsym[i])
                    set_line(h2, carry_branch, O_OTHER, 0, plus)
                    lkind[i] = L_LABEL
                    lsym[i] = plus
                    changed = true
                    i++                 ; (once more, as the label it is now)
                    continue
                }
            }
            if m == M_STA and not la and not lc and (ok == O_CELL or ok == O_VAR) {
                ; "lda x / clc / adc #1 / sta x" (or "inc a" for the two in the middle) with
                ; neither A nor the carry wanted after it: "inc x".  The same for dec.
                long s1 = previous_live(i)
                long s2 = previous_live(s1)
                long s3 = previous_live(s2)
                ubyte step = 255
                if lkind[s1] == L_INS and (lmn[s1] == M_INC or lmn[s1] == M_DEC) and (lok[s1] == O_ACC or lok[s1] == O_NONE) {
                    step = lmn[s1]
                    s3 = s2
                    s2 = s1
                }
                else if lkind[s1] == L_INS and lok[s1] == O_NUM and lval[s1] == 1 and lkind[s2] == L_INS {
                    if lmn[s1] == M_ADC and lmn[s2] == M_CLC
                        step = M_INC
                    else if lmn[s1] == M_SBC and lmn[s2] == M_SEC
                        step = M_DEC
                }
                if step != 255 and s3 < s2 and lkind[s3] == L_INS and lmn[s3] == M_LDA and lok[s3] == ok
                        and lval[s3] == lval[i] and lsym[s3] == lsym[i] {
                    lmn[i] = step
                    m = step
                    if s1 != s2
                        drop(s1)
                    drop(s2)
                    drop(s3)
                    ; (it reads the cell now: a store before it is not one that is overwritten)
                    if ok == O_CELL
                        cellkill[lval[i]] = 0
                }
            }
            if c02 and m == M_STA and not la and not lnz and (ok == O_CELL or ok == O_VAR) {
                ; "lda x / ora #k / sta x" with neither A nor the flags wanted: "lda #k / tsb x";
                ; with "and #k" it is "lda #~k / trb x"
                long t1 = previous_live(i)
                long t2 = previous_live(t1)
                if t2 < t1 and t1 < i and lkind[t1] == L_INS and (lmn[t1] == M_ORA or lmn[t1] == M_AND) and lok[t1] == O_NUM
                        and lkind[t2] == L_INS and lmn[t2] == M_LDA and lok[t2] == ok and lval[t2] == lval[i] and lsym[t2] == lsym[i] {
                    long setbits = lval[t1]
                    if lmn[t1] == M_ORA
                        lmn[i] = M_TSB
                    else {
                        lmn[i] = M_TRB
                        setbits = setbits ^ 255
                    }
                    m = lmn[i]
                    lok[t2] = O_NUM
                    lval[t2] = setbits
                    lsym[t2] = 0
                    drop(t1)
                    if ok == O_CELL
                        cellkill[lval[i]] = 0
                }
            }
            if m == M_STA and not la and not lnz and direct_operand(i) {
                ; "tya / sta" with A not wanted after it: store Y itself
                long pj = i
                while pj > 0 {
                    pj--
                    if lkind[pj] != L_DEAD
                        break
                }
                if pj < i and lkind[pj] == L_INS and (lmn[pj] == M_TYA or lmn[pj] == M_TXA) {
                    if lmn[pj] == M_TYA
                        lmn[i] = M_STY
                    else
                        lmn[i] = M_STX
                    m = lmn[i]
                    drop(pj)
                }
            }
            if (m == M_TAY or m == M_TAX) and not la {
                ; A was loaded only to be transferred: load the index register itself
                long j = i
                while j > 0 {
                    j--
                    if lkind[j] != L_DEAD
                        break
                }
                if j < i and lkind[j] == L_INS and lmn[j] == M_LDA and lok[j] != O_NONE and lok[j] != O_ACC {
                    bool direct = true
                    if lok[j] == O_OTHER {
                        ^^strtab.Sym js = lsym[j]
                        direct = js.mark & K_INDIRECT == 0
                    }
                    if direct {
                        if m == M_TAY
                            lmn[j] = M_LDY
                        else
                            lmn[j] = M_LDX
                        drop(i)
                        continue
                    }
                }
            }
            if not lnz {
                ; (a load of any other operand may be one that the hardware notices)
                bool harmless = ok == O_NUM or ok == O_IMMTEXT or ok == O_CELL or ok == O_VAR or ok == O_POOL
                if ok == O_OTHER and (m == M_LDA or m == M_LDX or m == M_LDY)
                    harmless = indexed_plain(lsym[i])
                if (m == M_CMP or m == M_CPX or m == M_CPY) and harmless and not lc {
                    ; a comparison that nothing looks at
                    drop(i)
                    continue
                }
                if (m == M_LDA and harmless and not la) or (m == M_LDX and harmless and not lx) or (m == M_LDY and harmless and not ly)
                        or (m == M_TXA and not la) or (m == M_TYA and not la) or (m == M_TAX and not lx) or (m == M_TAY and not ly) {
                    drop(i)
                    continue
                }
            }
            ubyte p = props[m]
            if m >= M_INC and m <= M_ROR and (ok == O_ACC or ok == O_NONE)
                p |= RA | WA
            if p & WA != 0
                la = false
            if p & WX != 0
                lx = false
            if p & WY != 0
                ly = false
            if p & SNZ != 0
                lnz = false
            if p & RA != 0
                la = true
            if p & RX != 0
                lx = true
            if p & RY != 0
                ly = true
            if p & RNZ != 0
                lnz = true
            if m == M_CLC or m == M_SEC or m == M_CMP or m == M_CPX or m == M_CPY or m == M_ASL or m == M_LSR or m == M_PLP
                lc = false
            else if m == M_ADC or m == M_SBC or m == M_ROL or m == M_ROR or m == M_PHP
                lc = true
            if ok == O_OTHER {
                ^^strtab.Sym s = lsym[i]
                if s.mark & K_USEX != 0
                    lx = true
                if s.mark & K_USEY != 0
                    ly = true
            }
        }
    }
}
