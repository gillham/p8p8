; The 68000 code generator: IR to assembly for vasm (Motorola syntax).
;
; A first, plain translation, one IR instruction at a time:
;- every virtual register is a cell of four bytes, the value at its low end
;   (a byte in the last of the four), so that a value read narrower than it
;   was written is its low part; a float register is a cell of twelve
;   bytes that holds what the FPU had (fmove.x), while a float variable is
;   four bytes (fmove.s), as upstream and its library have it;
; - a subroutine's cells are in a stack frame under a5 (link/unlk), so
;   they survive a call of the subroutine by itself; a subroutine with
;   assembly text in it has no frame (the text may return on its own) and
;   its cells are in a static area;
; - variables are where the IR has them: static, under their names; except
;   the plain variables and parameters that only their own subroutine
;   names, which are in its frame (a subroutine that calls itself needs
;   that).  The caller still writes an argument to the static parameter;
;   the subroutine takes it into its frame when it is entered;
; - d0, d1, a0 and a1 are scratch within one instruction, nothing is kept in
;   a CPU register from one instruction to the next;
; - a subroutine's value comes back in d0; the arguments of an ordinary
;   subroutine go into its parameter variables, those of an assembly routine
;   into the registers its declaration names (slots 10-17 d0-d7, 18-24 a0-a6).
;
; Names are global and written in full (vasm's -ldots), there are no scopes.

%import ir
%import buf
%import mem
%import out
%import strings
%import strtab

gen68k {
    ^^ir.Program prog = 0
    ^^buf.Buf o = 0
    ^^buf.Buf nb = 0
    long errors = 0
    ^^ir.Sub cursub = 0

    ; the cells of the virtual registers
    ^^long cell_of = 0              ; per register: its offset in the frame or in the static area
    ^^long cell_stamp = 0           ; per register: the number of the subroutine it was placed for
    long cell_cap = 0
    long stamp = 0
    long frame_size = 0             ; of the subroutine being written
    bool framed = false
    long static_size = 0            ; the static area so far
    long label_seq = 0
    bool cpu68000 = false           ; no 68020 instructions: the Amiga 500
    bool uses_fpu = false           ; the program has floating point: the assembler is told that there is an FPU
    bool amiga = false              ; AmigaOS: library calls, a hunk file, the system's stack
    long memtop = $00100000

    sub error(str message, ^^ubyte detail) {
        errors++
        if errors > 20
            return
        out.puts("68000 code generator: ")
        out.puts(message)
        if detail != 0 {
            out.puts(": ")
            out.puts(detail)
        }
        if cursub != 0 {
            out.puts(" (in ")
            out.puts(cursub.name)
            out.puts(")")
        }
        out.nl()
    }

    ; ---- text ----

    sub put(^^ubyte text) {
        buf.add_str(o, text)
    }

    sub putc(ubyte c) {
        buf.add_byte(o, c)
    }

    sub putn(long value) {
        buf.add_long(o, value)
    }

    sub nl() {
        buf.add_byte(o, '\n')
    }

    sub raw(str text) {
        buf.add_str(o, text)
        buf.add_byte(o, '\n')
    }

    sub comma() {
        buf.add_byte(o, ',')
    }

    sub puthex(long value) {
        buf.add_byte(o, '$')
        ubyte shift = 28
        repeat 8 {
            buf.add_byte(o, buf.hex_digit(((value >> shift) & 15) as ubyte))
            if shift >= 4
                shift -= 4
        }
    }

    ; "    mnemonic.s  " with the size letter of an IR type (none for T_NONE)
    sub op(str mnemonic, ubyte t) {
        put("    ")
        put(mnemonic)
        when t {
            ir.T_BYTE -> put(".b")
            ir.T_WORD -> put(".w")
            ir.T_LONG, ir.T_POINTER -> put(".l")
            ir.T_FLOAT -> put(".d")
        }
        put("  ")
    }

    ; a whole instruction without operands of its own
    sub ins(str text) {
        put("    ")
        raw(text)
    }

    sub label(^^ubyte name) {
        put(name)
        raw(":")
    }

    sub new_label() -> long {
        label_seq++
        return label_seq
    }

    sub put_gen(long n) {
        put("p8g_")
        putn(n)
    }

    sub gen_label(long n) {
        put_gen(n)
        raw(":")
    }

    sub type_size(ubyte t) -> ubyte {
        when t {
            ir.T_BYTE -> return 1
            ir.T_WORD -> return 2
            ir.T_FLOAT -> return 8
            else -> return 4
        }
    }

    ; ---- cells ----

    sub grow_cells() {
        long needed = ir.regcount as long + 1
        if needed > cell_cap {
            cell_of = mem.grow(cell_of, cell_cap * 4, needed * 4)
            cell_stamp = mem.grow(cell_stamp, cell_cap * 4, needed * 4)
            cell_cap = needed
        }
    }

    sub place(uword r) {
        if r == 0 or r >= cell_cap or cell_stamp[r] == stamp
            return
        cell_stamp[r] = stamp
        long size = 4
        if ir.reg_type(r) == ir.T_FLOAT
            size = 12
        if framed {
            frame_size += size
            cell_of[r] = frame_size         ; below a5
        }
        else {
            cell_of[r] = static_size
            static_size += size
        }
    }

    sub place_chunks(^^ir.Chunk c) {
        while c != 0 {
            ^^ir.Instr i = c.first
            while i != 0 {
                place(i.r1)
                place(i.r2)
                place(i.r3)
                ^^ir.Arg a = i.args
                while a != 0 {
                    place(a.reg)
                    a = a.next
                }
                a = i.results
                while a != 0 {
                    place(a.reg)
                    a = a.next
                }
                i = i.next
            }
            c = c.next
        }
    }

    sub has_assembly(^^ir.Chunk c) -> bool {
        while c != 0 {
            if c.kind == ir.C_ASM
                return true
            c = c.next
        }
        return false
    }

    ; the cell of a register as an operand of the size of type t, extra bytes on
    sub rgo(uword r, ubyte t, long extra) {
        long size = type_size(t)
        long adjust = 0
        if size < 4
            adjust = 4 - size
        if r >= cell_cap or cell_stamp[r] != stamp {
            error("a register without a cell", 0)
            return
        }
        if framed {
            putn(adjust + extra - cell_of[r])
            put("(a5)")
        }
        else {
            put("p8_regfile+")
            putn(cell_of[r] + adjust + extra)
        }
    }

    sub rg(uword r, ubyte t) {
        rgo(r, t, 0)
    }

    ; the whole cell (to clear what is above a narrow value)
    sub rg_whole(uword r) {
        rgo(r, ir.T_LONG, 0)
    }

    ; ---- memory operands ----

    bool indexed = false

    ; the plain memory operand of an instruction: a name and an offset, or an address
    sub memo(^^ir.Instr i, long extra) {
        if indexed {
            if extra != 0 {
                putn(extra)
            }
            put("(a0,d1.l)")
            return
        }
        if i.sym != 0 {
            ^^ir.Var fv = var_of(i.sym)
            if fv != 0 and fv.stacklocal and framed and fv.owner == cursub {
                putn(i.offset + extra - fv.zpaddr)
                put("(a5)")
                return
            }
            put(i.sym)
            long total = i.offset + extra
            if total > 0 {
                putc('+')
                putn(total)
            }
            else if total < 0
                putn(total)
        }
        else
            puthex(i.offset + extra)
    }

    sub memop(^^ir.Instr i) {
        memo(i, 0)
    }

    ; for loadx, storex, storezx: the address in a0 and the scaled index in d1
    sub index_setup(^^ir.Instr i) {
        indexed = false
        put("    lea  ")
        memop(i)
        raw(",a0")
        ubyte it = ir.reg_type(i.r2)
        if it == ir.T_LONG or it == ir.T_POINTER {
            op("move", ir.T_LONG)
            rg(i.r2, ir.T_LONG)
            raw(",d1")
        }
        else {
            ins("moveq  #0,d1")
            op("move", it)
            rg(i.r2, it)
            raw(",d1")
        }
        when i.scale {
            0, 1 -> {
            }
            2 -> ins("add.l  d1,d1")
            4 -> ins("lsl.l  #2,d1")
            8 -> ins("lsl.l  #3,d1")
            else -> {
                put("    mulu.w  #")
                putn(i.scale)
                raw(",d1")
            }
        }
        indexed = true
    }

    ; ---- pieces of instructions ----

    sub imm(quad value, ubyte t) {
        putc('#')
        when t {
            ir.T_BYTE -> putn((value & 255) as long)
            ir.T_WORD -> putn((value & $ffff) as long)
            else -> putn(value as long)
        }
    }

    ; register r into a data register, the bits above the value zero
    sub load_zx(uword r, ubyte t, str dreg) {
        if t == ir.T_BYTE or t == ir.T_WORD {
            put("    moveq  #0,")
            raw(dreg)
        }
        op("move", t)
        rg(r, t)
        comma()
        raw(dreg)
    }

    ; register r into a data register, as a signed long
    sub load_sx(uword r, ubyte t, str dreg) {
        op("move", t)
        rg(r, t)
        comma()
        raw(dreg)
        if t == ir.T_BYTE {
            put("    ext.w  ")
            raw(dreg)
        }
        if t == ir.T_BYTE or t == ir.T_WORD {
            put("    ext.l  ")
            raw(dreg)
        }
    }

    sub load_ext(uword r, ubyte t, str dreg, bool signed) {
        if signed
            load_sx(r, t, dreg)
        else
            load_zx(r, t, dreg)
    }

    sub mem_ext(^^ir.Instr i, ubyte t, str dreg, bool signed) {
        if not signed and (t == ir.T_BYTE or t == ir.T_WORD) {
            put("    moveq  #0,")
            raw(dreg)
        }
        op("move", t)
        memop(i)
        comma()
        raw(dreg)
        if signed {
            if t == ir.T_BYTE {
                put("    ext.w  ")
                raw(dreg)
            }
            if t == ir.T_BYTE or t == ir.T_WORD {
                put("    ext.l  ")
                raw(dreg)
            }
        }
    }

    sub imm_long(quad value, ubyte t, str dreg, bool signed) {
        long v = value as long
        when t {
            ir.T_BYTE -> {
                v &= 255
                if signed and v > 127
                    v -= 256
            }
            ir.T_WORD -> {
                v &= $ffff
                if signed and v > 32767
                    v -= 65536
            }
        }
        put("    move.l  #")
        putn(v)
        comma()
        raw(dreg)
    }

    sub store_d0(uword r, ubyte t) {
        op("move", t)
        put("d0,")
        rg(r, t)
        nl()
    }

    ; r1 = r1 <operation> second operand, for add, sub, and, or (xor wants a data register)
    ; kind 0: #value, 1: register r2, 2: memory, the result in memory (operation with r1)
    sub simple(str mnemonic, ^^ir.Instr i, ubyte kind, bool needs_dreg) {
        ubyte t = i.type
        when kind {
            0 -> {
                op(mnemonic, t)
                imm(i.value, t)
                comma()
                rg(i.r1, t)
                nl()
            }
            1 -> {
                op("move", t)
                rg(i.r2, t)
                raw(",d0")
                op(mnemonic, t)
                put("d0,")
                rg(i.r1, t)
                nl()
            }
            2 -> {
                op("move", t)
                rg(i.r1, t)
                raw(",d0")
                op(mnemonic, t)
                put("d0,")
                memop(i)
                nl()
            }
            3 -> {
                ; #value into memory
                op(mnemonic, t)
                imm(i.value, t)
                comma()
                memop(i)
                nl()
            }
        }
    }

    ; multiplication, division and remainder: the first operand in d0, the second in d1,
    ; both as longs; the result in d0
    const ubyte A_MUL = 0
    const ubyte A_DIV = 1
    const ubyte A_MOD = 2

    sub arith_d0_d1(ubyte what, ubyte t, bool signed) {
        bool wide = t == ir.T_LONG or t == ir.T_POINTER
        if wide and cpu68000 {
            ; the 68000 multiplies and divides words only: the library's routines
            ; (d0 and d1 in; the product or the quotient in d0, the remainder in d1)
            when what {
                A_MUL -> ins("jsr  p8_umult32")
                else -> {
                    if signed
                        ins("jsr  p8_sdivmod32")
                    else
                        ins("jsr  p8_udivmod32")
                    if what == A_MOD
                        ins("move.l  d1,d0")
                }
            }
            return
        }
        when what {
            A_MUL -> {
                if wide
                    ins("mulu.l  d1,d0")
                else
                    ins("mulu.w  d1,d0")
            }
            A_DIV -> {
                if wide {
                    if signed
                        ins("divs.l  d1,d0")
                    else
                        ins("divu.l  d1,d0")
                }
                else if signed
                    ins("divs.w  d1,d0")
                else
                    ins("divu.w  d1,d0")
            }
            A_MOD -> {
                if wide {
                    ins("move.l  d2,-(sp)")
                    if signed
                        ins("divsl.l  d1,d2:d0")
                    else
                        ins("divul.l  d1,d2:d0")
                    ins("move.l  d2,d0")
                    ins("move.l  (sp)+,d2")
                }
                else {
                    if signed
                        ins("divs.w  d1,d0")
                    else
                        ins("divu.w  d1,d0")
                    ins("swap  d0")
                }
            }
        }
    }

    ; kind as for simple(): 0 r1 with #value, 1 r1 with r2, 2 memory with r1 (into memory)
    sub arith(ubyte what, ^^ir.Instr i, ubyte kind, bool signed) {
        ubyte t = i.type
        when kind {
            0 -> {
                load_ext(i.r1, t, "d0", signed)
                imm_long(i.value, t, "d1", signed)
            }
            1 -> {
                load_ext(i.r1, t, "d0", signed)
                load_ext(i.r2, t, "d1", signed)
            }
            2 -> {
                mem_ext(i, t, "d0", signed)
                load_ext(i.r1, t, "d1", signed)
            }
        }
        arith_d0_d1(what, t, signed)
        if kind == 2 {
            op("move", t)
            put("d0,")
            memop(i)
            nl()
        }
        else
            store_d0(i.r1, t)
    }

    const ubyte S_LSL = 0
    const ubyte S_LSR = 1
    const ubyte S_ASR = 2
    const ubyte S_ROL = 3
    const ubyte S_ROR = 4
    const ubyte S_ROXL = 5
    const ubyte S_ROXR = 6
    str[] shift_names = ["lsl", "lsr", "asr", "rol", "ror", "roxl", "roxr"]

    ; d0 shifted by a constant count
    sub shift_d0_const(ubyte kind, ubyte t, long count) {
        if count == 0
            return
        if count > 8 {
            put("    moveq  #")
            putn(count & 63)
            raw(",d1")
            op(shift_names[kind], t)
            raw("d1,d0")
            return
        }
        op(shift_names[kind], t)
        putc('#')
        putn(count)
        raw(",d0")
    }

    ; a register shifted or rotated: count -1 takes it from register r2
    sub shift_reg(ubyte kind, ^^ir.Instr i, long count) {
        ubyte t = i.type
        op("move", t)
        rg(i.r1, t)
        raw(",d0")
        if count < 0 {
            ins("moveq  #0,d1")
            op("move", ir.T_BYTE)
            rg(i.r2, ir.T_BYTE)
            raw(",d1")
            op(shift_names[kind], t)
            raw("d1,d0")
        }
        else
            shift_d0_const(kind, t, count)
        store_d0(i.r1, t)
    }

    ; the same on a memory location; count -1 takes it from register r1
    sub shift_mem(ubyte kind, ^^ir.Instr i, long count) {
        ubyte t = i.type
        op("move", t)
        memop(i)
        raw(",d0")
        if count < 0 {
            ins("moveq  #0,d1")
            op("move", ir.T_BYTE)
            rg(i.r1, ir.T_BYTE)
            raw(",d1")
            op(shift_names[kind], t)
            raw("d1,d0")
        }
        else
            shift_d0_const(kind, t, count)
        op("move", t)
        put("d0,")
        memop(i)
        nl()
    }

    sub branch(str mnemonic, ^^ubyte target) {
        put("    ")
        put(mnemonic)
        put("  ")
        put(target)
        nl()
    }

    ; bgt, bge, blt, ble and their signed forms: r1 against #value or r2
    sub compare_branch(^^ir.Instr i, str mnemonic) {
        ubyte t = i.type
        if i.mode == ir.M_RIT {
            op("cmpi", t)
            imm(i.value, t)
            comma()
            rg(i.r1, t)
            nl()
        }
        else {
            op("move", t)
            rg(i.r1, t)
            raw(",d0")
            op("cmp", t)
            rg(i.r2, t)
            raw(",d0")
        }
        branch(mnemonic, i.sym)
    }

    ; the name of the CPU register of a calling convention slot, or 0
    str[] slot_names = ["d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7", "a0", "a1", "a2", "a3", "a4", "a5", "a6"]

    sub slot_name(ubyte slot) -> ^^ubyte {
        if slot >= 10 and slot <= 24
            return slot_names[slot - 10]
        return 0
    }

    ; a value into the CPU register of a slot: a register's cell (r != 0) or a number
    sub to_slot(ubyte slot, uword r, quad value, ubyte t) {
        ^^ubyte name = slot_name(slot)
        if name == 0 {
            error("this hardware register is not supported yet", 0)
            return
        }
        if slot == 23
            error("a5 is the frame pointer and cannot take a value", 0)
        if r == 0 {
            put("    move.l  #")
            when t {
                ir.T_BYTE -> putn((value & 255) as long)
                ir.T_WORD -> putn((value & $ffff) as long)
                else -> putn(value as long)
            }
            comma()
            put(name)
            nl()
            return
        }
        if slot >= 18 {
            ; an address register: a narrow value goes through d0, without its sign
            if t == ir.T_BYTE or t == ir.T_WORD {
                load_zx(r, t, "d0")
                put("    movea.l  d0,")
                put(name)
                nl()
            }
            else {
                put("    movea.l  ")
                rg(r, ir.T_LONG)
                comma()
                put(name)
                nl()
            }
            return
        }
        if t == ir.T_BYTE or t == ir.T_WORD {
            put("    moveq  #0,")
            put(name)
            nl()
        }
        op("move", t)
        rg(r, t)
        comma()
        put(name)
        nl()
    }

    ; the CPU register of a slot into a register's cell
    sub from_slot(ubyte slot, uword r, ubyte t) {
        ^^ubyte name = slot_name(slot)
        if name == 0 {
            error("this hardware register is not supported yet", 0)
            return
        }
        if slot >= 18 and (t == ir.T_BYTE or t == ir.T_WORD) {
            put("    move.l  ")
            put(name)
            raw(",d0")
            store_d0(r, t)
            return
        }
        op("move", t)
        put(name)
        comma()
        rg(r, t)
        nl()
    }

    ; ---- subroutines ----

    sub find_sub(^^ubyte name) -> ^^ir.Sub {
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if strings.compare(s.name, name) == 0
                    return s
                s = s.next
            }
            bl = bl.next
        }
        return 0
    }

    ; is the name a label of the subroutine being written (a jump elsewhere leaves its frame)
    sub own_label(^^ubyte name) -> bool {
        if cursub == 0
            return true
        ^^ir.Chunk c = cursub.chunks
        while c != 0 {
            if c.label != 0 and strings.compare(c.label, name) == 0
                return true
            c = c.next
        }
        return false
    }

    sub leave() {
        if framed
            ins("unlk  a5")
    }

    ; The Amiga's libraries by the numbers upstream gives them (an extsub's bank): the
    ; base of each is in a variable of the sys block, that of exec at address 4.
    str[] library_names = ["", "Sys", "DOS", "Gfx", "Intuition", "GadTools", "Layers", "Asl", "ConsoleDevice", "Utility",
                           "Expansion", "Icon", "Workbench", "Diskfont", "IFFParse"]

    ; a6 = the base of the library that the call target "#number,offset,name" names
    sub library_base(^^ubyte target) {
        long number = 0
        long k = 0
        if target[0] == '#'
            k = 1
        while target[k] >= '0' and target[k] <= '9' {
            number = number * 10 + (target[k] - '0')
            k++
        }
        if number == 1 {
            ins("movea.l  4.w,a6")
            return
        }
        if number < 1 or number >= len(library_names) {
            error("a library that is not known", target)
            return
        }
        put("    movea.l  sys.")
        put(library_names[number as ubyte])
        raw("Base,a6")
    }

    sub call_instr(^^ir.Instr i) {
        bool library_call = i.op == ir.OP_CALLFAR
        if i.op == ir.OP_CALLFARVB {
            error("a library call with the library in a variable is not supported", i.sym)
            return
        }
        if library_call {
            if not amiga {
                error("a banked call on a machine without libraries", i.sym)
                return
            }
            library_base(i.sym)
        }
        ; the parameter variables first, then the CPU registers (nothing else touches those)
        ^^ir.Arg a = i.args
        while a != 0 {
            if a.slot == 255 {
                if a.name == 0
                    error("an argument without a place", i.sym)
                else if a.type == ir.T_FLOAT {
                    if a.reg == 0
                        error("a floating point number as an argument is not supported yet", i.sym)
                    else {
                        fload(a.reg)
                        put("    fmove.s  fp0,")
                        put(i.sym)
                        putc('.')
                        put(a.name)
                        nl()
                    }
                }
                else {
                    op("move", a.type)
                    if a.reg != 0
                        rg(a.reg, a.type)
                    else
                        imm(a.value, a.type)
                    comma()
                    put(i.sym)
                    putc('.')
                    put(a.name)
                    nl()
                }
            }
            else if a.slot >= ir.SLOT_FLAGS
                error("a status flag as an argument is not supported yet", i.sym)
            a = a.next
        }
        a = i.args
        while a != 0 {
            if a.slot >= 25 and a.slot <= 32 {
                put("    fmove.x  ")
                frg(a.reg)
                put(",fp")
                putn(a.slot - 25)
                nl()
            }
            else if a.slot < ir.SLOT_FLAGS
                to_slot(a.slot, a.reg, a.value, a.type)
            a = a.next
        }
        ^^ir.Sub callee = 0
        if not library_call
            callee = find_sub(i.sym)
        if library_call {
            ; "#library,offset,name": through the library's jump table
            long k = 0
            while i.sym[k] != 0 and i.sym[k] != ','
                k++
            put("    jsr  ")
            if i.sym[k] == ',' {
                k++
                while i.sym[k] != 0 and i.sym[k] != ',' {
                    putc(i.sym[k])
                    k++
                }
            }
            raw("(a6)")
        }
        else if callee != 0 and callee.is_asm and callee.is_inline and callee.asmtext != 0 and not callee.asm_is_ir
            asm_text(callee.asmtext, callee.asmlen)
        else
            branch("jsr", i.sym)
        ^^ir.Arg r = i.results
        while r != 0 {
            if r.reg != 0 {
                if r.type == ir.T_FLOAT {
                    put("    fmove.x  fp")
                    if r.slot >= 25 and r.slot <= 32
                        putn(r.slot - 25)
                    else
                        putc('0')
                    comma()
                    frg(r.reg)
                    nl()
                }
                else if r.slot == 255
                    from_slot(10, r.reg, r.type)
                else if r.slot < ir.SLOT_FLAGS
                    from_slot(r.slot, r.reg, r.type)
                ; (a status flag: the instructions after the call make it a value)
            }
            r = r.next
        }
    }

    sub arg_n(^^ir.Instr i, ubyte n) -> ^^ir.Arg {
        ^^ir.Arg a = i.args
        while a != 0 and n != 0 {
            a = a.next
            n--
        }
        return a
    }

    sub hex_number(^^ubyte s) -> long {
        long v = 0
        long k = 0
        if s[0] == '$'
            k = 1
        while s[k] != 0 {
            ubyte c = s[k]
            if c >= '0' and c <= '9'
                v = v * 16 + (c - '0')
            else if c >= 'a' and c <= 'f'
                v = v * 16 + (c - 'a' + 10)
            else if c >= 'A' and c <= 'F'
                v = v * 16 + (c - 'A' + 10)
            k++
        }
        return v
    }

    ; an argument of a syscall into a data register, as a long
    sub arg_load(^^ir.Arg a, str dreg, bool signed) {
        if a == 0 {
            error("a syscall without the arguments it needs", 0)
            return
        }
        if a.reg != 0
            load_ext(a.reg, a.type, dreg, signed)
        else
            imm_long(a.value, a.type, dreg, signed)
    }

    ; the builtin functions that the IR leaves to the machine
    sub syscall(^^ir.Instr i) {
        long n = hex_number(i.sym)
        ^^ir.Arg a0 = arg_n(i, 0)
        ^^ir.Arg a1 = arg_n(i, 1)
        ^^ir.Arg a2 = arg_n(i, 2)
        ^^ir.Arg res = i.results
        long found
        long done
        when n {
            $100d -> {
                ; compare two strings: -1, 0 or 1
                arg_load(a0, "d0", false)
                arg_load(a1, "d1", false)
                ins("jsr  prog8_lib.strcmp")
            }
            $100e -> {
                ; is a character in a string
                found = new_label()
                done = new_label()
                long again = new_label()
                arg_load(a0, "d1", false)
                arg_load(a1, "d0", false)
                ins("movea.l  d0,a0")
                gen_label(again)
                ins("move.b  (a0)+,d0")
                put("    beq  ")
                put_gen(done)
                nl()
                ins("cmp.b  d1,d0")
                put("    bne  ")
                put_gen(again)
                nl()
                ins("moveq  #1,d0")
                gen_label(done)
            }
            $100f, $1010, $101b -> {
                ; is a value in an array: the value, the array, its length
                found = new_label()
                done = new_label()
                long next = new_label()
                arg_load(a1, "d0", false)
                ins("movea.l  d0,a0")
                arg_load(a2, "d1", false)
                arg_load(a0, "d0", false)
                put("    bra  ")
                put_gen(next)
                nl()
                long loop = new_label()
                gen_label(loop)
                when n {
                    $100f -> ins("cmp.b  (a0)+,d0")
                    $1010 -> ins("cmp.w  (a0)+,d0")
                    else -> ins("cmp.l  (a0)+,d0")
                }
                put("    beq  ")
                put_gen(found)
                nl()
                gen_label(next)
                put("    dbra  d1,")
                put_gen(loop)
                nl()
                ins("moveq  #0,d0")
                put("    bra  ")
                put_gen(done)
                nl()
                gen_label(found)
                ins("moveq  #1,d0")
                gen_label(done)
            }
            $1012, $1013, $1014, $1015, $1016 -> {
                ; clamp: the value, the least, the most
                bool signed = n == $1013 or n == $1015 or n == $1016
                long high = new_label()
                done = new_label()
                arg_load(a0, "d0", signed)
                arg_load(a1, "d1", signed)
                ins("cmp.l  d1,d0")
                if signed
                    put("    bge  ")
                else
                    put("    bhs  ")
                put_gen(high)
                nl()
                ins("move.l  d1,d0")
                put("    bra  ")
                put_gen(done)
                nl()
                gen_label(high)
                arg_load(a2, "d1", signed)
                ins("cmp.l  d1,d0")
                if signed
                    put("    ble  ")
                else
                    put("    bls  ")
                put_gen(done)
                nl()
                ins("move.l  d1,d0")
                gen_label(done)
            }
            else -> {
                error("syscall not supported yet", i.sym)
                return
            }
        }
        if res != 0 and res.reg != 0
            store_d0(res.reg, res.type)
    }

    ; ---- floating point ----
    ;
    ; Arithmetic is the FPU's (a 68881 or what the CPU has built in), in fp0.

    ; a float register's cell
    sub frg(uword r) {
        if r >= cell_cap or cell_stamp[r] != stamp {
            error("a register without a cell", 0)
            return
        }
        if framed {
            putn(0 - cell_of[r])
            put("(a5)")
        }
        else {
            put("p8_regfile+")
            putn(cell_of[r])
        }
    }

    sub fload(uword r) {
        put("    fmove.x  ")
        frg(r)
        raw(",fp0")
    }

    sub fstore(uword r) {
        put("    fmove.x  fp0,")
        frg(r)
        nl()
    }

    ; "    mnemonic.s  #number,fp0"
    sub fimm(str mnemonic, float value) {
        put("    ")
        put(mnemonic)
        put(".s  #")
        ir.text = o
        ir.add_float(value)
        raw(",fp0")
    }

    ; "    mnemonic.s  memory,fp0"
    sub fmem(str mnemonic, ^^ir.Instr i) {
        put("    ")
        put(mnemonic)
        put(".s  ")
        memop(i)
        raw(",fp0")
    }

    sub fmem_store(^^ir.Instr i) {
        put("    fmove.s  fp0,")
        memop(i)
        nl()
    }

    ; "    mnemonic.x  cell,fp0"
    sub fcell(str mnemonic, uword r) {
        put("    ")
        put(mnemonic)
        put(".x  ")
        frg(r)
        raw(",fp0")
    }

    sub pointer_a0(uword r) {
        put("    movea.l  ")
        rg(r, ir.T_LONG)
        raw(",a0")
    }

    ; the FPU's name for add, sub, mul, div in their three forms; 0 for another instruction
    sub float_operation(ubyte opcode) -> ^^ubyte {
        when opcode {
            ir.OP_ADDR, ir.OP_ADD, ir.OP_ADDM -> return "fadd"
            ir.OP_SUBR, ir.OP_SUB, ir.OP_SUBM -> return "fsub"
            ir.OP_MULR, ir.OP_MUL, ir.OP_MULM, ir.OP_MULSR, ir.OP_MULS, ir.OP_MULSM -> return "fmul"
            ir.OP_DIVR, ir.OP_DIV, ir.OP_DIVM, ir.OP_DIVSR, ir.OP_DIVS, ir.OP_DIVSM -> return "fdiv"
        }
        return 0
    }

    sub float_instruction(^^ir.Instr i) {
        uses_fpu = true
        ^^ubyte fop = float_operation(i.op)
        long l1
        long l2
        when i.op {
            ir.OP_LOAD -> {
                fimm("fmove", i.fvalue)
                fstore(i.r1)
            }
            ir.OP_LOADM -> {
                fmem("fmove", i)
                fstore(i.r1)
            }
            ir.OP_LOADX -> {
                index_setup(i)
                fmem("fmove", i)
                fstore(i.r1)
            }
            ir.OP_LOADI -> {
                pointer_a0(i.r2)
                put("    fmove.s  ")
                putn(i.offset)
                raw("(a0),fp0")
                fstore(i.r1)
            }
            ir.OP_LOADR -> {
                fload(i.r2)
                fstore(i.r1)
            }
            ir.OP_STOREM -> {
                fload(i.r1)
                fmem_store(i)
            }
            ir.OP_STOREX -> {
                index_setup(i)
                fload(i.r1)
                fmem_store(i)
            }
            ir.OP_STOREI -> {
                pointer_a0(i.r2)
                fload(i.r1)
                put("    fmove.s  fp0,")
                putn(i.offset)
                raw("(a0)")
            }
            ir.OP_STOREZM -> {
                put("    clr.l  ")
                memop(i)
                nl()
            }
            ir.OP_STOREZX -> {
                index_setup(i)
                put("    clr.l  ")
                memop(i)
                nl()
            }
            ir.OP_STOREZI -> {
                pointer_a0(i.r2)
                put("    clr.l  ")
                putn(i.offset)
                raw("(a0)")
            }
            ir.OP_STOREIM -> {
                fimm("fmove", i.fvalue)
                fmem_store(i)
            }
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_DIVSR -> {
                fload(i.r1)
                fcell(fop, i.r2)
                fstore(i.r1)
            }
            ir.OP_ADD, ir.OP_SUB, ir.OP_MUL, ir.OP_MULS, ir.OP_DIV, ir.OP_DIVS -> {
                fload(i.r1)
                fimm(fop, i.fvalue)
                fstore(i.r1)
            }
            ir.OP_ADDM, ir.OP_SUBM, ir.OP_MULM, ir.OP_MULSM, ir.OP_DIVM, ir.OP_DIVSM -> {
                fmem("fmove", i)
                fcell(fop, i.r1)
                fmem_store(i)
            }
            ir.OP_NEG -> {
                fload(i.r1)
                ins("fneg  fp0")
                fstore(i.r1)
            }
            ir.OP_NEGM -> {
                fmem("fmove", i)
                ins("fneg  fp0")
                fmem_store(i)
            }
            ir.OP_INC, ir.OP_DEC -> {
                fload(i.r1)
                if i.op == ir.OP_INC
                    ins("fadd.s  #1.0,fp0")
                else
                    ins("fsub.s  #1.0,fp0")
                fstore(i.r1)
            }
            ir.OP_INCM, ir.OP_DECM -> {
                fmem("fmove", i)
                if i.op == ir.OP_INCM
                    ins("fadd.s  #1.0,fp0")
                else
                    ins("fsub.s  #1.0,fp0")
                fmem_store(i)
            }
            ir.OP_SQRT, ir.OP_FABS, ir.OP_FSIN, ir.OP_FCOS, ir.OP_FTAN, ir.OP_FATAN, ir.OP_FLN, ir.OP_FLOG -> {
                ; r1 = function of r2
                fload(i.r2)
                when i.op {
                    ir.OP_SQRT -> ins("fsqrt  fp0")
                    ir.OP_FABS -> ins("fabs  fp0")
                    ir.OP_FSIN -> ins("fsin  fp0")
                    ir.OP_FCOS -> ins("fcos  fp0")
                    ir.OP_FTAN -> ins("ftan  fp0")
                    ir.OP_FATAN -> ins("fatan  fp0")
                    ir.OP_FLN -> ins("flogn  fp0")
                    else -> ins("flog2  fp0")
                }
                fstore(i.r1)
            }
            ir.OP_SGN -> {
                ; r1 (a byte) = the sign of r2
                l1 = new_label()
                fload(i.r2)
                ins("moveq  #0,d0")
                ins("ftst  fp0")
                put("    fbeq  ")
                put_gen(l1)
                nl()
                ins("moveq  #1,d0")
                put("    fbgt  ")
                put_gen(l1)
                nl()
                ins("moveq  #-1,d0")
                gen_label(l1)
                store_d0(i.r1, ir.T_BYTE)
            }
            ir.OP_FFROMUB -> {
                load_zx(i.r2, ir.T_BYTE, "d0")
                ins("fmove.l  d0,fp0")
                fstore(i.r1)
            }
            ir.OP_FFROMSB -> {
                load_sx(i.r2, ir.T_BYTE, "d0")
                ins("fmove.l  d0,fp0")
                fstore(i.r1)
            }
            ir.OP_FFROMUW -> {
                load_zx(i.r2, ir.T_WORD, "d0")
                ins("fmove.l  d0,fp0")
                fstore(i.r1)
            }
            ir.OP_FFROMSW -> {
                load_sx(i.r2, ir.T_WORD, "d0")
                ins("fmove.l  d0,fp0")
                fstore(i.r1)
            }
            ir.OP_FFROMSL -> {
                put("    fmove.l  ")
                rg(i.r2, ir.T_LONG)
                raw(",fp0")
                fstore(i.r1)
            }
            ir.OP_FTOUB, ir.OP_FTOSB -> {
                fload(i.r2)
                ins("moveq  #0,d0")
                ins("fmove.b  fp0,d0")
                store_d0(i.r1, ir.T_BYTE)
            }
            ir.OP_FTOUW, ir.OP_FTOSW -> {
                fload(i.r2)
                ins("fmove.w  fp0,d0")
                store_d0(i.r1, ir.T_WORD)
            }
            ir.OP_FTOSL -> {
                fload(i.r2)
                ins("fmove.l  fp0,d0")
                store_d0(i.r1, ir.T_LONG)
            }
            ir.OP_FCOMP -> {
                ; r1 (a byte) = -1, 0 or 1: r2 against r3
                l1 = new_label()
                l2 = new_label()
                fload(i.r2)
                fcell("fcmp", i.r3)
                ins("moveq  #0,d0")
                put("    fbeq  ")
                put_gen(l1)
                nl()
                ins("moveq  #1,d0")
                put("    fbgt  ")
                put_gen(l1)
                nl()
                ins("moveq  #-1,d0")
                gen_label(l1)
                store_d0(i.r1, ir.T_BYTE)
            }
            ir.OP_RETURNR -> {
                fload(i.r1)
                leave()
                ins("rts")
            }
            ir.OP_RETURNI -> {
                fimm("fmove", i.fvalue)
                leave()
                ins("rts")
            }
            ir.OP_PUSH -> {
                fload(i.r1)
                ins("fmove.x  fp0,-(sp)")
            }
            ir.OP_POP -> {
                ins("fmove.x  (sp)+,fp0")
                fstore(i.r1)
            }
            ir.OP_LOADHR -> {
                if i.slot < 25 or i.slot > 32
                    error("a float in this hardware register is not supported", 0)
                else {
                    put("    fmove.x  fp")
                    putn(i.slot - 25)
                    comma()
                    frg(i.r1)
                    nl()
                }
            }
            ir.OP_STOREHR -> {
                if i.slot < 25 or i.slot > 32
                    error("a float in this hardware register is not supported", 0)
                else {
                    put("    fmove.x  ")
                    frg(i.r1)
                    put(",fp")
                    putn(i.slot - 25)
                    nl()
                }
            }
            else -> error("floating point instruction not supported yet", ir.opcode_names[i.op])
        }
    }

    sub instruction(^^ir.Instr i) {
        ubyte t = i.type
        indexed = false
        if t == ir.T_FLOAT or i.t1 == ir.T_FLOAT or (i.op >= ir.OP_FFROMUB and i.op <= ir.OP_FCOMP) or (i.op >= ir.OP_FPOW and i.op <= ir.OP_FTOUQ) {
            float_instruction(i)
            return
        }
        if t == ir.T_QUAD {
            error("64 bit values are not supported", ir.opcode_names[i.op])
            return
        }
        when i.op {
            ir.OP_NOP, ir.OP_BREAKPOINT, ir.OP_SEI, ir.OP_CLI -> {
            }
            ir.OP_LOAD -> {
                if i.sym != 0 {
                    put("    move.l  #")
                    put(i.sym)
                    if i.offset > 0 {
                        putc('+')
                        putn(i.offset)
                    }
                    else if i.offset < 0
                        putn(i.offset)
                    comma()
                    rg(i.r1, ir.T_LONG)
                    nl()
                }
                else if i.value == 0 {
                    op("clr", t)
                    rg(i.r1, t)
                    nl()
                }
                else {
                    op("move", t)
                    imm(i.value, t)
                    comma()
                    rg(i.r1, t)
                    nl()
                }
            }
            ir.OP_LOADM -> {
                op("move", t)
                memop(i)
                comma()
                rg(i.r1, t)
                nl()
            }
            ir.OP_LOADMZ -> {
                ; a byte from memory into a word register
                op("clr", ir.T_WORD)
                rg(i.r1, ir.T_WORD)
                nl()
                op("move", ir.T_BYTE)
                memop(i)
                comma()
                rg(i.r1, ir.T_BYTE)
                nl()
            }
            ir.OP_LOADR -> {
                op("move", t)
                rg(i.r2, t)
                comma()
                rg(i.r1, t)
                nl()
            }
            ir.OP_LOADX -> {
                index_setup(i)
                op("move", t)
                memop(i)
                comma()
                rg(i.r1, t)
                nl()
            }
            ir.OP_STOREX -> {
                index_setup(i)
                op("move", t)
                rg(i.r1, t)
                comma()
                memop(i)
                nl()
            }
            ir.OP_STOREZX -> {
                index_setup(i)
                op("clr", t)
                memop(i)
                nl()
            }
            ir.OP_LOADI -> {
                put("    movea.l  ")
                rg(i.r2, ir.T_LONG)
                raw(",a0")
                op("move", t)
                putn(i.offset)
                put("(a0),")
                rg(i.r1, t)
                nl()
            }
            ir.OP_STOREI -> {
                put("    movea.l  ")
                rg(i.r2, ir.T_LONG)
                raw(",a0")
                op("move", t)
                rg(i.r1, t)
                comma()
                putn(i.offset)
                raw("(a0)")
            }
            ir.OP_STOREZI -> {
                put("    movea.l  ")
                rg(i.r2, ir.T_LONG)
                raw(",a0")
                op("clr", t)
                putn(i.offset)
                raw("(a0)")
            }
            ir.OP_STOREM -> {
                op("move", t)
                rg(i.r1, t)
                comma()
                memop(i)
                nl()
            }
            ir.OP_STOREZM -> {
                op("clr", t)
                memop(i)
                nl()
            }
            ir.OP_STOREIM -> {
                if i.value == 0
                    op("clr", t)
                else {
                    op("move", t)
                    imm(i.value, t)
                    comma()
                }
                memop(i)
                nl()
            }
            ir.OP_LOADHR -> from_slot(i.slot, i.r1, t)
            ir.OP_STOREHR -> to_slot(i.slot, i.r1, 0, t)
            ir.OP_JUMP -> {
                if own_label(i.sym)
                    branch("bra", i.sym)
                else {
                    leave()
                    branch("jmp", i.sym)
                }
            }
            ir.OP_JUMPI -> {
                put("    movea.l  ")
                rg(i.r1, ir.T_LONG)
                raw(",a0")
                leave()
                ins("jmp  (a0)")
            }
            ir.OP_CALLI -> {
                put("    movea.l  ")
                rg(i.r1, ir.T_LONG)
                raw(",a0")
                ins("jsr  (a0)")
            }
            ir.OP_CALL, ir.OP_CALLFAR, ir.OP_CALLFARVB -> call_instr(i)
            ir.OP_RETURN -> {
                leave()
                ins("rts")
            }
            ir.OP_RETURNR -> {
                load_zx(i.r1, t, "d0")
                leave()
                ins("rts")
            }
            ir.OP_RETURNI -> {
                imm_long(i.value, t, "d0", false)
                leave()
                ins("rts")
            }
            ir.OP_BSTCC -> branch("bcc", i.sym)
            ir.OP_BSTCS -> branch("bcs", i.sym)
            ir.OP_BSTEQ -> branch("beq", i.sym)
            ir.OP_BSTNE -> branch("bne", i.sym)
            ir.OP_BSTNEG -> branch("bmi", i.sym)
            ir.OP_BSTPOS -> branch("bpl", i.sym)
            ir.OP_BSTVC -> branch("bvc", i.sym)
            ir.OP_BSTVS -> branch("bvs", i.sym)
            ir.OP_BGT, ir.OP_BGTR -> compare_branch(i, "bhi")
            ir.OP_BGE, ir.OP_BGER -> compare_branch(i, "bhs")
            ir.OP_BLT -> compare_branch(i, "blo")
            ir.OP_BLE -> compare_branch(i, "bls")
            ir.OP_BGTS, ir.OP_BGTSR -> compare_branch(i, "bgt")
            ir.OP_BGES, ir.OP_BGESR -> compare_branch(i, "bge")
            ir.OP_BLTS -> compare_branch(i, "blt")
            ir.OP_BLES -> compare_branch(i, "ble")
            ir.OP_INC -> {
                op("addq", t)
                put("#1,")
                rg(i.r1, t)
                nl()
            }
            ir.OP_DEC -> {
                op("subq", t)
                put("#1,")
                rg(i.r1, t)
                nl()
            }
            ir.OP_INCM -> {
                op("addq", t)
                put("#1,")
                memop(i)
                nl()
            }
            ir.OP_DECM -> {
                op("subq", t)
                put("#1,")
                memop(i)
                nl()
            }
            ir.OP_NEG -> {
                op("neg", t)
                rg(i.r1, t)
                nl()
            }
            ir.OP_NEGM -> {
                op("neg", t)
                memop(i)
                nl()
            }
            ir.OP_INV -> {
                op("not", t)
                rg(i.r1, t)
                nl()
            }
            ir.OP_INVM -> {
                op("not", t)
                memop(i)
                nl()
            }
            ir.OP_ADDR -> simple("add", i, 1, false)
            ir.OP_ADD -> simple("addi", i, 0, false)
            ir.OP_ADDM -> simple("add", i, 2, false)
            ir.OP_ADDIM -> simple("addi", i, 3, false)
            ir.OP_SUBR -> simple("sub", i, 1, false)
            ir.OP_SUB -> simple("subi", i, 0, false)
            ir.OP_SUBM -> simple("sub", i, 2, false)
            ir.OP_SUBIM -> simple("subi", i, 3, false)
            ir.OP_ANDR -> simple("and", i, 1, false)
            ir.OP_AND -> simple("andi", i, 0, false)
            ir.OP_ANDM -> simple("and", i, 2, false)
            ir.OP_ORR -> simple("or", i, 1, false)
            ir.OP_OR -> simple("ori", i, 0, false)
            ir.OP_ORM -> simple("or", i, 2, false)
            ir.OP_XORR -> simple("eor", i, 1, true)
            ir.OP_XOR -> simple("eori", i, 0, true)
            ir.OP_XORM -> simple("eor", i, 2, true)
            ir.OP_MULR -> arith(A_MUL, i, 1, false)
            ir.OP_MUL -> arith(A_MUL, i, 0, false)
            ir.OP_MULM -> arith(A_MUL, i, 2, false)
            ir.OP_MULSR -> arith(A_MUL, i, 1, true)
            ir.OP_MULS -> arith(A_MUL, i, 0, true)
            ir.OP_MULSM -> arith(A_MUL, i, 2, true)
            ir.OP_DIVR -> arith(A_DIV, i, 1, false)
            ir.OP_DIV -> arith(A_DIV, i, 0, false)
            ir.OP_DIVM -> arith(A_DIV, i, 2, false)
            ir.OP_DIVSR -> arith(A_DIV, i, 1, true)
            ir.OP_DIVS -> arith(A_DIV, i, 0, true)
            ir.OP_DIVSM -> arith(A_DIV, i, 2, true)
            ir.OP_MODR -> arith(A_MOD, i, 1, false)
            ir.OP_MOD -> arith(A_MOD, i, 0, false)
            ir.OP_MODSR -> arith(A_MOD, i, 1, true)
            ir.OP_MODS -> arith(A_MOD, i, 0, true)
            ir.OP_DIVMODR -> {
                ; r1 = the quotient, r2 = the remainder
                load_zx(i.r1, t, "d0")
                load_zx(i.r2, t, "d1")
                if (t == ir.T_LONG or t == ir.T_POINTER) and cpu68000
                    ins("jsr  p8_udivmod32")
                else if t == ir.T_LONG or t == ir.T_POINTER {
                    ins("move.l  d2,-(sp)")
                    ins("divul.l  d1,d2:d0")
                    ins("move.l  d2,d1")
                    ins("move.l  (sp)+,d2")
                }
                else {
                    ins("divu.w  d1,d0")
                    ins("move.l  d0,d1")
                    ins("swap  d1")
                }
                store_d0(i.r1, t)
                op("move", t)
                put("d1,")
                rg(i.r2, t)
                nl()
            }
            ir.OP_SQRT -> {
                ; r1 = the root of r2, by the library's routines: of a byte or a word a byte, of a long a word
                ^^ubyte routine = "math._sqrt_ub"
                ubyte rt = ir.T_BYTE
                if t == ir.T_WORD
                    routine = "math._sqrt_uw"
                else if t != ir.T_BYTE {
                    routine = "math._sqrt_l"
                    rt = ir.T_WORD
                }
                op("move", t)
                rg(i.r2, t)
                comma()
                put(routine)
                raw(".value")
                branch("jsr", routine)
                store_d0(i.r1, rt)
            }
            ir.OP_SYSCALL -> syscall(i)
            ir.OP_SQUARE -> {
                load_zx(i.r1, t, "d0")
                ins("move.l  d0,d1")
                arith_d0_d1(A_MUL, t, false)
                store_d0(i.r1, t)
            }
            ir.OP_SGN -> {
                ; r1 (a byte) = the sign of r2
                long zero = new_label()
                ins("moveq  #0,d0")
                op("tst", t)
                rg(i.r2, t)
                nl()
                put("    beq  ")
                put_gen(zero)
                nl()
                ins("smi  d0")
                ins("or.b  #1,d0")
                gen_label(zero)
                store_d0(i.r1, ir.T_BYTE)
            }
            ir.OP_CMP -> {
                op("move", t)
                rg(i.r1, t)
                raw(",d0")
                op("cmp", t)
                rg(i.r2, t)
                raw(",d0")
            }
            ir.OP_CMPI -> {
                if i.value == 0
                    op("tst", t)
                else {
                    op("cmpi", t)
                    imm(i.value, t)
                    comma()
                }
                rg(i.r1, t)
                nl()
            }
            ir.OP_EXT, ir.OP_EXTL -> {
                ; r1 (wider) = r2, zeros above
                load_zx(i.r2, t, "d0")
                op("move", ir.T_LONG)
                put("d0,")
                rg_whole(i.r1)
                nl()
            }
            ir.OP_EXTS, ir.OP_EXTLS -> {
                load_sx(i.r2, t, "d0")
                op("move", ir.T_LONG)
                put("d0,")
                rg_whole(i.r1)
                nl()
            }
            ir.OP_LSIGB -> {
                op("move", ir.T_BYTE)
                rg(i.r2, ir.T_BYTE)
                comma()
                rg(i.r1, ir.T_BYTE)
                nl()
            }
            ir.OP_LSIGW -> {
                op("move", ir.T_WORD)
                rg(i.r2, ir.T_WORD)
                comma()
                rg(i.r1, ir.T_WORD)
                nl()
            }
            ir.OP_MSIGB -> {
                ; the highest byte of r2
                op("move", ir.T_BYTE)
                rg(i.r2, t)
                comma()
                rg(i.r1, ir.T_BYTE)
                nl()
            }
            ir.OP_MSIGW -> {
                op("move", ir.T_WORD)
                rg(i.r2, t)
                comma()
                rg(i.r1, ir.T_WORD)
                nl()
            }
            ir.OP_CONCAT -> {
                ; r1 (twice as wide) = r2 above r3
                ubyte wide = ir.T_WORD
                if t == ir.T_WORD
                    wide = ir.T_LONG
                op("move", t)
                rg(i.r2, t)
                comma()
                rg(i.r1, wide)
                nl()
                op("move", t)
                rg(i.r3, t)
                comma()
                rgo(i.r1, wide, type_size(t))
                nl()
            }
            ir.OP_LSLN -> shift_reg(S_LSL, i, -1)
            ir.OP_LSRN -> shift_reg(S_LSR, i, -1)
            ir.OP_ASRN -> shift_reg(S_ASR, i, -1)
            ir.OP_LSLI -> shift_reg(S_LSL, i, i.value as long)
            ir.OP_LSRI -> shift_reg(S_LSR, i, i.value as long)
            ir.OP_ASRI -> shift_reg(S_ASR, i, i.value as long)
            ir.OP_LSL -> shift_reg(S_LSL, i, 1)
            ir.OP_LSR -> shift_reg(S_LSR, i, 1)
            ir.OP_ASR -> shift_reg(S_ASR, i, 1)
            ir.OP_ROL -> shift_reg(S_ROL, i, 1)
            ir.OP_ROR -> shift_reg(S_ROR, i, 1)
            ir.OP_ROXL -> shift_reg(S_ROXL, i, 1)
            ir.OP_ROXR -> shift_reg(S_ROXR, i, 1)
            ir.OP_LSLM -> shift_mem(S_LSL, i, 1)
            ir.OP_LSRM -> shift_mem(S_LSR, i, 1)
            ir.OP_ASRM -> shift_mem(S_ASR, i, 1)
            ir.OP_ROLM -> shift_mem(S_ROL, i, 1)
            ir.OP_RORM -> shift_mem(S_ROR, i, 1)
            ir.OP_ROXLM -> shift_mem(S_ROXL, i, 1)
            ir.OP_ROXRM -> shift_mem(S_ROXR, i, 1)
            ir.OP_LSLNM -> shift_mem(S_LSL, i, -1)
            ir.OP_LSRNM -> shift_mem(S_LSR, i, -1)
            ir.OP_ASRNM -> shift_mem(S_ASR, i, -1)
            ir.OP_CLC -> ins("andi  #$ee,ccr")
            ir.OP_SEC -> ins("ori  #$11,ccr")
            ir.OP_PUSH -> {
                op("move", t)
                rg(i.r1, t)
                raw(",-(sp)")
            }
            ir.OP_POP -> {
                op("move", t)
                put("(sp)+,")
                rg(i.r1, t)
                nl()
            }
            ir.OP_ALIGN -> ins("even")
            else -> error("instruction not supported yet", ir.opcode_names[i.op])
        }
    }

    sub chunk_code(^^ir.Chunk c) {
        ^^ir.Instr i = c.first
        while i != 0 {
            instruction(i)
            i = i.next
        }
    }

    sub asm_text(^^ubyte text, long length) {
        if text == 0
            return
        buf.add_bytes(o, text, length)
        if length == 0 or text[length - 1] != '\n'
            nl()
    }

    ; the frame of a piece of code: its cells placed, and the link instruction
    sub enter(^^ir.Chunk chunks, bool with_frame) {
        stamp++
        framed = with_frame
        frame_size = 0
        place_chunks(chunks)
        if framed and cursub != 0
            place_variables(cursub)
        if framed {
            if frame_size & 1 != 0
                frame_size++
            put("    link  a5,#-")
            putn(frame_size)
            nl()
            if cursub != 0
                take_parameters(cursub)
        }
    }

    ; ---- variables in the frame ----
    ;
    ; The names of variables and subroutines are found through the string table:
    ; a symbol's stamp says that its extra field is ours, the number of the
    ; variable (from 1) or minus the number of the subroutine.

    const long OURS = 68000
    ^^pointer var_table = 0
    ^^pointer sub_table = 0

    sub var_of(^^ubyte name) -> ^^ir.Var {
        ^^strtab.Sym s = strtab.intern_sym(name, buf.cstr_len(name) as uword)
        if s.stamp != OURS or s.extra <= 0
            return 0
        return var_table[s.extra]
    }

    sub sub_of(^^ubyte name, long length) -> ^^ir.Sub {
        ^^strtab.Sym s = strtab.intern_sym(name, length as uword)
        if s.stamp != OURS or s.extra >= 0
            return 0
        return sub_table[0 - s.extra]
    }

    ; the subroutine a variable's name is in: the longest part before a dot that is one
    sub owner_of(^^ubyte name) -> ^^ir.Sub {
        long i = buf.cstr_len(name)
        while i > 0 {
            i--
            if name[i] == '.' {
                ^^ir.Sub s = sub_of(name, i)
                if s != 0
                    return s
            }
        }
        return 0
    }

    sub name_char(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.'
    }

    ; a variable that assembly text names stays where the text expects it
    sub names_in_assembly(^^ubyte text, long length) {
        if text == 0
            return
        long p = 0
        while p < length {
            if name_char(text[p]) {
                long q = p
                while q < length and name_char(text[q])
                    q++
                ^^strtab.Sym s = strtab.intern_sym(text + p, (q - p) as uword)
                if s.stamp == OURS and s.extra > 0 {
                    ^^ir.Var v = var_table[s.extra]
                    v.stacklocal = false
                }
                p = q
            }
            else
                p++
        }
    }

    sub static_use(^^ir.Instr i, ^^ir.Sub s) {
        if i.sym == 0
            return
        ^^ir.Var v = var_of(i.sym)
        if v == 0 or not v.stacklocal
            return
        ; a symbol as a value is its address; a use from elsewhere shares it
        if i.mode == ir.M_RI or i.mode == ir.M_I or i.mode == ir.M_RRI or v.owner != s
            v.stacklocal = false
    }

    sub mark_frame_variables() {
        long nvars = 0
        long nsubs = 0
        ^^ir.Var v = prog.vars
        while v != 0 {
            nvars++
            v = v.next
        }
        ^^ir.Block bl = prog.blocks
        ^^ir.Sub s
        while bl != 0 {
            s = bl.subs
            while s != 0 {
                nsubs++
                s = s.next
            }
            bl = bl.next
        }
        var_table = mem.alloc((nvars + 1) * sizeof(pointer))
        sub_table = mem.alloc((nsubs + 1) * sizeof(pointer))
        ^^strtab.Sym sy
        long k = 0
        bl = prog.blocks
        while bl != 0 {
            s = bl.subs
            while s != 0 {
                k++
                sub_table[k] = s
                sy = strtab.intern_sym(s.name, buf.cstr_len(s.name) as uword)
                sy.stamp = OURS
                sy.extra = 0 - k
                s = s.next
            }
            bl = bl.next
        }
        k = 0
        v = prog.vars
        while v != 0 {
            k++
            var_table[k] = v
            v.stacklocal = false
            v.owner = 0
            sy = strtab.intern_sym(v.name, buf.cstr_len(v.name) as uword)
            if sy.stamp != OURS {
                sy.stamp = OURS
                sy.extra = k
                if v.kind == ir.V_VAR and not v.shared and not v.dirty and v.align == 0 and array_length(v.typestr) == 0 and element_size(v.typestr) <= 8 and not v.split {
                    ^^ir.Sub owner = owner_of(v.name)
                    if owner != 0 and not owner.is_asm and not has_assembly(owner.chunks) {
                        v.owner = owner
                        v.stacklocal = true
                    }
                }
            }
            v = v.next
        }
        ; what takes a variable out again
        ^^ir.Chunk c
        ^^ir.Instr i
        bl = prog.blocks
        while bl != 0 {
            c = bl.chunks
            while c != 0 {
                if c.kind == ir.C_ASM
                    names_in_assembly(c.text, c.textlen)
                c = c.next
            }
            s = bl.subs
            while s != 0 {
                names_in_assembly(s.asmtext, s.asmlen)
                c = s.chunks
                while c != 0 {
                    if c.kind == ir.C_ASM
                        names_in_assembly(c.text, c.textlen)
                    i = c.first
                    while i != 0 {
                        static_use(i, s)
                        i = i.next
                    }
                    c = c.next
                }
                s = s.next
            }
            bl = bl.next
        }
        if prog.initglobals != 0 {
            i = prog.initglobals.first
            while i != 0 {
                static_use(i, 0)
                i = i.next
            }
        }
        ; and an address in an initializer
        v = prog.vars
        while v != 0 {
            if v.init != 0 {
                long p = 0
                while v.init[p] != 0 {
                    if v.init[p] == '@' {
                        long q = p + 1
                        while v.init[q] != 0 and v.init[q] != ','
                            q++
                        names_in_assembly(v.init + p + 1, q - p - 1)
                        p = q
                    }
                    else
                        p++
                }
            }
            v = v.next
        }
    }

    ; the frame places of a subroutine's own variables
    sub place_variables(^^ir.Sub s) {
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.stacklocal and v.owner == s {
                long size = element_size(v.typestr)
                if size > 1 and frame_size & 1 != 0
                    frame_size++
                frame_size += size
                v.zpaddr = frame_size
            }
            v = v.next
        }
    }

    ; the arguments, from the static parameters where the caller put them
    sub take_parameters(^^ir.Sub s) {
        ^^ir.Param p = s.params
        while p != 0 {
            ^^ir.Var v = var_of(p.name)
            if v != 0 and v.stacklocal and v.owner == s {
                long size = element_size(v.typestr)
                if size == 8 {
                    put("    move.l  ")
                    put(v.name)
                    comma()
                    putn(0 - v.zpaddr)
                    raw("(a5)")
                    put("    move.l  ")
                    put(v.name)
                    put("+4,")
                    putn(4 - v.zpaddr)
                    raw("(a5)")
                }
                else {
                    when size {
                        1 -> put("    move.b  ")
                        2 -> put("    move.w  ")
                        else -> put("    move.l  ")
                    }
                    put(v.name)
                    comma()
                    putn(0 - v.zpaddr)
                    raw("(a5)")
                }
            }
            p = p.next
        }
    }

    sub subroutine(^^ir.Sub s) {
        cursub = s
        nl()
        if s.is_asm {
            ; an assembly routine: its text, unless it is put in place of every call
            if s.is_inline or s.asmtext == 0 or s.asm_is_ir {
                cursub = 0
                return
            }
            raw("    even")
            label(s.name)
            asm_text(s.asmtext, s.asmlen)
            cursub = 0
            return
        }
        put("; ---- Subroutine: ")
        put(s.name)
        raw(" ----")
        raw("    even")
        label(s.name)
        if strings.compare(s.name, "p8b_main.p8s_start") == 0
            ins("jsr  run_global_inits")
        enter(s.chunks, not has_assembly(s.chunks))
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            if c.label != 0 and strings.compare(c.label, s.name) != 0
                label(c.label)
            if c.kind == ir.C_ASM
                asm_text(c.text, c.textlen)
            else
                chunk_code(c)
            c = c.next
        }
        cursub = 0
    }

    sub code() {
        raw("prog8_program_start:")
        if not amiga {
            put("    move.l  #")
            puthex(memtop)
            raw(",sp")
        }
        ins("jsr  p8_sys_startup.init_system")
        ins("jsr  p8_sys_startup.init_system_phase2")
        ins("jsr  p8b_main.p8s_start")
        ins("moveq  #0,d0")
        ins("jmp  p8_sys_startup.cleanup_at_exit")
        nl()
        raw("run_global_inits:")
        if prog.initglobals != 0 {
            enter(prog.initglobals, true)
            chunk_code(prog.initglobals)
            leave()
        }
        ins("rts")
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            nl()
            if bl.chipram and amiga
                raw("    section  code_c,code,chip")
            put("; Block: ")
            put(bl.name)
            nl()
            label(bl.name)
            ^^ir.Chunk c = bl.chunks
            while c != 0 {
                if c.label != 0
                    label(c.label)
                if c.kind == ir.C_ASM
                    asm_text(c.text, c.textlen)
                else if c.first != 0
                    error("code outside of a subroutine", bl.name)
                c = c.next
            }
            ^^ir.Sub s = bl.subs
            while s != 0 {
                subroutine(s)
                s = s.next
            }
            if bl.chipram and amiga
                raw("    section  .text,code")
            bl = bl.next
        }
    }

    ; ---- data ----

    sub starts_with(^^ubyte s, str prefix) -> bool {
        return buf.bytes_equal(s, prefix, strings.length(prefix))
    }

    sub array_length(^^ubyte t) -> long {
        long i = 0
        while t[i] != 0 and t[i] != '['
            i++
        if t[i] == 0
            return 0
        long n = 0
        i++
        while t[i] >= '0' and t[i] <= '9' {
            n = n * 10 + (t[i] - '0')
            i++
        }
        return n
    }

    sub element_size(^^ubyte t) -> long {
        if starts_with(t, "ubyte") or starts_with(t, "byte") or starts_with(t, "bool")
            return 1
        if starts_with(t, "uword") or starts_with(t, "word")
            return 2
        if starts_with(t, "long") or starts_with(t, "pointer") or t[0] == '^'
            return 4
        if starts_with(t, "float")
            return 4
        long i = 0
        while t[i] != 0 and t[i] != '['
            i++
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_STRUCT and buf.cstr_len(v.name) == i and buf.bytes_equal(v.name, t, i)
                return v.size
            v = v.next
        }
        return 1
    }

    sub is_float(^^ubyte t) -> bool {
        return starts_with(t, "float")
    }

    sub var_size(^^ir.Var v) -> long {
        long n = array_length(v.typestr)
        if n == 0
            n = 1
        return n * element_size(v.typestr)
    }

    sub directive(long size, bool isfloat) {
        if isfloat {
            put("    dc.s  ")
            return
        }
        when size {
            2 -> put("    dc.w  ")
            4 -> put("    dc.l  ")
            else -> put("    dc.b  ")
        }
    }

    ; one value of an initializer from position p; gives the position after it
    sub put_value(^^ubyte t, long p) -> long {
        if t[p] == '@'
            p++
        while t[p] != 0 and t[p] != ',' {
            putc(t[p])
            p++
        }
        return p
    }

    sub values(^^ubyte init, long size, bool isfloat) {
        long p = 0
        ubyte column = 0
        while init[p] != 0 {
            if column == 0
                directive(size, isfloat)
            else
                comma()
            p = put_value(init, p)
            if init[p] == ','
                p++
            column++
            if column == 16 {
                nl()
                column = 0
            }
        }
        if column != 0
            nl()
    }

    ; "type:value,type:value": a line of data for each field of a struct instance
    sub instance_values(^^ubyte t) {
        long p = 0
        while t[p] != 0 {
            long colon = p
            while t[colon] != ':' and t[colon] != 0
                colon++
            if t[colon] == 0
                return
            buf.clear(nb)
            buf.add_bytes(nb, t + p, colon - p)
            buf.add_byte(nb, 0)
            directive(element_size(nb.data), is_float(nb.data))
            p = put_value(t, colon + 1)
            nl()
            if t[p] == ','
                p++
        }
    }

    sub is_struct_array(^^ubyte t) -> bool {
        long i = 0
        while t[i] != 0 and t[i] != '['
            i++
        if t[i] == 0
            return false
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_STRUCT and buf.cstr_len(v.name) == i and buf.bytes_equal(v.name, t, i)
                return true
            v = v.next
        }
        return false
    }

    ; "@instance,@instance": each instance's field values (zeros for one without)
    sub struct_array_values(^^ubyte t, long struct_size) {
        long p = 0
        while t[p] != 0 {
            long stop = p
            while t[stop] != 0 and t[stop] != ','
                stop++
            ^^ir.Var inst = 0
            if t[p] == '@' {
                inst = var_of(strtab.intern(t + p + 1, (stop - p - 1) as uword))
                if inst != 0 and inst.kind != ir.V_INSTANCE
                    inst = 0
            }
            if inst != 0 and inst.init != 0
                instance_values(inst.init)
            else {
                put("    dcb.b  ")
                putn(struct_size)
                raw(",0")
            }
            p = stop
            if t[p] == ','
                p++
        }
    }

    ; The size of a struct and the offsets of its fields, for assembly text:
    ; name_size and name.p8v_field, as upstream writes them.
    sub struct_equates() {
        raw("; struct types")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_STRUCT and v.typestr != 0 {
                put(v.name)
                put("_size equ ")
                putn(v.size)
                nl()
                long offset = 0
                long p = 0
                ^^ubyte f = v.typestr
                while f[p] != 0 {
                    ; "type name;"
                    long space = p
                    while f[space] != 0 and f[space] != ' ' and f[space] != ';'
                        space++
                    if f[space] != ' '
                        break
                    buf.clear(nb)
                    buf.add_bytes(nb, f + p, space - p)
                    buf.add_byte(nb, 0)
                    long count = array_length(nb.data)
                    if count == 0
                        count = 1
                    long size = element_size(nb.data) * count
                    long stop = space + 1
                    while f[stop] != 0 and f[stop] != ';'
                        stop++
                    put(v.name)
                    putc('.')
                    if not buf.bytes_equal(f + space + 1, "p8v_", 4)
                        put("p8v_")
                    buf.add_bytes(o, f + space + 1, stop - space - 1)
                    put(" equ ")
                    putn(offset)
                    nl()
                    offset += size
                    p = stop
                    if f[p] == ';'
                        p++
                }
            }
            v = v.next
        }
        nl()
    }

    sub constants() {
        raw("; constants and memory-mapped variables")
        ^^ir.Var v = prog.vars
        while v != 0 {
            ; (not a float constant: the assembler has no such names, and the IR has the
            ; number wherever the program uses one)
            if (v.kind == ir.V_CONST or v.kind == ir.V_MEMVAR) and v.init != 0 and not (v.kind == ir.V_CONST and is_float(v.typestr)) {
                put(v.name)
                put(" = ")
                put(v.init)
                nl()
            }
            v = v.next
        }
        nl()
    }

    ; is the variable one of a block with %option amiga_chipram (its name starts with the block's)
    sub in_chip(^^ubyte name) -> bool {
        if not amiga
            return false
        long dot = 0
        while name[dot] != 0 and name[dot] != '.'
            dot++
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            if bl.chipram and buf.cstr_len(bl.name) == dot and buf.bytes_equal(bl.name, name, dot)
                return true
            bl = bl.next
        }
        return false
    }

    sub data() {
        data_of(false)
        if any_chip
            data_of(true)
    }

    bool any_chip = false

    sub data_of(bool chip) {
        nl()
        if chip
            raw("    section  data_c,data,chip")
        else
            raw("    section  .data,data")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if in_chip(v.name) != chip {
                v = v.next
                continue
            }
            if v.kind == ir.V_VAR and v.init != 0 {
                long esize = element_size(v.typestr)
                raw("    even")
                label(v.name)
                if is_struct_array(v.typestr)
                    struct_array_values(v.init, esize)
                else
                    values(v.init, esize, is_float(v.typestr))
            }
            else if v.kind == ir.V_INSTANCE and v.init != 0 {
                raw("    even")
                label(v.name)
                instance_values(v.init)
            }
            v = v.next
        }
    }

    sub bss() {
        bss_of(false)
        if any_chip
            bss_of(true)
    }

    sub bss_of(bool chip) {
        nl()
        if chip
            raw("    section  bss_c,bss,chip")
        else
            raw("    section  .bss,bss")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if in_chip(v.name) != chip {
                v = v.next
                continue
            }
            long size = -1
            if v.kind == ir.V_VAR and v.init == 0
                size = var_size(v)
            else if v.kind == ir.V_SLAB or (v.kind == ir.V_INSTANCE and v.init == 0)
                size = v.size
            if size >= 0 {
                if v.align > 2 {
                    put("    cnop  0,")
                    putn(v.align)
                    nl()
                }
                else
                    raw("    even")
                put(v.name)
                put(":  ds.b  ")
                putn(size)
                nl()
            }
            v = v.next
        }
        if not chip {
            raw("    even")
            put("p8_regfile:  ds.b  ")
            putn(static_size + 4)
            nl()
        }
    }

    sub generate(^^ir.Program p, ^^buf.Buf output) {
        prog = p
        o = output
        errors = 0
        label_seq = 0
        static_size = 0
        cursub = 0
        if nb == 0
            nb = buf.new(256)
        grow_cells()
        mark_frame_variables()
        cpu68000 = strings.compare(p.target, "amiga500") == 0
        amiga = buf.bytes_equal(p.target, "amiga", 5)
        any_chip = false
        uses_fpu = false
        ^^ir.Block cb = p.blocks
        while cb != 0 {
            ; (the floats library's own assembly has the FPU's instructions)
            if strings.compare(cb.name, "floats") == 0
                uses_fpu = true
            if cb.chipram and amiga
                any_chip = true
            cb = cb.next
        }
        put("; Program: ")
        put(p.name)
        nl()
        raw("; Generated by p8p8's 68000 code generator, for vasm (Motorola syntax)")
        nl()
        raw("    section  .text,code")
        constants()
        struct_equates()
        code()
        data()
        bss()
    }
}
