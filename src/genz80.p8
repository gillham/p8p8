; The Z80 code generator: writes a p8p8 IR program (ir.p8) as assembly for z88dk's
; z80asm.  A first version.
;
; How it is put together (docs/DESIGN.md, "The Z80"):
;
; - Every IR register has a place in memory (p8r_N, as wide as its type).  An
;   instruction takes its operands from there into A (a byte) or HL and DE (a word),
;   works, and puts the result back.  That is slow and simple; registers that live in
;   CPU registers come later.
; - A call puts its arguments into the subroutine's parameter variables, as the IR
;   names them; a result comes back in A (a byte) or HL (a word).
; - What the machine has to do (print a character, a string) is a system call in the
;   IR; here those are routines for CP/M's BDOS.
; - The program is a CP/M .com file: it begins at $0100, takes its stack below the
;   BDOS, clears its variables, and returns to CP/M with a warm start.
;
; Not there yet is said by an error that names the instruction: longs beyond loading,
; storing, adding and comparing, floats, signed division, most system calls.

%import ir
%import irparse
%import buf
%import strtab
%import strings
%import mem
%import out
%import target

genz80 {
    %option ignore_unused

    ^^ir.Program prog = 0
    ^^buf.Buf o = 0
    ^^buf.Buf nb = 0
    long errors = 0
    long labels = 0
    ^^ubyte reg_used = 0            ; per IR register: named by the code that was written
    long part = 0                   ; which subroutine's registers: its number
    ^^buf.Buf cells = 0             ; the places of the registers, written at the end
    ^^ir.Instr previous = 0         ; the instruction before the one being written, in its chunk
    bool need_mul = false
    bool need_div = false
    bool need_divs = false          ; the signed division of words
    bool need_mul32 = false
    bool need_div32 = false
    bool need_divs32 = false
    bool need_long = false          ; the cells of the long routines
    bool[256] slot_used             ; the hardware register slots that the code names
    bool need_print = false
    bool need_jphl = false
    bool need_vregs = false
    bool carry_cell = false         ; this subroutine keeps the IR's carry in a place of its own (see carry_scan)
    bool carry_loaded = false       ; the instruction's carry was just taken from there
    bool entry_pending = false      ; the subroutine's first label is still to come
    bool[32] need_rt                ; the routines of the system calls (the RT_ numbers)
    const ubyte RT_MOVE = 0
    const ubyte RT_FILL = 1
    const ubyte RT_FILLW = 2
    const ubyte RT_STRCMP = 3
    const ubyte RT_INSTR = 4
    const ubyte RT_INBYTES = 5
    const ubyte RT_INWORDS = 6
    const ubyte RT_CLAMP8 = 7
    const ubyte RT_CLAMPS8 = 8
    const ubyte RT_CLAMP16 = 9
    const ubyte RT_CLAMPS16 = 10
    const ubyte RT_SQRT = 11
    const ubyte RT_WAITKEY = 12

    sub error(str message, ^^ubyte detail) {
        out.err()
        out.puts("Z80 code generator: ")
        out.puts(message)
        if detail != 0 {
            out.puts(": ")
            out.puts(detail)
        }
        out.nl()
        errors++
    }

    ; ---- writing ----

    sub put(^^ubyte text) {
        buf.add_str(o, text)
    }

    sub putn(long value) {
        buf.add_long(o, value)
    }

    sub nl() {
        buf.add_byte(o, '\n')
    }

    ; one line of assembly
    sub line(str text) {
        buf.add_str(o, "    ")
        buf.add_str(o, text)
        buf.add_byte(o, '\n')
    }

    ; a name of the program as the assembler takes it: its dots are underscores, and it
    ; begins with an underscore, so that no name is one of the assembler's own words
    sub name(^^ubyte sym) {
        buf.add_byte(o, '_')
        long k = 0
        while sym[k] != 0 {
            if sym[k] == '.'
                buf.add_byte(o, '_')
            else
                buf.add_byte(o, sym[k])
            k++
        }
    }

    sub label(^^ubyte sym) {
        name(sym)
        put(":")
        nl()
    }

    sub new_label() -> long {
        labels++
        return labels
    }

    sub put_local(long n) {
        put("p8z_")
        putn(n)
    }

    sub local(long n) {
        put_local(n)
        put(":")
        nl()
    }

    ; "    mnemonic  " and the rest of the line follows
    sub start(str mnemonic) {
        put("    ")
        put(mnemonic)
        put("  ")
    }

    ; ---- types ----

    sub size_of(ubyte t) -> ubyte {
        when t {
            ir.T_BYTE -> return 1
            ir.T_WORD, ir.T_POINTER -> return 2
            ir.T_LONG -> return 4
        }
        return 0
    }

    ; the type an operand register is written with
    sub type1(^^ir.Instr i) -> ubyte {
        if i.t1 != 0
            return i.t1
        return i.type
    }

    sub type2(^^ir.Instr i) -> ubyte {
        if i.t2 != 0
            return i.t2
        return i.type
    }

    ; ---- operands ----

    ; a register's place, with a byte offset
    sub reg(uword r, ubyte offset) {
        if r <= ir.regcount
            reg_used[r] = 1
        ; (register numbers are used again from one subroutine to the next, so each
        ; subroutine has places of its own)
        put("p8r_")
        putn(part)
        put("_")
        putn(r)
        if offset != 0 {
            put("+")
            putn(offset)
        }
    }

    ; the memory operand of an instruction (without an index), with a byte offset
    sub mem_name(^^ir.Instr i, long extra) {
        if i.sym != 0 {
            name(i.sym)
            if i.offset + extra != 0 {
                put("+")
                putn(i.offset + extra)
            }
        }
        else {
            ; (a fixed address: in the value, or in the offset alone when the value is
            ; the instruction's immediate)
            long address = (i.value as long) + i.offset
            if i.op == ir.OP_STOREIM or i.op == ir.OP_ADDIM or i.op == ir.OP_SUBIM
                address = i.offset
            if address >= $ff0000 {
                ; (one of the library's virtual registers, by its made-up address)
                put("p8_vregs+")
                putn(address - $ff0000 + extra)
                need_vregs = true
            }
            else
                putn(address + extra)
        }
    }

    ; A hardware register slot of the IR: on the Z80 a place in memory, four bytes.  The
    ; values that a subroutine returns beside its first, and the one of a call through a
    ; pointer, go through them.
    sub slot(ubyte number, ubyte offset) {
        slot_used[number] = true
        put("p8_slot_")
        putn(number)
        if offset != 0 {
            put("+")
            putn(offset)
        }
    }

    ; "ld a,(reg)" and its relatives
    sub a_from_reg(uword r, ubyte offset) {
        start("ld")
        put("a,(")
        reg(r, offset)
        put(")")
        nl()
    }

    sub reg_from_a(uword r, ubyte offset) {
        start("ld")
        put("(")
        reg(r, offset)
        put("),a")
        nl()
    }

    sub pair_from_reg(str pair, uword r, ubyte offset) {
        start("ld")
        put(pair)
        put(",(")
        reg(r, offset)
        put(")")
        nl()
    }

    sub reg_from_pair(uword r, ubyte offset, str pair) {
        start("ld")
        put("(")
        reg(r, offset)
        put("),")
        put(pair)
        nl()
    }

    sub a_from_mem(^^ir.Instr i, long extra) {
        start("ld")
        put("a,(")
        mem_name(i, extra)
        put(")")
        nl()
    }

    sub mem_from_a(^^ir.Instr i, long extra) {
        start("ld")
        put("(")
        mem_name(i, extra)
        put("),a")
        nl()
    }

    sub pair_from_mem(str pair, ^^ir.Instr i, long extra) {
        start("ld")
        put(pair)
        put(",(")
        mem_name(i, extra)
        put(")")
        nl()
    }

    sub mem_from_pair(^^ir.Instr i, long extra, str pair) {
        start("ld")
        put("(")
        mem_name(i, extra)
        put("),")
        put(pair)
        nl()
    }

    sub pair_imm(str pair, long value) {
        start("ld")
        put(pair)
        put(",")
        putn(value & $ffff)
        nl()
    }

    sub a_imm(long value) {
        start("ld")
        put("a,")
        putn(value & 255)
        nl()
    }

    ; HL = the address of the instruction's memory operand, with its index when it has
    ; one (r2 times the element's size)
    sub hl_address(^^ir.Instr i, bool indexed) {
        start("ld")
        put("hl,")
        mem_name(i, 0)
        nl()
        if indexed and i.r2 != 0 {
            if size_of(ir.regtypes[i.r2]) == 1 {
                a_from_reg(i.r2, 0)
                line("ld  e,a")
                line("ld  d,0")
            }
            else
                pair_from_reg("de", i.r2, 0)
            ubyte times = i.scale
            if times == 0
                times = 1
            while times > 1 {
                line("sla  e")
                line("rl  d")
                times >>= 1
            }
            line("add  hl,de")
        }
    }

    ; HL = r2 + offset: the address of a load or store through a pointer
    sub hl_pointer(^^ir.Instr i) {
        pair_from_reg("hl", i.r2, 0)
        if i.offset != 0 {
            pair_imm("de", i.offset)
            line("add  hl,de")
        }
    }

    ; the bytes at (HL) into register r, or the other way round
    sub reg_from_hl(uword r, ubyte size) {
        ubyte k
        for k in 0 to size - 1 {
            line("ld  a,(hl)")
            reg_from_a(r, k)
            if k != size - 1
                line("inc  hl")
        }
    }

    sub hl_from_reg(uword r, ubyte size) {
        ubyte k
        for k in 0 to size - 1 {
            a_from_reg(r, k)
            line("ld  (hl),a")
            if k != size - 1
                line("inc  hl")
        }
    }

    ; ---- the program ----

    sub generate(^^ir.Program p, ^^buf.Buf output) {
        prog = p
        o = output
        errors = 0
        labels = 0
        need_mul = false
        need_div = false
        need_divs = false
        need_mul32 = false
        need_div32 = false
        need_divs32 = false
        need_long = false
        need_print = false
        sys.memset(&slot_used, 256, 0)
        need_jphl = false
        need_vregs = false
        sys.memset(&need_rt, 32, 0)
        if nb == 0
            nb = buf.new(256)
        if cells == 0
            cells = buf.new(65536)
        buf.clear(cells)
        part = 0
        reg_used = mem.alloc(70000)
        long k
        for k in 0 to 69999
            reg_used[k] = 0
        put("; Program: ")
        put(prog.name)
        nl()
        line("; written by p8p8's Z80 code generator, for z88dk-z80asm")
        ; (the load address is the target's: $0100 for CP/M)
        put("    org  ")
        putn(target.number("load_address", $0100))
        nl()
        ; (the machine's first instructions: where the stack is, as the target file says)
        target_lines("startup_code")
        ; the variables without values are zero
        line("ld  hl,p8_bss_start")
        line("ld  bc,p8_bss_end-p8_bss_start")
        put("p8_clear:")
        nl()
        line("ld  a,b")
        line("or  c")
        line("jr  z,p8_cleared")
        line("ld  (hl),0")
        line("inc  hl")
        line("dec  bc")
        line("jr  p8_clear")
        put("p8_cleared:")
        nl()
        line("call  p8_init_globals")
        line("call  _main_start")
        ; (how the program ends: the target's; sys.exit comes here too)
        raw("p8_exit:")
        target_lines("exit_code")
        nl()
        put("p8_init_globals:")
        nl()
        previous = 0
        part = 0
        chunk_code(prog.initglobals)
        line("ret")
        nl()
        register_cells()
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Chunk c = bl.chunks
            part++
            while c != 0 {
                chunk(c)
                c = c.next
            }
            register_cells()
            ^^ir.Sub s = bl.subs
            while s != 0 {
                subroutine(s)
                s = s.next
            }
            bl = bl.next
        }
        runtime()
        variables()
    }

    ; the lines of a key of the target file, as instructions
    sub target_lines(str key) {
        ^^ubyte text = target.text(key)
        if text == 0 {
            error("the target file lacks a key that a Z80 machine needs", key)
            return
        }
        long k = 0
        while text[k] != 0 {
            put("    ")
            while text[k] != 0 and text[k] != '\n' {
                buf.add_byte(o, text[k])
                k++
            }
            nl()
            if text[k] == '\n'
                k++
        }
    }

    sub subroutine(^^ir.Sub s) {
        if s.is_external
            return
        if s.is_asm and s.asmtext != 0 and not s.asm_is_ir {
            ; assembly for another machine is of no use here
            error("a subroutine in assembly cannot be used on the Z80 yet", s.name)
            return
        }
        if not irparse.expand(s) {
            error("the IR text of a subroutine could not be read", s.name)
            return
        }
        put("; ---- ")
        put(s.name)
        nl()
        part++
        carry_cell = carry_scan(s)
        ^^ir.Chunk c = s.chunks
        bool first = true
        while c != 0 {
            if first {
                if c.label == 0 or strings.compare(c.label, s.name) != 0 {
                    label(s.name)
                    carry_clear()
                }
                else
                    entry_pending = true
            }
            first = false
            chunk(c)
            c = c.next
        }
        if first
            label(s.name)
        line("ret")
        nl()
        register_cells()
        if carry_cell {
            buf.add_str(cells, "p8c_")
            buf.add_long(cells, part)
            buf.add_str(cells, ":  defs  1\n")
        }
        carry_cell = false
    }

    ; ---- the IR's carry ----
    ;
    ; The IR has a carry flag that only a compare, clc, sec and the shifts and rotations
    ; by one bit change, and that roxl, roxr, bstcc and bstcs read.  Mostly the reader comes
    ; straight after what set it, and the Z80's own carry serves.  A subroutine where it
    ; does not (the library's string hash rotates a byte around a loop) keeps the flag in
    ; a place of its own: clear at its start, as on the host, where each subroutine has
    ; its own flags; every instruction that sets it stores it there, and a reader takes it
    ; from there.  The place holds the IR's carry, which after a compare is the other way
    ; round than the Z80's.

    sub carry_setter(ubyte op) -> bool {
        when op {
            ir.OP_CMP, ir.OP_CMPI, ir.OP_CLC, ir.OP_SEC, ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_ROL, ir.OP_ROR,
            ir.OP_ROXL, ir.OP_ROXR, ir.OP_LSLM, ir.OP_LSRM, ir.OP_ASRM, ir.OP_ROLM, ir.OP_RORM, ir.OP_ROXLM, ir.OP_ROXRM -> return true
        }
        return false
    }

    sub carry_rotation(ubyte op) -> bool {
        return op == ir.OP_ROXL or op == ir.OP_ROXR or op == ir.OP_ROXLM or op == ir.OP_ROXRM
    }

    ; does instruction i, after instruction before (or 0), find the carry it reads in the
    ; Z80's own?
    sub carry_at_hand(^^ir.Instr i, ^^ir.Instr before) -> bool {
        if before == 0 or not carry_setter(before.op)
            return false
        if carry_rotation(i.op) and (before.op == ir.OP_CMP or before.op == ir.OP_CMPI)
            return false
        return true
    }

    sub carry_scan(^^ir.Sub s) -> bool {
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            if c.kind != ir.C_ASM {
                ^^ir.Instr before = 0
                ^^ir.Instr i = c.first
                while i != 0 {
                    if (carry_rotation(i.op) or i.op == ir.OP_BSTCC or i.op == ir.OP_BSTCS) and not carry_at_hand(i, before)
                        return true
                    before = i
                    i = i.next
                }
            }
            c = c.next
        }
        return false
    }

    sub carry_place() {
        put("(p8c_")
        putn(part)
        put(")")
    }

    sub carry_clear() {
        if carry_cell {
            line("xor  a")
            start("ld")
            carry_place()
            put(",a")
            nl()
        }
    }

    ; after an instruction that set the carry: into the place, with the flags and A as
    ; they were
    sub carry_save(ubyte op) {
        line("push  af")
        if op == ir.OP_CMP or op == ir.OP_CMPI
            line("ccf")
        line("sbc  a,a")
        start("ld")
        carry_place()
        put(",a")
        nl()
        line("pop  af")
    }

    ; before an instruction that reads the carry: from the place, when it is not at hand
    sub carry_in(^^ir.Instr i) {
        carry_loaded = false
        if carry_cell and not carry_at_hand(i, previous) {
            start("ld")
            put("a,")
            carry_place()
            nl()
            line("rra")
            carry_loaded = true
        }
    }

    ; the places of the registers that the code just written names, for the end of the
    ; program
    sub register_cells() {
        uword r
        for r in 1 to ir.regcount {
            if reg_used[r] != 0 {
                reg_used[r] = 0
                ubyte rsize = size_of(ir.regtypes[r])
                if rsize == 0
                    rsize = 4
                buf.add_str(cells, "p8r_")
                buf.add_long(cells, part)
                buf.add_byte(cells, '_')
                buf.add_long(cells, r)
                buf.add_str(cells, ":  defs  ")
                buf.add_long(cells, rsize)
                buf.add_byte(cells, '\n')
            }
        }
    }

    sub chunk(^^ir.Chunk c) {
        if c.label != 0
            label(c.label)
        if entry_pending {
            entry_pending = false
            carry_clear()
        }
        if c.kind == ir.C_ASM {
            if c.is_ir
                error("IR text that was not turned into instructions", c.label)
            else
                error("assembly text cannot be used on the Z80 yet", c.label)
            return
        }
        previous = 0
        chunk_code(c)
    }

    sub chunk_code(^^ir.Chunk c) {
        if c == 0
            return
        ^^ir.Instr i = c.first
        while i != 0 {
            instruction(i)
            if carry_cell and carry_setter(i.op)
                carry_save(i.op)
            previous = i
            i = i.next
        }
    }

    ; ---- instructions ----

    sub unsupported(^^ir.Instr i) {
        buf.clear(nb)
        buf.add_str(nb, ir.opcode_names[i.op])
        when i.type {
            ir.T_BYTE -> buf.add_str(nb, ".b")
            ir.T_WORD -> buf.add_str(nb, ".w")
            ir.T_LONG -> buf.add_str(nb, ".l")
            ir.T_QUAD -> buf.add_str(nb, ".q")
            ir.T_FLOAT -> buf.add_str(nb, ".f")
            ir.T_POINTER -> buf.add_str(nb, ".p")
        }
        buf.add_byte(nb, 0)
        error("this instruction is not written for the Z80 yet", nb.data)
    }

    ; the value of register r into A (a byte), HL (a word) or DE and HL (a long, HL the
    ; low half), by the type
    sub fetch(uword r, ubyte size) {
        if size == 1
            a_from_reg(r, 0)
        else {
            pair_from_reg("hl", r, 0)
            if size == 4
                pair_from_reg("de", r, 2)
        }
    }

    sub keep(uword r, ubyte size) {
        if size == 1
            reg_from_a(r, 0)
        else {
            reg_from_pair(r, 0, "hl")
            if size == 4
                reg_from_pair(r, 2, "de")
        }
    }

    ; A op= the byte in register r2 / the immediate, HL op= DE for words: the second
    ; operand into its place (B for a byte, DE for a word)
    sub second_reg(uword r, ubyte size) {
        if size == 1 {
            a_from_reg(r, 0)
            line("ld  b,a")
        }
        else
            pair_from_reg("de", r, 0)
    }

    sub second_imm(long value, ubyte size) {
        if size == 1 {
            start("ld")
            put("b,")
            putn(value & 255)
            nl()
        }
        else
            pair_imm("de", value)
    }

    ; What an arithmetic instruction does, whatever its operands are: 0 add, 1 subtract,
    ; 2 and, 3 or, 4 xor, 5 multiply, 6 divide, 7 remainder, 8 signed divide, 9 signed
    ; remainder.
    sub kind_of(ubyte op) -> ubyte {
        when op {
            ir.OP_ADD, ir.OP_ADDR, ir.OP_ADDM, ir.OP_ADDIM -> return 0
            ir.OP_SUB, ir.OP_SUBR, ir.OP_SUBM, ir.OP_SUBIM -> return 1
            ir.OP_AND, ir.OP_ANDR, ir.OP_ANDM -> return 2
            ir.OP_OR, ir.OP_ORR, ir.OP_ORM -> return 3
            ir.OP_XOR, ir.OP_XORR, ir.OP_XORM -> return 4
            ir.OP_MUL, ir.OP_MULR, ir.OP_MULM, ir.OP_MULS, ir.OP_MULSR, ir.OP_MULSM -> return 5
            ir.OP_DIV, ir.OP_DIVR, ir.OP_DIVM, ir.OP_DIVMOD, ir.OP_DIVMODR -> return 6
            ir.OP_MOD, ir.OP_MODR -> return 7
            ir.OP_DIVS, ir.OP_DIVSR, ir.OP_DIVSM, ir.OP_SDIVMOD, ir.OP_SDIVMODR -> return 8
            ir.OP_MODS, ir.OP_MODSR -> return 9
        }
        return 255
    }

    ; The operands of an arithmetic instruction, by its group:
    ;   1  register r1 op= the immediate       2  register r1 op= register r2
    ;   3  memory op= register r1              4  memory op= the immediate
    ; "first" is what is changed, "second" the other one; k is the byte of it.
    sub first_a(^^ir.Instr i, ubyte group, ubyte k) {
        if group <= 2
            a_from_reg(i.r1, k)
        else
            a_from_mem(i, k)
    }

    sub a_first(^^ir.Instr i, ubyte group, ubyte k) {
        if group <= 2
            reg_from_a(i.r1, k)
        else
            mem_from_a(i, k)
    }

    sub first_pair(str pair, ^^ir.Instr i, ubyte group, ubyte k) {
        if group <= 2
            pair_from_reg(pair, i.r1, k)
        else
            pair_from_mem(pair, i, k)
    }

    sub pair_first(^^ir.Instr i, ubyte group, ubyte k, str pair) {
        if group <= 2
            reg_from_pair(i.r1, k, pair)
        else
            mem_from_pair(i, k, pair)
    }

    sub second_b(^^ir.Instr i, ubyte group, ubyte k) {
        when group {
            1, 4 -> {
                start("ld")
                put("b,")
                putn(((i.value >> (k * 8)) as long) & 255)
                nl()
            }
            2 -> {
                a_from_reg(i.r2, k)
                line("ld  b,a")
            }
            else -> {
                a_from_reg(i.r1, k)
                line("ld  b,a")
            }
        }
    }

    sub second_pair(str pair, ^^ir.Instr i, ubyte group, ubyte k) {
        when group {
            1, 4 -> pair_imm(pair, (i.value >> (k * 8)) as long)
            2 -> pair_from_reg(pair, i.r2, k)
            else -> pair_from_reg(pair, i.r1, k)
        }
    }

    ; HL = first / second, DE = the remainder.  Words are in HL and DE; bytes are in A
    ; and B and are made words here.
    sub divide(ubyte kind, ubyte size) {
        if size == 1 {
            line("ld  l,a")
            if kind >= 8 {
                line("rlca")
                line("sbc  a,a")
                line("ld  h,a")
                line("ld  a,b")
                line("ld  e,a")
                line("rlca")
                line("sbc  a,a")
                line("ld  d,a")
            }
            else {
                line("ld  h,0")
                line("ld  e,b")
                line("ld  d,0")
            }
        }
        if kind >= 8 {
            line("call  p8rt_divs16")
            need_divs = true
        }
        else
            line("call  p8rt_div16")
        need_div = true
    }

    ; first (A or HL) op= second (B or DE); the result is in A or HL
    sub combine(ubyte kind, ubyte size) {
        when kind {
            0 -> {
                if size == 1
                    line("add  a,b")
                else
                    line("add  hl,de")
            }
            1 -> {
                if size == 1
                    line("sub  b")
                else {
                    line("or  a")
                    line("sbc  hl,de")
                }
            }
            2 -> {
                if size == 1
                    line("and  b")
                else
                    logic16("and")
            }
            3 -> {
                if size == 1
                    line("or  b")
                else
                    logic16("or")
            }
            4 -> {
                if size == 1
                    line("xor  b")
                else
                    logic16("xor")
            }
            5 -> {
                if size == 1 {
                    ; (a byte product is the low byte of the word product)
                    line("ld  l,a")
                    line("ld  h,0")
                    line("ld  e,b")
                    line("ld  d,0")
                    line("call  p8rt_mul16")
                    line("ld  a,l")
                }
                else
                    line("call  p8rt_mul16")
                need_mul = true
            }
            else -> {
                divide(kind, size)
                if kind == 7 or kind == 9
                    line("ex  de,hl")           ; (the remainder)
                if size == 1
                    line("ld  a,l")
            }
        }
    }

    ; one byte of a long addition, subtraction or logic operation: A op= B, with the carry
    ; of the byte before
    sub bytewise(ubyte kind, ubyte k) {
        when kind {
            0 -> {
                if k == 0
                    line("add  a,b")
                else
                    line("adc  a,b")
            }
            1 -> {
                if k == 0
                    line("sub  b")
                else
                    line("sbc  a,b")
            }
            2 -> line("and  b")
            3 -> line("or  b")
            else -> line("xor  b")
        }
    }

    ; the operands of a long multiplication or division into the cells of the routines
    sub long_cells(^^ir.Instr i, ubyte group) {
        first_pair("hl", i, group, 0)
        line("ld  (p8_la),hl")
        first_pair("hl", i, group, 2)
        line("ld  (p8_la+2),hl")
        second_pair("hl", i, group, 0)
        line("ld  (p8_lb),hl")
        second_pair("hl", i, group, 2)
        line("ld  (p8_lb+2),hl")
        need_long = true
    }

    ; the routine: the product and a remainder come in p8_lc, a quotient in p8_la
    sub long_call(ubyte kind) {
        if kind == 5 {
            line("call  p8rt_mul32")
            need_mul32 = true
        }
        else if kind >= 8 {
            line("call  p8rt_divs32")
            need_divs32 = true
            need_div32 = true
        }
        else {
            line("call  p8rt_div32")
            need_div32 = true
        }
    }

    ; an arithmetic instruction of any size
    sub arith(^^ir.Instr i, ubyte group) {
        ubyte size = size_of(i.type)
        ubyte kind = kind_of(i.op)
        ubyte k
        if size == 1 {
            second_b(i, group, 0)
            first_a(i, group, 0)
            combine(kind, 1)
            a_first(i, group, 0)
        }
        else if size == 2 {
            second_pair("de", i, group, 0)
            first_pair("hl", i, group, 0)
            combine(kind, 2)
            pair_first(i, group, 0, "hl")
        }
        else if size == 4 {
            if kind <= 4 {
                for k in 0 to 3 {
                    second_b(i, group, k)
                    first_a(i, group, k)
                    bytewise(kind, k)
                    a_first(i, group, k)
                }
            }
            else {
                long_cells(i, group)
                long_call(kind)
                if kind == 6 or kind == 8 {
                    line("ld  hl,(p8_la)")
                    pair_first(i, group, 0, "hl")
                    line("ld  hl,(p8_la+2)")
                    pair_first(i, group, 2, "hl")
                }
                else {
                    line("ld  hl,(p8_lc)")
                    pair_first(i, group, 0, "hl")
                    line("ld  hl,(p8_lc+2)")
                    pair_first(i, group, 2, "hl")
                }
            }
        }
        else
            unsupported(i)
    }

    ; r1 = r1 / the second operand, r2 = the remainder
    sub quotient_and_rest(^^ir.Instr i) {
        ubyte size = size_of(i.type)
        ubyte kind = kind_of(i.op)
        ubyte group = 2
        if i.op == ir.OP_DIVMOD or i.op == ir.OP_SDIVMOD
            group = 1
        if size == 1 {
            second_b(i, group, 0)
            a_from_reg(i.r1, 0)
            divide(kind, 1)
            line("ld  a,l")
            reg_from_a(i.r1, 0)
            line("ld  a,e")
            reg_from_a(i.r2, 0)
        }
        else if size == 2 {
            second_pair("de", i, group, 0)
            pair_from_reg("hl", i.r1, 0)
            divide(kind, 2)
            reg_from_pair(i.r1, 0, "hl")
            reg_from_pair(i.r2, 0, "de")
        }
        else if size == 4 {
            long_cells(i, group)
            long_call(kind)
            line("ld  hl,(p8_la)")
            reg_from_pair(i.r1, 0, "hl")
            line("ld  hl,(p8_la+2)")
            reg_from_pair(i.r1, 2, "hl")
            line("ld  hl,(p8_lc)")
            reg_from_pair(i.r2, 0, "hl")
            line("ld  hl,(p8_lc+2)")
            reg_from_pair(i.r2, 2, "hl")
        }
        else
            unsupported(i)
    }

    ; first = -first, byte by byte
    sub negate(^^ir.Instr i, ubyte group, ubyte size) {
        ubyte k
        for k in 0 to size - 1 {
            first_a(i, group, k)
            if k == 0
                line("neg")
            else {
                line("ld  b,a")
                line("ld  a,0")
                line("sbc  a,b")
            }
            a_first(i, group, k)
        }
    }

    ; first += 1 or -= 1, a long
    sub step_long(^^ir.Instr i, ubyte group, bool up) {
        ubyte k
        for k in 0 to 3 {
            first_a(i, group, k)
            if up {
                if k == 0
                    line("add  a,1")
                else
                    line("adc  a,0")
            }
            else {
                if k == 0
                    line("sub  1")
                else
                    line("sbc  a,0")
            }
            a_first(i, group, k)
        }
    }

    ; A long compare: r1 against r2 or the immediate.  It leaves what the short ones
    ; leave: carry is "less", zero is "equal".
    sub long_compare(^^ir.Instr i, bool with_register, bool signed) {
        ubyte k
        ubyte group = 1
        if with_register
            group = 2
        if signed {
            ; (the top bytes with their top bit turned over, in H and C until they are needed)
            if with_register
                a_from_reg(i.r2, 3)
            else
                a_imm((i.value >> 24) as long)
            line("xor  $80")
            line("ld  h,a")
            a_from_reg(i.r1, 3)
            line("xor  $80")
            line("ld  c,a")
        }
        for k in 0 to 3 {
            if k == 3 and signed {
                line("ld  b,h")
                line("ld  a,c")
            }
            else {
                second_b(i, group, k)
                a_from_reg(i.r1, k)
            }
            if k == 0
                line("sub  b")
            else
                line("sbc  a,b")
            when k {
                0 -> line("ld  e,a")
                1 -> line("ld  d,a")
                2 -> line("ld  l,a")
                else -> line("ld  h,a")
            }
        }
        ; (the carry is kept while the difference is tested for zero)
        line("sbc  a,a")
        line("ld  c,a")
        line("ld  a,e")
        line("or  d")
        line("or  l")
        line("or  h")
        line("ld  a,c")
        line("rrca")
    }

    sub logic16(str mnemonic) {
        line("ld  a,l")
        start(mnemonic)
        put("e")
        nl()
        line("ld  l,a")
        line("ld  a,h")
        start(mnemonic)
        put("d")
        nl()
        line("ld  h,a")
    }

    ; a long in register r1 op= a long: byte by byte with the carry
    sub long_from_mem(uword r, ^^ir.Instr i) {
        pair_from_mem("hl", i, 0)
        reg_from_pair(r, 0, "hl")
        pair_from_mem("hl", i, 2)
        reg_from_pair(r, 2, "hl")
    }

    sub mem_from_long(^^ir.Instr i, uword r) {
        pair_from_reg("hl", r, 0)
        mem_from_pair(i, 0, "hl")
        pair_from_reg("hl", r, 2)
        mem_from_pair(i, 2, "hl")
    }

    ; flags for the branch that follows: the value of register r as it is (zero or not;
    ; for the sign, its top byte)
    sub test_reg(uword r, ubyte size, bool sign) {
        if size == 0
            return
        if sign or size == 1 {
            a_from_reg(r, size - 1)
            line("or  a")
        }
        else {
            pair_from_reg("hl", r, 0)
            line("ld  a,h")
            line("or  l")
            if size == 4 {
                pair_from_reg("hl", r, 2)
                line("or  h")
                line("or  l")
            }
        }
    }

    ; Is the flag state that a status branch needs what the instruction before left?  A
    ; compare leaves it; after anything else that gave a register its value, the value is
    ; tested again here.
    sub flags_for_branch(bool sign) {
        if previous == 0
            return
        if sign and previous.op == ir.OP_CMPI and previous.value == 0 {
            ; (a compare with 0 and then the sign: the value's own)
            test_reg(previous.r1, size_of(type1(previous)), true)
            return
        }
        when previous.op {
            ir.OP_LOAD, ir.OP_LOADM, ir.OP_LOADMZ, ir.OP_LOADR, ir.OP_LOADI, ir.OP_LOADX, ir.OP_STOREM, ir.OP_STOREI,
            ir.OP_STOREX, ir.OP_LOADHR, ir.OP_LSIGB, ir.OP_LSIGW, ir.OP_MSIGB, ir.OP_MSIGW, ir.OP_EXT, ir.OP_EXTS, ir.OP_EXTL, ir.OP_EXTLS,
            ir.OP_CONCAT, ir.OP_INC, ir.OP_DEC, ir.OP_NEG, ir.OP_INV, ir.OP_SGN, ir.OP_POP,
            ir.OP_ADD, ir.OP_SUB, ir.OP_AND, ir.OP_OR, ir.OP_XOR, ir.OP_MUL, ir.OP_MULS, ir.OP_DIV, ir.OP_DIVS, ir.OP_MOD, ir.OP_MODS,
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_ANDR, ir.OP_ORR, ir.OP_XORR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_DIVSR,
            ir.OP_MODR, ir.OP_MODSR, ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI,
            ir.OP_LSLN, ir.OP_LSRN, ir.OP_ASRN -> {
                if previous.r1 != 0 and previous.mode != ir.M_IM
                    test_reg(previous.r1, size_of(ir.regtypes[previous.r1]), sign)
            }
        }
    }

    ; "jp cc,target"
    sub jump_if(str condition, ^^ubyte target) {
        start("jp")
        put(condition)
        put(",")
        name(target)
        nl()
    }

    sub jump_if_local(str condition, long n) {
        start("jp")
        put(condition)
        put(",")
        put_local(n)
        nl()
    }

    ; first operand of a compare into A or HL, the second into B or DE, signed ones with
    ; their top bit turned over (then the unsigned compare says the signed order)
    sub compare_operands(^^ir.Instr i, ubyte size, bool with_register, bool signed) {
        if with_register
            second_reg(i.r2, size)
        else
            second_imm(i.value as long, size)
        if signed {
            if size == 1 {
                line("ld  a,b")
                line("xor  $80")
                line("ld  b,a")
            }
            else {
                line("ld  a,d")
                line("xor  $80")
                line("ld  d,a")
            }
        }
        fetch(i.r1, size)
        if signed {
            if size == 1
                line("xor  $80")
            else {
                line("ld  a,h")
                line("xor  $80")
                line("ld  h,a")
            }
        }
        if size == 1
            line("cp  b")
        else {
            line("or  a")
            line("sbc  hl,de")
        }
    }

    ; a compare and a branch: carry is "less", zero is "equal"
    sub compare_branch(^^ir.Instr i, bool with_register, bool signed, ubyte relation) {
        ubyte size = size_of(type1(i))
        if size == 4
            long_compare(i, with_register, signed)
        else if size == 1 or size == 2
            compare_operands(i, size, with_register, signed)
        else {
            unsupported(i)
            return
        }
        when relation {
            0 -> {
                ; greater: not less and not equal
                long skip = new_label()
                jump_if_local("z", skip)
                jump_if("nc", i.sym)
                local(skip)
            }
            1 -> jump_if("c", i.sym)        ; less
            2 -> jump_if("nc", i.sym)       ; greater or equal
            3 -> {
                jump_if("c", i.sym)         ; less or equal
                jump_if("z", i.sym)
            }
        }
    }

    sub instruction(^^ir.Instr i) {
        ubyte size = size_of(i.type)
        ubyte k
        when i.op {
            ir.OP_NOP, ir.OP_BREAKPOINT, ir.OP_ALIGN -> {
            }
            ir.OP_LOAD -> {
                if i.sym != 0 {
                    start("ld")
                    put("hl,")
                    mem_name(i, 0)
                    nl()
                    reg_from_pair(i.r1, 0, "hl")
                }
                else if size == 1 {
                    a_imm(i.value as long)
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    pair_imm("hl", i.value as long)
                    reg_from_pair(i.r1, 0, "hl")
                }
                else if size == 4 {
                    pair_imm("hl", i.value as long)
                    reg_from_pair(i.r1, 0, "hl")
                    pair_imm("hl", (i.value >> 16) as long)
                    reg_from_pair(i.r1, 2, "hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_LOADM -> {
                if size == 1 {
                    a_from_mem(i, 0)
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    pair_from_mem("hl", i, 0)
                    reg_from_pair(i.r1, 0, "hl")
                }
                else if size == 4
                    long_from_mem(i.r1, i)
                else
                    unsupported(i)
            }
            ir.OP_LOADMZ -> {
                ; a byte from memory into a wider register, the rest zero
                a_from_mem(i, 0)
                reg_from_a(i.r1, 0)
                line("xor  a")
                for k in 1 to size_of(ir.regtypes[i.r1]) - 1
                    reg_from_a(i.r1, k)
            }
            ir.OP_LOADR -> {
                if size == 0
                    unsupported(i)
                else for k in 0 to size - 1 {
                    a_from_reg(i.r2, k)
                    reg_from_a(i.r1, k)
                }
            }
            ir.OP_LOADX -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_address(i, true)
                    reg_from_hl(i.r1, size)
                }
            }
            ir.OP_LOADI -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_pointer(i)
                    reg_from_hl(i.r1, size)
                }
            }
            ir.OP_LOADHR, ir.OP_STOREHR -> {
                if size == 0 or i.slot >= ir.SLOT_FLAGS {
                    unsupported(i)
                    return
                }
                for k in 0 to size - 1 {
                    if i.op == ir.OP_LOADHR {
                        start("ld")
                        put("a,(")
                        slot(i.slot, k)
                        put(")")
                        nl()
                        reg_from_a(i.r1, k)
                    }
                    else {
                        a_from_reg(i.r1, k)
                        start("ld")
                        put("(")
                        slot(i.slot, k)
                        put("),a")
                        nl()
                    }
                }
            }
            ir.OP_STOREM -> {
                if size == 1 {
                    a_from_reg(i.r1, 0)
                    mem_from_a(i, 0)
                }
                else if size == 2 {
                    pair_from_reg("hl", i.r1, 0)
                    mem_from_pair(i, 0, "hl")
                }
                else if size == 4
                    mem_from_long(i, i.r1)
                else
                    unsupported(i)
            }
            ir.OP_STOREZM -> {
                if size == 0
                    unsupported(i)
                else {
                    line("xor  a")
                    for k in 0 to size - 1
                        mem_from_a(i, k)
                }
            }
            ir.OP_STOREIM -> {
                if size == 0
                    unsupported(i)
                else for k in 0 to size - 1 {
                    a_imm((i.value >> (k * 8)) as long)
                    mem_from_a(i, k)
                }
            }
            ir.OP_STOREX -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_address(i, true)
                    hl_from_reg(i.r1, size)
                }
            }
            ir.OP_STOREZX -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_address(i, true)
                    for k in 0 to size - 1 {
                        line("ld  (hl),0")
                        if k != size - 1
                            line("inc  hl")
                    }
                }
            }
            ir.OP_STOREI -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_pointer(i)
                    hl_from_reg(i.r1, size)
                }
            }
            ir.OP_STOREZI -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_pointer(i)
                    for k in 0 to size - 1 {
                        line("ld  (hl),0")
                        if k != size - 1
                            line("inc  hl")
                    }
                }
            }
            ir.OP_JUMP -> {
                start("jp")
                name(i.sym)
                nl()
            }
            ir.OP_JUMPI -> {
                pair_from_reg("hl", i.r1, 0)
                line("jp  (hl)")
            }
            ir.OP_CALL -> call_instruction(i)
            ir.OP_CALLI -> {
                pair_from_reg("hl", i.r1, 0)
                line("call  p8rt_jphl")
                need_jphl = true
                ; (what it returns is taken from slot 10 by the code that follows: a byte
                ; is returned in A and in L, see OP_RETURNR)
                start("ld")
                put("(")
                slot(10, 0)
                put("),hl")
                nl()
            }
            ir.OP_SYSCALL -> syscall(i)
            ir.OP_RETURN -> line("ret")
            ir.OP_RETURNR -> {
                if size != 0 {
                    fetch(i.r1, size)
                    if size == 1
                        line("ld  l,a")         ; (for a caller through a pointer, which takes HL)
                    line("ret")
                }
                else
                    unsupported(i)
            }
            ir.OP_RETURNI -> {
                if size == 1 {
                    a_imm(i.value as long)
                    line("ld  l,a")
                }
                else if size == 2
                    pair_imm("hl", i.value as long)
                else if size == 4 {
                    pair_imm("hl", i.value as long)
                    pair_imm("de", (i.value >> 16) as long)
                }
                else
                    unsupported(i)
                line("ret")
            }
            ir.OP_BSTEQ -> {
                flags_for_branch(false)
                jump_if("z", i.sym)
            }
            ir.OP_BSTNE -> {
                flags_for_branch(false)
                jump_if("nz", i.sym)
            }
            ir.OP_BSTNEG -> {
                flags_for_branch(true)
                jump_if("m", i.sym)
            }
            ir.OP_BSTPOS -> {
                flags_for_branch(true)
                jump_if("p", i.sym)
            }
            ; (the IR's carry is the 6502's: clear after a compare means "less".  A compare
            ; here leaves the Z80's, which is set then.)
            ir.OP_BSTCC -> {
                carry_in(i)
                if not carry_loaded and previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("c", i.sym)
                else
                    jump_if("nc", i.sym)
            }
            ir.OP_BSTCS -> {
                carry_in(i)
                if not carry_loaded and previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("nc", i.sym)
                else
                    jump_if("c", i.sym)
            }
            ir.OP_CMP -> {
                if size == 1 or size == 2
                    compare_operands(i, size, true, false)
                else if size == 4
                    long_compare(i, true, false)
                else
                    unsupported(i)
            }
            ir.OP_CMPI -> {
                if size == 1 or size == 2
                    compare_operands(i, size, false, false)
                else if size == 4
                    long_compare(i, false, false)
                else
                    unsupported(i)
            }
            ir.OP_BGT -> compare_branch(i, false, false, 0)
            ir.OP_BGTR -> compare_branch(i, true, false, 0)
            ir.OP_BLT -> compare_branch(i, false, false, 1)
            ir.OP_BGE -> compare_branch(i, false, false, 2)
            ir.OP_BGER -> compare_branch(i, true, false, 2)
            ir.OP_BLE -> compare_branch(i, false, false, 3)
            ir.OP_BGTS -> compare_branch(i, false, true, 0)
            ir.OP_BGTSR -> compare_branch(i, true, true, 0)
            ir.OP_BLTS -> compare_branch(i, false, true, 1)
            ir.OP_BGES -> compare_branch(i, false, true, 2)
            ir.OP_BGESR -> compare_branch(i, true, true, 2)
            ir.OP_BLES -> compare_branch(i, false, true, 3)
            ir.OP_INC, ir.OP_DEC -> {
                if size == 1 {
                    a_from_reg(i.r1, 0)
                    if i.op == ir.OP_INC
                        line("inc  a")
                    else
                        line("dec  a")
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    pair_from_reg("hl", i.r1, 0)
                    if i.op == ir.OP_INC
                        line("inc  hl")
                    else
                        line("dec  hl")
                    reg_from_pair(i.r1, 0, "hl")
                    line("ld  a,h")
                    line("or  l")
                }
                else if size == 4
                    step_long(i, 1, i.op == ir.OP_INC)
                else
                    unsupported(i)
            }
            ir.OP_INCM, ir.OP_DECM -> {
                if size == 1 {
                    start("ld")
                    put("hl,")
                    mem_name(i, 0)
                    nl()
                    if i.op == ir.OP_INCM
                        line("inc  (hl)")
                    else
                        line("dec  (hl)")
                }
                else if size == 2 {
                    pair_from_mem("hl", i, 0)
                    if i.op == ir.OP_INCM
                        line("inc  hl")
                    else
                        line("dec  hl")
                    mem_from_pair(i, 0, "hl")
                    line("ld  a,h")
                    line("or  l")
                }
                else if size == 4 {
                    step_long(i, 3, i.op == ir.OP_INCM)
                    pair_from_mem("hl", i, 0)
                    line("ld  a,h")
                    line("or  l")
                    pair_from_mem("hl", i, 2)
                    line("or  h")
                    line("or  l")
                }
                else
                    unsupported(i)
            }
            ir.OP_ADD, ir.OP_SUB, ir.OP_AND, ir.OP_OR, ir.OP_XOR, ir.OP_MUL, ir.OP_MULS, ir.OP_DIV, ir.OP_DIVS,
            ir.OP_MOD, ir.OP_MODS -> arith(i, 1)
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_ANDR, ir.OP_ORR, ir.OP_XORR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_DIVSR,
            ir.OP_MODR, ir.OP_MODSR -> arith(i, 2)
            ir.OP_ADDM, ir.OP_SUBM, ir.OP_ANDM, ir.OP_ORM, ir.OP_XORM, ir.OP_MULM, ir.OP_MULSM, ir.OP_DIVM,
            ir.OP_DIVSM -> arith(i, 3)
            ir.OP_ADDIM, ir.OP_SUBIM -> arith(i, 4)
            ir.OP_DIVMOD, ir.OP_DIVMODR, ir.OP_SDIVMOD, ir.OP_SDIVMODR -> quotient_and_rest(i)
            ir.OP_NEG -> {
                if size == 0
                    unsupported(i)
                else
                    negate(i, 1, size)
            }
            ir.OP_NEGM -> {
                if size == 0
                    unsupported(i)
                else
                    negate(i, 3, size)
            }
            ir.OP_INV, ir.OP_INVM -> {
                ubyte where = 1
                if i.op == ir.OP_INVM
                    where = 3
                if size == 0
                    unsupported(i)
                else for k in 0 to size - 1 {
                    first_a(i, where, k)
                    line("cpl")
                    a_first(i, where, k)
                }
            }
            ir.OP_SGN -> {
                ; r1 (a byte) = the sign of r2: -1, 0 or 1
                if size == 0 {
                    unsupported(i)
                    return
                }
                long signed = new_label()
                a_from_reg(i.r2, size - 1)
                line("or  a")
                line("ld  a,255")
                jump_if_local("m", signed)
                a_from_reg(i.r2, 0)
                if size == 1
                    line("or  a")
                else for k in 1 to size - 1 {
                    line("ld  b,a")
                    a_from_reg(i.r2, k)
                    line("or  b")
                }
                jump_if_local("z", signed)
                line("ld  a,1")
                local(signed)
                reg_from_a(i.r1, 0)
            }
            ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_ROL, ir.OP_ROR, ir.OP_ROXL, ir.OP_ROXR -> shift_register(i, 1, size, 1)
            ir.OP_LSLM, ir.OP_LSRM, ir.OP_ASRM, ir.OP_ROLM, ir.OP_RORM, ir.OP_ROXLM, ir.OP_ROXRM -> shift_register(i, 1, size, 3)
            ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI -> shift_register(i, (i.value & 255) as ubyte, size, 1)
            ir.OP_LSLN, ir.OP_LSRN, ir.OP_ASRN, ir.OP_LSLNM, ir.OP_LSRNM, ir.OP_ASRNM -> {
                ; by the number in a register (r2; r1 when memory is shifted): one bit at a time
                if size == 0 {
                    unsupported(i)
                    return
                }
                long again = new_label()
                long done = new_label()
                ubyte place = 1
                if i.op == ir.OP_LSLNM or i.op == ir.OP_LSRNM or i.op == ir.OP_ASRNM {
                    place = 3
                    a_from_reg(i.r1, 0)
                }
                else
                    a_from_reg(i.r2, 0)
                line("or  a")
                jump_if_local("z", done)
                line("ld  c,a")
                local(again)
                shift_once(i.op, i, place, size)
                line("dec  c")
                jump_if_local("nz", again)
                local(done)
            }
            ir.OP_EXT, ir.OP_EXTS, ir.OP_EXTL, ir.OP_EXTLS -> {
                ; r1 (the next wider type) = r2 (the instruction's type)
                ubyte wide = size_of(ir.regtypes[i.r1])
                if size == 0 or wide <= size {
                    unsupported(i)
                    return
                }
                for k in 0 to size - 1 {
                    a_from_reg(i.r2, k)
                    reg_from_a(i.r1, k)
                }
                if i.op == ir.OP_EXTS or i.op == ir.OP_EXTLS {
                    ; (A is the top byte still: all ones when it is negative)
                    line("rlca")
                    line("sbc  a,a")
                }
                else
                    line("xor  a")
                for k in size to wide - 1
                    reg_from_a(i.r1, k)
            }
            ir.OP_LSIGB, ir.OP_LSIGW -> {
                ; the low byte (word) of r2
                ubyte part = 1
                if i.op == ir.OP_LSIGW
                    part = 2
                for k in 0 to part - 1 {
                    a_from_reg(i.r2, k)
                    reg_from_a(i.r1, k)
                }
            }
            ir.OP_MSIGB -> {
                ; the high byte of r2, which is of the instruction's type
                a_from_reg(i.r2, size - 1)
                reg_from_a(i.r1, 0)
            }
            ir.OP_MSIGW -> {
                a_from_reg(i.r2, 2)
                reg_from_a(i.r1, 0)
                a_from_reg(i.r2, 3)
                reg_from_a(i.r1, 1)
            }
            ir.OP_CONCAT -> {
                ; r1 = r2 (the high half) and r3 (the low half), each of the instruction's type
                if size == 1 or size == 2 {
                    for k in 0 to size - 1 {
                        a_from_reg(i.r3, k)
                        reg_from_a(i.r1, k)
                        a_from_reg(i.r2, k)
                        reg_from_a(i.r1, size + k)
                    }
                }
                else
                    unsupported(i)
            }
            ir.OP_PUSH -> {
                if size == 1 {
                    a_from_reg(i.r1, 0)
                    line("push  af")
                }
                else if size == 2 {
                    pair_from_reg("hl", i.r1, 0)
                    line("push  hl")
                }
                else if size == 4 {
                    pair_from_reg("hl", i.r1, 2)
                    line("push  hl")
                    pair_from_reg("hl", i.r1, 0)
                    line("push  hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_POP -> {
                if size == 1 {
                    line("pop  af")
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    line("pop  hl")
                    reg_from_pair(i.r1, 0, "hl")
                }
                else if size == 4 {
                    line("pop  hl")
                    reg_from_pair(i.r1, 0, "hl")
                    line("pop  hl")
                    reg_from_pair(i.r1, 2, "hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_SQRT -> {
                ; r1 = the square root of r2 (a whole number, rounded down)
                if size == 0 {
                    unsupported(i)
                    return
                }
                for k in 0 to 3 {
                    if k < size
                        a_from_reg(i.r2, k)
                    else if k == size
                        line("xor  a")
                    start("ld")
                    put("(p8_la+")
                    putn(k)
                    put("),a")
                    nl()
                }
                line("call  p8rt_sqrt32")
                need_rt[RT_SQRT] = true
                need_long = true
                line("ld  a,l")
                reg_from_a(i.r1, 0)
                if size_of(ir.regtypes[i.r1]) >= 2 {
                    line("ld  a,h")
                    reg_from_a(i.r1, 1)
                }
            }
            ir.OP_CLC -> line("or  a")
            ir.OP_SEC -> line("scf")
            else -> unsupported(i)
        }
    }

    ; One bit, of a register (place 1) or of memory (place 3): the bytes from the end that
    ; the bit leaves.  The rox ones take the carry in; rol and ror put the bit that left
    ; in at the other end.
    sub shift_once(ubyte op, ^^ir.Instr i, ubyte place, ubyte size) {
        ubyte k
        bool through = op == ir.OP_ROXL or op == ir.OP_ROXLM or op == ir.OP_ROXR or op == ir.OP_ROXRM
        bool around = op == ir.OP_ROL or op == ir.OP_ROLM or op == ir.OP_ROR or op == ir.OP_RORM
        bool left = false
        when op {
            ir.OP_LSL, ir.OP_LSLI, ir.OP_LSLN, ir.OP_LSLM, ir.OP_LSLNM, ir.OP_ROL, ir.OP_ROLM, ir.OP_ROXL, ir.OP_ROXLM -> left = true
        }
        long skip = 0
        if left {
            for k in 0 to size - 1 {
                first_a(i, place, k)
                if k == 0 and not through
                    line("add  a,a")
                else
                    line("rla")
                a_first(i, place, k)
            }
            if around {
                skip = new_label()
                jump_if_local("nc", skip)
                first_a(i, place, 0)
                line("inc  a")
                a_first(i, place, 0)
                local(skip)
            }
        }
        else {
            k = size
            while k != 0 {
                k--
                first_a(i, place, k)
                if k == size - 1 and not through {
                    if op == ir.OP_ASR or op == ir.OP_ASRI or op == ir.OP_ASRN or op == ir.OP_ASRM or op == ir.OP_ASRNM
                        line("sra  a")
                    else
                        line("srl  a")
                }
                else
                    line("rra")
                a_first(i, place, k)
            }
            if around {
                skip = new_label()
                jump_if_local("nc", skip)
                first_a(i, place, size - 1)
                line("set  7,a")
                a_first(i, place, size - 1)
                local(skip)
            }
        }
    }

    sub shift_register(^^ir.Instr i, ubyte count, ubyte size, ubyte place) {
        if size == 0 {
            unsupported(i)
            return
        }
        if carry_rotation(i.op)
            carry_in(i)
        repeat count
            shift_once(i.op, i, place, size)
    }

    ; A call: the arguments into the subroutine's parameters, by their names; a result
    ; comes back in A or HL.
    sub call_instruction(^^ir.Instr i) {
        ^^ir.Arg a = i.args
        while a != 0 {
            ubyte size = size_of(a.type)
            if a.name == 0 or size == 0 or size > 4 {
                error("the arguments of this call cannot be passed on the Z80 yet", i.sym)
                return
            }
            ubyte k
            for k in 0 to size - 1 {
                if a.reg != 0
                    a_from_reg(a.reg, k)
                else
                    a_imm((a.value >> (k * 8)) as long)
                start("ld")
                put("(")
                ; (the parameter: a variable of the subroutine, named there without its scope)
                if not text_has(a.name, ".") {
                    name(i.sym)
                    put("_")
                    put(a.name)
                }
                else
                    name(a.name)
                if k != 0 {
                    put("+")
                    putn(k)
                }
                put("),a")
                nl()
            }
            a = a.next
        }
        start("call")
        name(i.sym)
        nl()
        ^^ir.Arg r = i.results
        if r != 0 {
            ubyte rsize = size_of(r.type)
            if r.next != 0 or r.reg == 0 or rsize == 0 {
                error("the results of this call cannot be taken on the Z80 yet", i.sym)
                return
            }
            keep(r.reg, rsize)
        }
    }

    ; ---- system calls: CP/M ----

    sub arg_n(^^ir.Instr i, ubyte n) -> ^^ir.Arg {
        ^^ir.Arg a = i.args
        while a != 0 and n != 0 {
            a = a.next
            n--
        }
        return a
    }

    ; an argument of a system call into A, or into a register pair
    sub arg_a(^^ir.Arg a) {
        if a == 0
            error("a system call without the arguments it needs", 0)
        else if a.reg != 0
            a_from_reg(a.reg, 0)
        else
            a_imm(a.value as long)
    }

    sub arg_pair(^^ir.Arg a, str pair) {
        if a == 0
            error("a system call without the arguments it needs", 0)
        else if a.reg != 0 {
            if size_of(a.type) == 1 {
                ; (a byte where a word is wanted)
                a_from_reg(a.reg, 0)
                start("ld")
                put(pair)
                put(",0")
                nl()
                start("ld")
                buf.add_byte(o, pair[1])
                put(",a")
                nl()
            }
            else
                pair_from_reg(pair, a.reg, 0)
        }
        else
            pair_imm(pair, a.value as long)
    }

    sub call_rt(ubyte which, str routine) {
        need_rt[which] = true
        start("call")
        put(routine)
        nl()
    }

    ; The system calls: what the library asks of the machine (the low numbers, as the
    ; virtual machine has them), and the builtin functions that the IR leaves to the
    ; back end (from $1000).  A result is in A or HL.
    sub syscall(^^ir.Instr i) {
        ^^ir.Arg a0 = arg_n(i, 0)
        ^^ir.Arg a1 = arg_n(i, 1)
        ^^ir.Arg a2 = arg_n(i, 2)
        ^^ir.Arg res = i.results
        when i.value as long {
            1 -> line("jp  p8_exit")        ; the end of the program, as the target ends one
            2 -> {
                ; a character to the console (BDOS function 2)
                arg_a(a0)
                line("ld  e,a")
                line("ld  c,2")
                line("call  5")
            }
            3 -> {
                ; a string that ends with 0
                arg_pair(a0, "hl")
                line("call  p8rt_print")
                need_print = true
            }
            36 -> {
                ; copy memory: from, to, how many bytes (they may overlap)
                arg_pair(a0, "hl")
                arg_pair(a1, "de")
                arg_pair(a2, "bc")
                call_rt(RT_MOVE, "p8rt_move")
            }
            37 -> {
                ; fill memory: where, how many bytes, the value
                arg_a(a2)
                line("ld  e,a")
                arg_pair(a0, "hl")
                arg_pair(a1, "bc")
                call_rt(RT_FILL, "p8rt_fill")
            }
            38 -> {
                ; fill memory with a word: where, how many words, the value
                arg_pair(a0, "hl")
                arg_pair(a1, "bc")
                arg_pair(a2, "de")
                call_rt(RT_FILLW, "p8rt_fillw")
            }
            69 -> {
                ; a character from the console, waited for and shown (BDOS function 1)
                line("ld  c,1")
                line("call  5")
            }
            217 -> {
                ; a key, or 0 when none is waiting (BDOS function 6)
                line("ld  e,255")
                line("ld  c,6")
                line("call  5")
            }
            218 -> call_rt(RT_WAITKEY, "p8rt_waitkey")
            $100d -> {
                ; compare two strings: -1, 0 or 1
                arg_pair(a0, "hl")
                arg_pair(a1, "de")
                call_rt(RT_STRCMP, "p8rt_strcmp")
            }
            $100e -> {
                ; is a character in a string
                arg_a(a0)
                line("ld  b,a")
                arg_pair(a1, "hl")
                call_rt(RT_INSTR, "p8rt_instr")
            }
            $100f -> {
                ; is a byte in an array: the value, the array, its length
                arg_a(a0)
                line("ld  e,a")
                arg_pair(a1, "hl")
                arg_pair(a2, "bc")
                call_rt(RT_INBYTES, "p8rt_inbytes")
            }
            $1010 -> {
                arg_pair(a0, "de")
                arg_pair(a1, "hl")
                arg_pair(a2, "bc")
                call_rt(RT_INWORDS, "p8rt_inwords")
            }
            $1012, $1013 -> {
                ; clamp a byte: the value, the least, the most
                arg_a(a1)
                line("ld  b,a")
                arg_a(a2)
                line("ld  c,a")
                arg_a(a0)
                need_rt[RT_CLAMP8] = true
                if i.value == $1013
                    call_rt(RT_CLAMPS8, "p8rt_clamps8")
                else
                    line("call  p8rt_clamp8")
            }
            $1014, $1015 -> {
                arg_pair(a0, "hl")
                arg_pair(a1, "de")
                arg_pair(a2, "bc")
                need_rt[RT_CLAMP16] = true
                if i.value == $1015
                    call_rt(RT_CLAMPS16, "p8rt_clamps16")
                else
                    line("call  p8rt_clamp16")
            }
            else -> {
                buf.clear(nb)
                buf.add_long(nb, i.value as long)
                buf.add_byte(nb, 0)
                error("this system call is not there for CP/M yet", nb.data)
                return
            }
        }
        if res != 0 and res.reg != 0 {
            ubyte rsize = size_of(res.type)
            if rsize == 1 or rsize == 2
                keep(res.reg, rsize)
            else
                error("the result of this system call cannot be taken on the Z80 yet", 0)
        }
    }

    ; the routines of the system calls that the program uses
    sub runtime_calls() {
        if need_rt[RT_MOVE] {
            raw("; copies BC bytes from HL to DE; the two may overlap")
            raw("p8rt_move:")
            line("ld  a,b")
            line("or  c")
            line("ret  z")
            line("push  hl")
            line("or  a")
            line("sbc  hl,de")
            line("pop  hl")
            line("jr  c,p8rt_move_back")
            line("ldir")
            line("ret")
            raw("p8rt_move_back:")
            line("add  hl,bc")
            line("dec  hl")
            line("ex  de,hl")
            line("add  hl,bc")
            line("dec  hl")
            line("ex  de,hl")
            line("lddr")
            line("ret")
            nl()
        }
        if need_rt[RT_FILL] {
            raw("; fills BC bytes at HL with E")
            raw("p8rt_fill:")
            line("ld  a,b")
            line("or  c")
            line("ret  z")
            line("ld  (hl),e")
            line("inc  hl")
            line("dec  bc")
            line("jr  p8rt_fill")
            nl()
        }
        if need_rt[RT_FILLW] {
            raw("; fills BC words at HL with DE")
            raw("p8rt_fillw:")
            line("ld  a,b")
            line("or  c")
            line("ret  z")
            line("ld  (hl),e")
            line("inc  hl")
            line("ld  (hl),d")
            line("inc  hl")
            line("dec  bc")
            line("jr  p8rt_fillw")
            nl()
        }
        if need_rt[RT_WAITKEY] {
            raw("; waits for a key and gives it in A, without showing it")
            raw("p8rt_waitkey:")
            line("ld  e,255")
            line("ld  c,6")
            line("call  5")
            line("or  a")
            line("jr  z,p8rt_waitkey")
            line("ret")
            nl()
        }
        if need_rt[RT_STRCMP] {
            raw("; compares the strings at HL and DE: A = 0 the same, 1 the first is greater, 255 it is less")
            raw("p8rt_strcmp:")
            line("ld  a,(de)")
            line("ld  b,a")
            line("ld  a,(hl)")
            line("cp  b")
            line("jr  nz,p8rt_strcmp_differ")
            line("or  a")
            line("ret  z")
            line("inc  hl")
            line("inc  de")
            line("jr  p8rt_strcmp")
            raw("p8rt_strcmp_differ:")
            line("ld  a,1")
            line("ret  nc")
            line("ld  a,255")
            line("ret")
            nl()
        }
        if need_rt[RT_INSTR] {
            raw("; is the character in B in the string at HL: A = 1 or 0")
            raw("p8rt_instr:")
            line("ld  a,(hl)")
            line("or  a")
            line("ret  z")
            line("cp  b")
            line("inc  hl")
            line("jr  nz,p8rt_instr")
            line("ld  a,1")
            line("ret")
            nl()
        }
        if need_rt[RT_INBYTES] {
            raw("; is the byte in E among the BC bytes at HL: A = 1 or 0")
            raw("p8rt_inbytes:")
            line("ld  a,b")
            line("or  c")
            line("ret  z")
            line("ld  a,(hl)")
            line("cp  e")
            line("inc  hl")
            line("dec  bc")
            line("jr  nz,p8rt_inbytes")
            line("ld  a,1")
            line("ret")
            nl()
        }
        if need_rt[RT_INWORDS] {
            raw("; is the word in DE among the BC words at HL: A = 1 or 0")
            raw("p8rt_inwords:")
            line("ld  a,b")
            line("or  c")
            line("ret  z")
            line("ld  a,(hl)")
            line("inc  hl")
            line("cp  e")
            line("jr  nz,p8rt_inwords_next")
            line("ld  a,(hl)")
            line("cp  d")
            line("jr  nz,p8rt_inwords_next")
            line("ld  a,1")
            line("ret")
            raw("p8rt_inwords_next:")
            line("inc  hl")
            line("dec  bc")
            line("jr  p8rt_inwords")
            nl()
        }
        if need_rt[RT_CLAMPS8] {
            raw("; A = A kept between B and C, signed: with the top bits turned over it is the unsigned one")
            raw("p8rt_clamps8:")
            line("xor  $80")
            line("ld  d,a")
            line("ld  a,b")
            line("xor  $80")
            line("ld  b,a")
            line("ld  a,c")
            line("xor  $80")
            line("ld  c,a")
            line("ld  a,d")
            line("call  p8rt_clamp8")
            line("xor  $80")
            line("ret")
            nl()
        }
        if need_rt[RT_CLAMP8] {
            raw("; A = A kept between B and C")
            raw("p8rt_clamp8:")
            line("cp  b")
            line("jr  nc,p8rt_clamp8_top")
            line("ld  a,b")
            raw("p8rt_clamp8_top:")
            line("cp  c")
            line("ret  c")
            line("ld  a,c")
            line("ret")
            nl()
        }
        if need_rt[RT_CLAMPS16] {
            raw("; HL = HL kept between DE and BC, signed")
            raw("p8rt_clamps16:")
            line("ld  a,h")
            line("xor  $80")
            line("ld  h,a")
            line("ld  a,d")
            line("xor  $80")
            line("ld  d,a")
            line("ld  a,b")
            line("xor  $80")
            line("ld  b,a")
            line("call  p8rt_clamp16")
            line("ld  a,h")
            line("xor  $80")
            line("ld  h,a")
            line("ret")
            nl()
        }
        if need_rt[RT_CLAMP16] {
            raw("; HL = HL kept between DE and BC")
            raw("p8rt_clamp16:")
            line("push  hl")
            line("or  a")
            line("sbc  hl,de")
            line("pop  hl")
            line("jr  nc,p8rt_clamp16_top")
            line("ld  h,d")
            line("ld  l,e")
            raw("p8rt_clamp16_top:")
            line("push  hl")
            line("or  a")
            line("sbc  hl,bc")
            line("pop  hl")
            line("ret  c")
            line("ld  h,b")
            line("ld  l,c")
            line("ret")
            nl()
        }
        if need_rt[RT_SQRT] {
            raw("; HL = the square root of the long in p8_la, rounded down: two bits of the number")
            raw("; at a time into the rest (C and HL), the root in DE")
            raw("p8rt_sqrt32:")
            line("ld  ix,p8_la")
            line("ld  hl,0")
            line("ld  c,l")
            line("ld  d,h")
            line("ld  e,l")
            line("ld  b,16")
            raw("p8rt_sqrt32_bit:")
            repeat 2 {
                line("sla  (ix+0)")
                line("rl  (ix+1)")
                line("rl  (ix+2)")
                line("rl  (ix+3)")
                line("adc  hl,hl")
                line("rl  c")
            }
            line("sla  e")
            line("rl  d")
            line("push  hl")
            line("push  de")
            line("ex  de,hl")
            line("add  hl,hl")
            line("ld  a,0")
            line("adc  a,0")
            line("inc  hl")
            line("ex  de,hl")
            line("or  a")
            line("sbc  hl,de")
            line("ld  d,a")
            line("ld  a,c")
            line("sbc  a,d")
            line("pop  de")
            line("jr  c,p8rt_sqrt32_less")
            line("ld  c,a")
            line("inc  e")
            line("pop  af")
            line("jr  p8rt_sqrt32_next")
            raw("p8rt_sqrt32_less:")
            line("pop  hl")
            raw("p8rt_sqrt32_next:")
            line("djnz  p8rt_sqrt32_bit")
            line("ex  de,hl")
            line("ret")
            nl()
        }
    }

    ; ---- what the code calls ----

    sub runtime() {
        if need_print {
            raw("; prints the string at HL (it ends with 0)")
            raw("p8rt_print:")
            line("ld  a,(hl)")
            line("or  a")
            line("ret  z")
            line("push  hl")
            line("ld  e,a")
            line("ld  c,2")
            line("call  5")
            line("pop  hl")
            line("inc  hl")
            line("jr  p8rt_print")
            nl()
        }
        if need_jphl {
            raw("p8rt_jphl:")
            line("jp  (hl)")
            nl()
        }
        if need_mul {
            raw("; HL = HL * DE (the low 16 bits)")
            raw("p8rt_mul16:")
            line("ld  b,h")
            line("ld  c,l")
            line("ld  hl,0")
            line("ld  a,16")
            raw("p8rt_mul16_bit:")
            line("add  hl,hl")
            line("rl  c")
            line("rl  b")
            line("jr  nc,p8rt_mul16_next")
            line("add  hl,de")
            raw("p8rt_mul16_next:")
            line("dec  a")
            line("jr  nz,p8rt_mul16_bit")
            line("ret")
            nl()
        }
        runtime_long()
        runtime_calls()
        if need_div {
            raw("; HL = HL / DE, DE = the remainder (unsigned; a division by 0 gives $ffff)")
            raw("p8rt_div16:")
            line("ld  b,h")
            line("ld  c,l")
            line("ld  hl,0")
            line("ld  a,16")
            raw("p8rt_div16_bit:")
            line("sla  c")
            line("rl  b")
            line("adc  hl,hl")
            line("sbc  hl,de")
            line("jr  nc,p8rt_div16_fits")
            line("add  hl,de")
            line("dec  c")
            raw("p8rt_div16_fits:")
            line("inc  c")
            line("dec  a")
            line("jr  nz,p8rt_div16_bit")
            line("ex  de,hl")
            line("ld  h,b")
            line("ld  l,c")
            line("ret")
            nl()
        }
    }

    sub runtime_long() {
        if need_divs {
            raw("; HL = HL / DE, DE = the remainder (signed: towards zero, the remainder with the dividend's sign)")
            raw("p8rt_divs16:")
            line("ld  c,h")
            line("ld  a,h")
            line("xor  d")
            line("ld  b,a")
            line("push  bc")
            line("bit  7,h")
            line("call  nz,p8rt_neghl")
            line("bit  7,d")
            line("jr  z,p8rt_divs16_go")
            line("ex  de,hl")
            line("call  p8rt_neghl")
            line("ex  de,hl")
            raw("p8rt_divs16_go:")
            line("call  p8rt_div16")
            line("pop  bc")
            line("bit  7,b")
            line("call  nz,p8rt_neghl")
            line("bit  7,c")
            line("ret  z")
            line("ex  de,hl")
            line("call  p8rt_neghl")
            line("ex  de,hl")
            line("ret")
            raw("p8rt_neghl:")
            line("xor  a")
            line("sub  l")
            line("ld  l,a")
            line("sbc  a,a")
            line("sub  h")
            line("ld  h,a")
            line("ret")
            nl()
        }
        if need_mul32 {
            raw("; p8_lc = p8_la * p8_lb (the low 32 bits)")
            raw("p8rt_mul32:")
            line("ld  hl,0")
            line("ld  (p8_lc),hl")
            line("ld  (p8_lc+2),hl")
            line("ld  b,32")
            raw("p8rt_mul32_bit:")
            line("ld  hl,p8_la+3")
            line("srl  (hl)")
            repeat 3 {
                line("dec  hl")
                line("rr  (hl)")
            }
            line("jr  nc,p8rt_mul32_next")
            line("ld  hl,(p8_lc)")
            line("ld  de,(p8_lb)")
            line("add  hl,de")
            line("ld  (p8_lc),hl")
            line("ld  hl,(p8_lc+2)")
            line("ld  de,(p8_lb+2)")
            line("adc  hl,de")
            line("ld  (p8_lc+2),hl")
            raw("p8rt_mul32_next:")
            line("ld  hl,p8_lb")
            line("sla  (hl)")
            repeat 3 {
                line("inc  hl")
                line("rl  (hl)")
            }
            line("djnz  p8rt_mul32_bit")
            line("ret")
            nl()
        }
        if need_div32 {
            raw("; p8_la = p8_la / p8_lb, p8_lc = the remainder (unsigned)")
            raw("p8rt_div32:")
            line("ld  hl,0")
            line("ld  (p8_lc),hl")
            line("ld  (p8_lc+2),hl")
            line("ld  b,32")
            raw("p8rt_div32_bit:")
            line("ld  hl,p8_la")            ; (p8_lc follows p8_la: one shift of 64 bits)
            line("sla  (hl)")
            repeat 7 {
                line("inc  hl")
                line("rl  (hl)")
            }
            line("ld  hl,(p8_lc)")
            line("ld  de,(p8_lb)")
            line("or  a")
            line("sbc  hl,de")
            line("push  hl")
            line("ld  hl,(p8_lc+2)")
            line("ld  de,(p8_lb+2)")
            line("sbc  hl,de")
            line("pop  de")
            line("jr  c,p8rt_div32_next")
            line("ld  (p8_lc),de")
            line("ld  (p8_lc+2),hl")
            line("ld  hl,p8_la")
            line("inc  (hl)")
            raw("p8rt_div32_next:")
            line("djnz  p8rt_div32_bit")
            line("ret")
            nl()
        }
        if need_divs32 {
            raw("; the same, signed: towards zero, the remainder with the dividend's sign")
            raw("p8rt_divs32:")
            line("ld  a,(p8_la+3)")
            line("ld  c,a")
            line("ld  a,(p8_lb+3)")
            line("xor  c")
            line("ld  b,a")
            line("push  bc")
            line("bit  7,c")
            line("ld  hl,p8_la")
            line("call  nz,p8rt_neg32")
            line("ld  a,(p8_lb+3)")
            line("rla")
            line("ld  hl,p8_lb")
            line("call  c,p8rt_neg32")
            line("call  p8rt_div32")
            line("pop  bc")
            line("bit  7,b")
            line("ld  hl,p8_la")
            line("call  nz,p8rt_neg32")
            line("bit  7,c")
            line("ld  hl,p8_lc")
            line("call  nz,p8rt_neg32")
            line("ret")
            raw("; the long at HL = -it")
            raw("p8rt_neg32:")
            line("xor  a")
            line("sub  (hl)")
            line("ld  (hl),a")
            repeat 3 {
                line("inc  hl")
                line("ld  a,0")
                line("sbc  a,(hl)")
                line("ld  (hl),a")
            }
            line("ret")
            nl()
        }
    }

    sub raw(str text) {
        put(text)
        nl()
    }

    ; ---- variables ----

    sub element_size(^^ubyte typestr) -> ubyte {
        if text_has(typestr, "word") or text_has(typestr, "pointer") or typestr[0] == '^'
            return 2
        if text_has(typestr, "long")
            return 4
        if text_has(typestr, "float") or text_has(typestr, "quad")
            return 0
        return 1
    }

    sub text_has(^^ubyte text, str part) -> bool {
        long k = 0
        while text[k] != 0 {
            long m = 0
            while part[m] != 0 and text[k + m] == part[m]
                m++
            if part[m] == 0
                return true
            k++
        }
        return false
    }

    ; how many elements a type has ("ubyte[65]": 65; 1 for what is no array)
    sub element_count(^^ubyte typestr) -> long {
        long k = 0
        while typestr[k] != 0 and typestr[k] != '['
            k++
        if typestr[k] == 0
            return 1
        long n = 0
        k++
        while typestr[k] >= '0' and typestr[k] <= '9' {
            n = n * 10 + (typestr[k] - '0')
            k++
        }
        return n
    }

    sub variables() {
        raw("; ---- variables with values")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 {
                name(v.name)
                put("  equ  ")
                long address = number_of(v.init)
                if address >= $ff0000 {
                    ; (the library's virtual registers r0-r15: it gives them addresses that
                    ; no 16-bit machine has, to say that they are the back end's to place)
                    put("p8_vregs+")
                    putn(address - $ff0000)
                    need_vregs = true
                }
                else
                    put_number_text(v.init)
                nl()
            }
            else if v.kind == ir.V_VAR and v.init != 0 and struct_of(v.typestr) != 0 {
                ; an array of structs: its instances' values, one after the other
                name(v.name)
                put(":")
                nl()
                struct_array_values(v, struct_of(v.typestr).size)
            }
            else if v.kind == ir.V_VAR and v.init != 0 {
                ubyte esize = element_size(v.typestr)
                if esize == 0
                    error("a variable of this type cannot be used on the Z80 yet", v.name)
                else
                    values(v, esize)
            }
            else if v.kind == ir.V_INSTANCE and v.init != 0 {
                name(v.name)
                put(":")
                nl()
                instance_values(v, v.init)
            }
            v = v.next
        }
        raw("; ---- variables without values, and the registers of the code")
        raw("p8_bss_start:")
        v = prog.vars
        while v != 0 {
            if (v.kind == ir.V_VAR and v.init == 0) or v.kind == ir.V_SLAB or (v.kind == ir.V_INSTANCE and v.init == 0) {
                long bytes = v.size
                if v.kind == ir.V_VAR {
                    long vsize = element_size(v.typestr)
                    if struct_of(v.typestr) != 0
                        vsize = struct_of(v.typestr).size
                    if vsize == 0 {
                        error("a variable of this type cannot be used on the Z80 yet", v.name)
                        vsize = 1
                    }
                    bytes = element_count(v.typestr) * vsize
                }
                if v.align > 1 {
                    put("    align  ")
                    putn(v.align)
                    nl()
                }
                name(v.name)
                put(":  defs  ")
                putn(bytes)
                nl()
            }
            v = v.next
        }
        buf.add_bytes(o, cells.data, cells.len)
        if need_vregs
            raw("p8_vregs:  defs  32")
        ubyte sn
        for sn in 0 to 99 {
            if slot_used[sn] {
                put("p8_slot_")
                putn(sn)
                raw(":  defs  4")
            }
        }
        if need_long {
            raw("p8_la:  defs  4")
            raw("p8_lc:  defs  4")
            raw("p8_lb:  defs  4")
        }
        raw("p8_bss_end:")
    }

    ; the struct that a type is an array of ("main.Two[4]"), or 0
    sub struct_of(^^ubyte t) -> ^^ir.Var {
        long n = 0
        while t[n] != 0 and t[n] != '['
            n++
        if t[n] == 0
            return 0
        ^^ir.Var sv = prog.vars
        while sv != 0 {
            if sv.kind == ir.V_STRUCT and buf.cstr_len(sv.name) == n and buf.bytes_equal(sv.name, t, n)
                return sv
            sv = sv.next
        }
        return 0
    }

    ; "@instance,@instance": each instance's values (zeros for one without)
    sub struct_array_values(^^ir.Var v, long struct_size) {
        ^^ubyte t = v.init
        long p = 0
        while t[p] != 0 {
            long stop = p
            while t[stop] != 0 and t[stop] != ','
                stop++
            ^^ir.Var inst = 0
            if t[p] == '@' {
                ^^ubyte wanted = strtab.intern(t + p + 1, (stop - p - 1) as uword)
                inst = prog.vars
                while inst != 0 {
                    if inst.kind == ir.V_INSTANCE and strings.compare(inst.name, wanted) == 0
                        break
                    inst = inst.next
                }
            }
            if inst != 0 and inst.init != 0
                instance_values(v, inst.init)
            else {
                put("    defs  ")
                putn(struct_size)
                nl()
            }
            p = stop
            if t[p] == ','
                p++
        }
    }

    ; the values of a struct instance: "type:value,type:value,..."
    sub instance_values(^^ir.Var v, ^^ubyte init) {
        long p = 0
        while init[p] != 0 {
            long colon = p
            while init[colon] != 0 and init[colon] != ':'
                colon++
            if init[colon] == 0
                break
            ; (the field's type: what stands before the colon)
            if init[p] == '^' or (init[p] == 'u' and init[p + 1] == 'w') or init[p] == 'w' or init[p] == 'p'
                put("    defw  ")
            else if init[p] == 'l'
                put("    defq  ")
            else if init[p] == 'f' or init[p] == 'q' or (init[p] == 'u' and init[p + 1] == 'q') {
                error("a struct field of this type cannot be used on the Z80 yet", v.name)
                return
            }
            else
                put("    defb  ")
            p = colon + 1
            if init[p] == '@' or init[p] == '&' {
                p++
                buf.add_byte(o, '_')
                while init[p] != 0 and init[p] != ',' {
                    if init[p] == '.'
                        buf.add_byte(o, '_')
                    else
                        buf.add_byte(o, init[p])
                    p++
                }
            }
            else {
                while init[p] != 0 and init[p] != ',' {
                    buf.add_byte(o, init[p])
                    p++
                }
            }
            nl()
            if init[p] == ','
                p++
        }
    }

    ; the value of a number as the IR writes it ($hex or decimal)
    sub number_of(^^ubyte text) -> long {
        long value = 0
        long k = 0
        if text[0] == '$' {
            k = 1
            repeat {
                ubyte c = text[k] | 32
                if text[k] >= '0' and text[k] <= '9'
                    value = value * 16 + (text[k] - '0')
                else if c >= 'a' and c <= 'f'
                    value = value * 16 + (c - 'a' + 10)
                else
                    break
                k++
            }
            return value
        }
        while text[k] >= '0' and text[k] <= '9' {
            value = value * 10 + (text[k] - '0')
            k++
        }
        return value
    }

    ; a number as the IR writes it ($hex, decimal, with a minus) for the assembler
    sub put_number_text(^^ubyte text) {
        long k = 0
        while text[k] != 0 and text[k] != ',' {
            buf.add_byte(o, text[k])
            k++
        }
    }

    ; the values of a variable: numbers, and "@name" for the address of something
    sub values(^^ir.Var v, ubyte esize) {
        if v.align > 1 {
            put("    align  ")
            putn(v.align)
            nl()
        }
        name(v.name)
        put(":")
        nl()
        long p = 0
        ubyte column = 0
        while v.init[p] != 0 {
            if column == 0 {
                when esize {
                    1 -> put("    defb  ")
                    2 -> put("    defw  ")
                    else -> put("    defq  ")
                }
            }
            else
                put(",")
            if v.init[p] == '@' or v.init[p] == '&' {
                p++
                buf.add_byte(o, '_')
                while v.init[p] != 0 and v.init[p] != ',' {
                    if v.init[p] == '.'
                        buf.add_byte(o, '_')
                    else
                        buf.add_byte(o, v.init[p])
                    p++
                }
            }
            else {
                while v.init[p] != 0 and v.init[p] != ',' {
                    buf.add_byte(o, v.init[p])
                    p++
                }
            }
            if v.init[p] == ','
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
}
