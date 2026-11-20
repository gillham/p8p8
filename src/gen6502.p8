; The 6502 code generator: writes a p8p8 IR program (ir.p8) as 64tass assembly
; for the 6502 and 65C02.  See docs/DESIGN.md.
;
; The file layout is the one the library's inline assembly expects, which is
; that of upstream's codeGenNew6502/AsmGen.kt: the header with the zero page
; scratch cells, the BASIC launcher and startup sequence, the constants and
; memory-mapped variables, a .proc per block and subroutine, then the data and
; the BSS sections.
;
; Stage A/B of the plan: every virtual register has a memory cell in
; p8_regfile, and each IR instruction is translated by itself (the reference's
; behaviour).  The value tracking that makes the code good comes on top of
; this, through the same emit routines.
;
; All instructions go through ins() and the few routines after it that know
; the CPU: the 65C02 has stz, bra and friends, the 6502 gets longer forms.

%import crumb
%import ir
%import strtab
%import mem
%import buf
%import out
%import strings
%import peep6502
%import target
%import io_platform
%import irparse

gen6502 {
    %option ignore_unused

    ^^ir.Program prog = 0
    ^^buf.Buf o = 0                 ; the assembly text
    ^^buf.Buf nb = 0                ; scratch
    ^^buf.Buf hb = 0                ; scratch of ins_half and ins_indexed
    ^^buf.Buf pb = 0                ; scratch for a composed name
    long errors = 0
    ; A 65C02: stz, bra, inc a, (zp), tsb.  Only what the 65816 has too (it runs the
    ; Commander X16 as well): no bbr, bbs, rmb or smb.
    bool c02 = false
    bool c816 = false               ; a 65816: everything a 65C02 has that p8p8 uses, and more
    bool c45 = false                ; a 45GS02 (MEGA65): the 65C02's too, but for two (c02z), and 32-bit instructions
    bool c02z = false               ; "stz" stores a zero and "(zp)" is there: a 65C02 or 65816, not the 45GS02,
                                    ; where stz stores the Z register and (zp) is (zp),z
    ^^ubyte cpu_option = 0          ; -cpu: the CPU to write code for, in place of the target's

    ; the options of the program (the <OPTIONS> lines of the IR)
    long load_address = $0801
    ^^ubyte break_instruction = 0       ; -breakinstr brk|stp
    long memtop = 0
    bool launcher_basic = true
    bool no_sysinit = false
    bool vars_golden = false        ; -varsgolden: uninitialized variables in the target's golden ram
    long vars_high_bank = -1        ; -varshigh N: in its high ram, bank N
    long vars_address = -1          ; -varsaddress: at this address
    ^^ubyte output_type = "PRG"     ; PRG, RAW, XEX or LIBRARY: what the assembler is asked to write
    bool zp_safe = false            ; zeropage basicsafe or dontuse: no reset vector on the stack

    ; the cell of each virtual register: its offset in p8_regfile
    ^^uword cell_of = 0
    long cell_cap = 0
    long regfile_size = 0
    long float_cells = 0            ; the size of the float cells, which come first
    long regfile_used = 0           ; what p8_regfile needs in the end

    sub error(str message, ^^ubyte detail) {
        out.err()
        out.puts("6502 code generator: ")
        out.puts(message)
        if detail != 0 {
            out.puts(": ")
            out.puts(detail)
        }
        out.nl()
        errors++
    }

    ; ---- text output ----
    ;
    ; Inside a subroutine the lines go to peep6502, which writes them when the
    ; subroutine is complete.

    sub w() -> ^^buf.Buf {
        if peep6502.active
            return peep6502.text()
        return o
    }

    sub raw(str text) {
        buf.add_str(w(), text)
        buf.add_byte(w(), '\n')
    }

    sub put(^^ubyte text) {
        buf.add_str(w(), text)
    }

    sub putn(long value) {
        buf.add_long(w(), value)
    }

    sub nl() {
        buf.add_byte(w(), '\n')
    }

    ; "$1f2e"
    sub puthex(long value) {
        buf.add_byte(w(), '$')
        ubyte shift = 28
        bool started = false
        repeat 8 {
            ubyte digit = ((value >> shift) & 15) as ubyte
            if digit != 0 or started or shift == 0 {
                buf.add_byte(w(), buf.hex_digit(digit))
                started = true
            }
            if shift >= 4
                shift -= 4
        }
    }

    ; one instruction: "    lda  operand"
    sub ins(str mnemonic, ^^ubyte operand) {
        if peep6502.active {
            peep6502.ins(mnemonic, operand)
            return
        }
        buf.add_str(w(), "    ")
        buf.add_str(w(), mnemonic)
        if operand != 0 and operand[0] != 0 {
            buf.add_str(w(), "  ")
            buf.add_str(w(), operand)
        }
        buf.add_byte(w(), '\n')
    }

    ; an instruction whose operand is a symbol plus an offset: "    sta  name+1"
    sub ins_at(str mnemonic, ^^ubyte symbol, long offset) {
        if peep6502.active {
            peep6502.ins_at(mnemonic, symbol, offset)
            return
        }
        buf.add_str(w(), "    ")
        buf.add_str(w(), mnemonic)
        buf.add_str(w(), "  ")
        buf.add_str(w(), symbol)
        if offset != 0 {
            buf.add_byte(w(), '+')
            buf.add_long(w(), offset)
        }
        buf.add_byte(w(), '\n')
    }

    ; an instruction with an immediate number: "    lda  #65"
    sub ins_imm(str mnemonic, long value) {
        if peep6502.active {
            peep6502.ins_imm(mnemonic, value)
            return
        }
        buf.add_str(w(), "    ")
        buf.add_str(w(), mnemonic)
        buf.add_str(w(), "  #")
        buf.add_long(w(), value & 255)
        buf.add_byte(w(), '\n')
    }

    ; an instruction with the low or high byte of a symbol's address: "    lda  #<name"
    sub ins_half(str mnemonic, ubyte which, ^^ubyte symbol, long offset) {
        if hb == 0
            hb = buf.new(128)
        buf.clear(hb)
        buf.add_byte(hb, '#')
        buf.add_byte(hb, which)
        if offset != 0
            buf.add_byte(hb, '(')
        buf.add_str(hb, symbol)
        if offset != 0 {
            buf.add_byte(hb, '+')
            buf.add_long(hb, offset)
            buf.add_byte(hb, ')')
        }
        buf.add_byte(hb, 0)
        ins(mnemonic, hb.data)
    }

    ; an instruction on symbol+offset indexed by X or Y: "    lda  name+1,y"
    sub ins_indexed(str mnemonic, ^^ubyte symbol, long offset, ubyte index) {
        if hb == 0
            hb = buf.new(128)
        buf.clear(hb)
        buf.add_str(hb, symbol)
        if offset != 0 {
            buf.add_byte(hb, '+')
            buf.add_long(hb, offset)
        }
        buf.add_byte(hb, ',')
        buf.add_byte(hb, index)
        buf.add_byte(hb, 0)
        ins(mnemonic, hb.data)
    }

    ; an anonymous label of the assembler: "+" (for branches forward) or "-" (backward)
    sub anon_label(str which) {
        if peep6502.active {
            peep6502.anon_label(which)
            return
        }
        raw(which)
    }

    sub label(^^ubyte name) {
        if peep6502.active {
            peep6502.label(name)
            return
        }
        buf.add_str(w(), name)
        buf.add_str(w(), ":\n")
    }

    ; ---- the CPU ----

    ; stores zero at a memory location (A is lost on the 6502)
    sub store_zero(^^ubyte symbol, long offset) {
        if c02z
            ins_at("stz", symbol, offset)
        else {
            ins("lda", "#0")
            ins_at("sta", symbol, offset)
        }
    }

    sub jump_always(^^ubyte target) {
        ins("jmp", target)
    }

    ; ---- registers ----

    ; the size in bytes of an IR type
    sub type_size(ubyte t) -> ubyte {
        when t {
            ir.T_BYTE -> return 1
            ir.T_WORD, ir.T_POINTER -> return 2
            ir.T_LONG -> return 4
            ir.T_FLOAT -> return 5
        }
        return 2
    }

    ^^ubyte reg_named = 0           ; per register: an instruction of the program names it
    ^^ubyte reg_fixed = 0           ; per register: its cell is used by address and keeps its place

    ; gives every register that the program uses a cell
    sub assign_cells() {
        cell_cap = (ir.regcount as long) + 2
        cell_of = mem.alloc(cell_cap * 2)
        reg_fixed = mem.alloc(cell_cap)
        sys.memset(reg_fixed, cell_cap as uword, 0)
        reg_named = mem.alloc(cell_cap)
        sys.memset(reg_named, cell_cap as uword, 0)
        if c45 {
            ; a long is loaded and stored whole (ldq, stq): its cell is four bytes in a row
            ; with a place of its own
            long qr = 1
            while qr <= ir.regcount {
                if ir.regtypes[qr] == ir.T_LONG
                    reg_fixed[qr] = 1
                qr++
            }
        }
        fixed_longs_in(prog.initglobals)
        ^^ir.Block fb = prog.blocks
        while fb != 0 {
            fixed_longs_in(fb.chunks)
            ^^ir.Sub fs = fb.subs
            while fs != 0 {
                fixed_longs_in(fs.chunks)
                fs = fs.next
            }
            fb = fb.next
        }
        regfile_size = 0
        ; the floats first: their cells are used by address and keep their place, the
        ; others are placed again when it is known which of them the code still names
        long r = 1
        while r <= ir.regcount {
            if ir.regtypes[r] == ir.T_FLOAT {
                ; (a float register of code that was removed needs none)
                cell_of[r] = 0
                if reg_named[r] != 0 {
                    cell_of[r] = regfile_size as uword
                    regfile_size += 5
                }
            }
            else if reg_fixed[r] != 0 {
                ; (a long whose address goes to a float routine: the same)
                cell_of[r] = 0
                if reg_named[r] != 0 or not c45 {
                    cell_of[r] = regfile_size as uword
                    regfile_size += 4
                }
            }
            r++
        }
        if c45 {
            ; the cells of the division routine (p8_qdivs)
            qdiv_cells = regfile_size
            regfile_size += 18
        }
        if types.far_bits != 0 {
            ; where a value from far memory is while an instruction works on it
            far_cells = regfile_size
            regfile_size += 5
        }
        float_cells = regfile_size
        r = 1
        while r <= ir.regcount {
            if ir.regtypes[r] != ir.T_FLOAT and reg_fixed[r] == 0 {
                cell_of[r] = regfile_size as uword
                regfile_size += type_size(ir.regtypes[r])
            }
            r++
        }
        regfile_used = regfile_size
    }

    ; "p8_regfile+N" into nb; gives nb's text (valid until nb is used again)
    sub cell(uword r, ubyte byteoffset) -> ^^ubyte {
        buf.clear(nb)
        buf.add_str(nb, "p8_regfile+")
        long offset = byteoffset
        if r < cell_cap
            offset += cell_of[r]
        buf.add_long(nb, offset)
        buf.add_byte(nb, 0)
        return nb.data
    }

    sub lda_reg(uword r, ubyte byteoffset) {
        ins("lda", cell(r, byteoffset))
    }

    sub sta_reg(uword r, ubyte byteoffset) {
        ins("sta", cell(r, byteoffset))
    }

    ; ---- the program options ----

    ; the value of "key=" in the options text, or 0
    sub option(str key) -> ^^ubyte {
        ^^ubyte t = prog.options
        if t == 0
            return 0
        long keylen = buf.cstr_len(key)
        long i = 0
        while t[i] != 0 {
            if buf.bytes_equal(t + i, key, keylen) and t[i + keylen] == '=' {
                long start = i + keylen + 1
                long stop = start
                while t[stop] != 0 and t[stop] != '\n'
                    stop++
                return strtab.intern(t + start, (stop - start) as uword)
            }
            while t[i] != 0 and t[i] != '\n'
                i++
            if t[i] == '\n'
                i++
        }
        return 0
    }

    ; a number as the IR writes it: decimal, $hex or %binary
    sub number(^^ubyte s) -> long {
        long v = 0
        long i = 0
        bool negative = false
        if s[0] == '-' {
            negative = true
            i = 1
        }
        if s[i] == '$' {
            i++
            while s[i] != 0 {
                ubyte c = s[i]
                if c >= '0' and c <= '9'
                    v = v * 16 + (c - '0')
                else if (c | 32) >= 'a' and (c | 32) <= 'f'
                    v = v * 16 + ((c | 32) - 'a' + 10)
                else
                    break
                i++
            }
        }
        else if s[i] == '%' {
            i++
            while s[i] == '0' or s[i] == '1' {
                v = v * 2 + (s[i] - '0')
                i++
            }
        }
        else {
            while s[i] >= '0' and s[i] <= '9' {
                v = v * 10 + (s[i] - '0')
                i++
            }
        }
        if negative
            return -v
        return v
    }

    sub read_options() {
        load_address = $0801
        memtop = 0
        launcher_basic = true
        no_sysinit = false
        zp_safe = false
        ^^ubyte v = option("loadAddress")
        if v != 0
            load_address = number(v)
        v = option("memtop")
        if v != 0
            memtop = number(v)
        v = option("launcher")
        if v != 0 and strings.compare(v, "BASIC") != 0
            launcher_basic = false
        v = option("noSysInit")
        if v != 0 and strings.compare(v, "true") == 0
            no_sysinit = true
        v = option("zeropage")
        if v != 0 and (strings.compare(v, "BASICSAFE") == 0 or strings.compare(v, "DONTUSE") == 0)
            zp_safe = true
        v = option("romable")
        romable = v != 0 and strings.compare(v, "true") == 0
        output_type = "PRG"
        v = option("output")
        if v != 0
            output_type = v
        if strings.compare(output_type, "PRG") != 0 and strings.compare(output_type, "RAW") != 0
                and strings.compare(output_type, "XEX") != 0 and strings.compare(output_type, "LIBRARY") != 0
            error("output type not supported", v)
        ; (upstream's rule: the BASIC launcher is a line of a .prg; a target with its own
        ; launcher code has that in its place)
        if launcher_basic and strings.compare(output_type, "PRG") != 0 and strings.compare(output_type, "LIBRARY") != 0
                and target.text("custom_launcher_code") == 0
            error("BASIC launcher requires output type PRG (the program needs %launcher none)", 0)
    }

    ; ---- the zero page ----
    ;
    ; Scalar variables go to the free part of the zero page: first the ones that ask
    ; for it (@zp, @requirezp), then the others, the most used first.  What is free
    ; depends on the machine and on %zeropage: the zp_... lists of the target's
    ; configuration (target.p8).  A variable with an initial value that lands there
    ; gets it from code in run_global_inits.

    ^^bool zp_free = 0              ; 256 of them
    long zp_count = 0               ; variables placed

    ; the free locations of this machine for this %zeropage
    sub zp_free_map() {
        uword k
        if zp_free == 0
            zp_free = mem.alloc(256)
        for k in 0 to 255
            zp_free[k] = false
        if not target.loaded
            return              ; a machine nobody described: the zero page is left alone
        ^^ubyte mode = option("zeropage")
        if mode == 0
            mode = "KERNALSAFE"
        if strings.compare(mode, "DONTUSE") == 0
            return
        if strings.compare(mode, "FULL") == 0
            void target.mark_ranges("zp_fullsafe", zp_free, true)
        else if strings.compare(mode, "KERNALSAFE") == 0
            void target.mark_ranges("zp_kernalsafe", zp_free, true)
        else if strings.compare(mode, "FLOATSAFE") == 0 {
            if not target.mark_ranges("zp_floatsafe", zp_free, true)
                void target.mark_ranges("zp_basicsafe", zp_free, true)
        }
        else
            void target.mark_ranges("zp_basicsafe", zp_free, true)
        ; the virtual registers, when the machine has them in the zero page
        long vregs = target.number("virtual_registers", -1)
        if irgen.vregs_moved_to >= 0
            vregs = irgen.vregs_moved_to        ; (moved into the zero page for this program)
        if vregs >= 0 and vregs < 256 {
            for k in 0 to 31 {
                if vregs + k < 256
                    zp_free[vregs + k] = false
            }
        }
        ; the scratch cells are the library's
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 and starts_with(v.name, "P8ZP_SCRATCH") {
                long at = number(v.init)
                if at >= 0 and at < 255 {
                    zp_free[at] = false
                    ; (the byte cells are one byte, the others a pair)
                    if not starts_with(v.name, "P8ZP_SCRATCH_B1") and not starts_with(v.name, "P8ZP_SCRATCH_REG")
                        zp_free[at + 1] = false
                }
            }
            v = v.next
        }
        ; %zpreserved and %zpallowed
        zp_option_ranges("zpReserved", false)
        ^^ubyte allowed = option("zpAllowed")
        if allowed != 0 {
            long first
            long last
            first, last = two_numbers(allowed)
            for k in 0 to 255 {
                if k < first or k > last
                    zp_free[k] = false
            }
        }
    }

    ; "first,last"
    sub two_numbers(^^ubyte t) -> long, long {
        long comma = 0
        while t[comma] != 0 and t[comma] != ','
            comma++
        if t[comma] == 0
            return 0, 255
        buf.clear(nb)
        buf.add_bytes(nb, t, comma)
        buf.add_byte(nb, 0)
        long first = number(nb.data)
        return first, number(t + comma + 1)
    }

    ; every "key=first,last" line of the options
    sub zp_option_ranges(str key, bool free) {
        ^^ubyte t = prog.options
        if t == 0
            return
        long keylen = buf.cstr_len(key)
        long i = 0
        while t[i] != 0 {
            if buf.bytes_equal(t + i, key, keylen) and t[i + keylen] == '=' {
                long start = i + keylen + 1
                long stop = start
                while t[stop] != 0 and t[stop] != '\n'
                    stop++
                long first
                long last
                first, last = two_numbers(strtab.intern(t + start, (stop - start) as uword))
                long k
                for k in first to last {
                    if k >= 0 and k <= 255
                        zp_free[k] = free
                }
            }
            while t[i] != 0 and t[i] != '\n'
                i++
            if t[i] == '\n'
                i++
        }
    }

    sub zp_left() -> long {
        long n = 0
        uword k
        for k in 2 to 255 {
            if zp_free[k]
                n++
        }
        return n
    }

    ; a place for size bytes, or 0
    sub zp_take(long size) -> long {
        long at = 2
        while at + size <= 256 {
            bool fits = true
            long k
            for k in 0 to size - 1 {
                if not zp_free[at + k] {
                    fits = false
                    break
                }
            }
            if fits {
                for k in 0 to size - 1
                    zp_free[at + k] = false
                return at
            }
            at++
        }
        return 0
    }

    ; can this variable live in the zero page, and how large is it?  (0: no)
    sub zp_candidate(^^ir.Var v, bool asked) -> long {
        if v.kind != ir.V_VAR or v.zpaddr != 0 or v.align > 1
            return 0
        if v.zp != 0 and strings.compare(v.zp, "NOT_IN_ZEROPAGE") == 0
            return 0
        if v.split and not asked
            return 0
        if asked {
            ; what the program asks for (@zp, @requirezp): anything whose first value the
            ; code at the start can give it.  An array without values is cleared there.
            if starts_with(v.typestr, "str")
                return 0
            if array_length(v.typestr) != 0 {
                if v.init != 0 or var_size(v) > 255
                    return 0
                return var_size(v)
            }
            return element_size(v.typestr)
        }
        if array_length(v.typestr) != 0
            return 0
        if v.init != 0 and (v.init[0] == '@' or starts_with(v.typestr, "float"))
            return 0            ; (an address or a float as the initial value: not from code yet)
        long size = element_size(v.typestr)
        if size > 2 and not asked
            return 0
        if size < 1 or size > 5
            return 0
        return size
    }

    sub zp_wanted(^^ir.Var v) -> bool {
        return v.zp != 0 and (strings.compare(v.zp, "REQUIRE_ZEROPAGE") == 0 or strings.compare(v.zp, "PREFER_ZEROPAGE") == 0)
    }

    ; How much each variable would gain from the zero page: a byte for every time it is
    ; named, and for a pointer the copy to the scratch pointer that it saves when it is
    ; loaded to be followed (in the zero page it is followed where it is).
    ^^pointer zp_reg_sym = 0        ; per register: the variable it was loaded from, until it is followed
    ^^long zp_reg_seq = 0           ; and in which chunk
    long zp_chunk_seq = 0
    long zp_follow_gain = 3

    sub zp_count_chunk(^^ir.Chunk c) {
        if zp_reg_sym == 0 {
            zp_reg_sym = mem.alloc((ir.regcount + 2) * sizeof(pointer))
            zp_reg_seq = mem.alloc((ir.regcount + 2) * 4)
            long z = 0
            while z < ir.regcount + 2 {
                zp_reg_seq[z] = 0
                z++
            }
        }
        while c != 0 {
            if c.kind != ir.C_ASM {
                zp_chunk_seq++
                ^^ir.Instr i = c.first
                while i != 0 {
                    if i.sym != 0 {
                        ^^strtab.Sym s = strtab.intern_sym(i.sym, buf.cstr_len(i.sym) as uword)
                        s.extra++
                        if i.op == ir.OP_LOADM and i.r1 <= ir.regcount and type_size(i.type) == 2 {
                            zp_reg_sym[i.r1] = s
                            zp_reg_seq[i.r1] = zp_chunk_seq
                        }
                    }
                    else if i.op == ir.OP_LOADR and i.r1 <= ir.regcount and i.r2 <= ir.regcount and zp_reg_seq[i.r2] == zp_chunk_seq {
                        ; (a copy that an index is added to)
                        zp_reg_sym[i.r1] = zp_reg_sym[i.r2]
                        zp_reg_seq[i.r1] = zp_chunk_seq
                    }
                    else if (i.mode == ir.M_RP or i.mode == ir.M_P) and i.r2 <= ir.regcount and zp_reg_seq[i.r2] == zp_chunk_seq {
                        ^^strtab.Sym ps = zp_reg_sym[i.r2]
                        ps.extra += zp_follow_gain
                        zp_reg_seq[i.r2] = 0        ; (one copy serves the next times)
                    }
                    i = i.next
                }
            }
            c = c.next
        }
    }

    ubyte[32] pool_at               ; the zero page bytes of the shared temporaries
    ubyte pool_count = 0

    ; Which subroutines may run while another is in the middle of something: those
    ; whose address is taken (an interrupt handler is set that way) or that assembly
    ; names, and all they call.  They keep off the shared temporaries.
    sub interrupt_subroutines() {
        ^^ir.Block bl = prog.blocks
        ^^ir.Sub sb
        ^^strtab.Sym s
        ; the names in assembly: every identifier, and its part after the last dot
        while bl != 0 {
            ^^ir.Chunk bc = bl.chunks
            while bc != 0 {
                if bc.kind == ir.C_ASM
                    names_in_assembly(bc.text, bc.textlen)
                bc = bc.next
            }
            sb = bl.subs
            while sb != 0 {
                sb.no_pool = false
                if sb.asmtext != 0
                    names_in_assembly(sb.asmtext, sb.asmlen)
                ^^ir.Chunk sc = sb.chunks
                while sc != 0 {
                    if sc.kind == ir.C_ASM
                        names_in_assembly(sc.text, sc.textlen)
                    else {
                        ; an address taken: the name as the operand of something that is not a call or jump
                        ^^ir.Instr i = sc.first
                        while i != 0 {
                            if i.sym != 0 and i.op != ir.OP_CALL and i.op != ir.OP_CALLFAR and i.op != ir.OP_CALLFARVB and i.op != ir.OP_JUMP
                                    and i.mode != ir.M_M and i.mode != ir.M_RM and i.mode != ir.M_IM {
                                s = strtab.intern_sym(i.sym, buf.cstr_len(i.sym) as uword)
                                s.mark |= peep6502.K_TAKEN
                            }
                            i = i.next
                        }
                    }
                    sc = sc.next
                }
                sb = sb.next
            }
            bl = bl.next
        }
        ; an address in the initial value of a variable ("@name") is taken as well
        ^^ir.Var iv = prog.vars
        while iv != 0 {
            if iv.init != 0 {
                long il = buf.cstr_len(iv.init)
                long ik = 0
                while ik < il {
                    if iv.init[ik] == '@' {
                        names_in_assembly(iv.init, il)
                        break
                    }
                    ik++
                }
            }
            iv = iv.next
        }
        ; the subroutines that are named that way
        bl = prog.blocks
        while bl != 0 {
            sb = bl.subs
            while sb != 0 {
                if not sb.is_asm {
                    s = strtab.intern_sym(sb.name, buf.cstr_len(sb.name) as uword)
                    ^^ubyte tail = unscoped(sb.name)
                    ^^strtab.Sym ts = strtab.intern_sym(tail, buf.cstr_len(tail) as uword)
                    if s.mark & peep6502.K_TAKEN != 0 or ts.mark & peep6502.K_TAKEN != 0
                        sb.no_pool = true
                }
                sb = sb.next
            }
            bl = bl.next
        }
        ; and what they call, and what that calls
        bool more = true
        while more {
            more = false
            bl = prog.blocks
            while bl != 0 {
                sb = bl.subs
                while sb != 0 {
                    if sb.no_pool and not sb.is_asm {
                        ^^ir.Chunk cc = sb.chunks
                        while cc != 0 {
                            if cc.kind != ir.C_ASM {
                                ^^ir.Instr ci = cc.first
                                while ci != 0 {
                                    if ci.sym != 0 and (ci.op == ir.OP_CALL or ci.op == ir.OP_JUMP) {
                                        ^^ir.Sub callee = find_sub(ci.sym)
                                        if callee != 0 and not callee.no_pool {
                                            callee.no_pool = true
                                            more = true
                                        }
                                    }
                                    ci = ci.next
                                }
                            }
                            cc = cc.next
                        }
                    }
                    sb = sb.next
                }
                bl = bl.next
            }
        }
    }

    ; Which variables does only their own subroutine name, and which subroutines can be
    ; called again while they run?  (For peep6502: what a call leaves as it was.)
    ; A subroutine with assembly in it, one that calls through a pointer or calls
    ; something that is not the program's, may call any subroutine that assembly names.
    sub own_variables() {
        ^^ir.Block bl = prog.blocks
        ^^ir.Sub sb
        ^^ir.Chunk c
        ^^ir.Instr i
        ^^strtab.Sym s
        long n = 0
        long edges = 0
        while bl != 0 {
            c = bl.chunks
            while c != 0 {
                if c.kind != ir.C_ASM {
                    i = c.first
                    while i != 0 {
                        if i.sym != 0 {
                            s = strtab.intern_sym(i.sym, buf.cstr_len(i.sym) as uword)
                            s.mark |= peep6502.K_FOREIGN
                        }
                        i = i.next
                    }
                }
                c = c.next
            }
            sb = bl.subs
            while sb != 0 {
                n++
                c = sb.chunks
                while c != 0 {
                    if c.kind != ir.C_ASM {
                        i = c.first
                        while i != 0 {
                            edges++
                            i = i.next
                        }
                    }
                    c = c.next
                }
                sb = sb.next
            }
            bl = bl.next
        }
        if n == 0
            return
        ^^pointer subv = mem.alloc(n * sizeof(pointer))
        ^^ubyte wild = mem.alloc(n)
        ^^ubyte named = mem.alloc(n)
        ^^long seen = mem.alloc(n * 4)
        ^^long estart = mem.alloc((n + 1) * 4)
        ^^long eto = mem.alloc((edges + 1) * 4)
        ^^long todo = mem.alloc((n + 1) * 4)
        long k = 0
        bl = prog.blocks
        while bl != 0 {
            sb = bl.subs
            while sb != 0 {
                subv[k] = sb
                k++
                sb = sb.next
            }
            bl = bl.next
        }
        long ecount = 0
        long j
        for k in 0 to n - 1 {
            sb = subv[k]
            estart[k] = ecount
            seen[k] = -1
            wild[k] = 0
            named[k] = 0
            s = strtab.intern_sym(sb.name, buf.cstr_len(sb.name) as uword)
            ^^ubyte tail = unscoped(sb.name)
            ^^strtab.Sym ts = strtab.intern_sym(tail, buf.cstr_len(tail) as uword)
            if s.mark & peep6502.K_TAKEN != 0 or ts.mark & peep6502.K_TAKEN != 0
                named[k] = 1
            if sb.is_asm or sb.asmtext != 0
                wild[k] = 1
            long namelen = buf.cstr_len(sb.name)
            c = sb.chunks
            while c != 0 {
                if c.kind == ir.C_ASM
                    wild[k] = 1
                else {
                    i = c.first
                    while i != 0 {
                        when i.op {
                            ir.OP_CALL, ir.OP_CALLFAR, ir.OP_CALLFARVB, ir.OP_JUMP -> {
                                ^^ir.Sub callee = 0
                                if i.sym != 0
                                    callee = find_sub(i.sym)
                                if callee != 0 {
                                    for j in 0 to n - 1 {
                                        if subv[j] == callee {
                                            eto[ecount] = j
                                            ecount++
                                            break
                                        }
                                    }
                                }
                                else if i.op != ir.OP_JUMP or i.sym == 0
                                    wild[k] = 1         ; not a subroutine of the program, or not a name
                            }
                            ir.OP_CALLI, ir.OP_SYSCALL -> wild[k] = 1
                            else -> {
                                if i.sym != 0 {
                                    ; a variable: this subroutine's own?
                                    ^^ubyte t = i.sym
                                    bool mine = true
                                    j = 0
                                    while j < namelen {
                                        if t[j] != sb.name[j] {
                                            mine = false
                                            break
                                        }
                                        j++
                                    }
                                    if mine and t[namelen] != '.'
                                        mine = false
                                    if not mine {
                                        s = strtab.intern_sym(t, buf.cstr_len(t) as uword)
                                        s.mark |= peep6502.K_FOREIGN
                                    }
                                }
                            }
                        }
                        i = i.next
                    }
                }
                c = c.next
            }
        }
        estart[n] = ecount
        ; can it be reached from itself?
        for k in 0 to n - 1 {
            sb = subv[k]
            sb.reenter = false
            long top = 0
            bool named_done = false
            todo[0] = k
            top = 1
            while top > 0 and not sb.reenter {
                top--
                long u = todo[top]
                if wild[u] != 0 and not named_done {
                    named_done = true
                    for j in 0 to n - 1 {
                        if named[j] != 0 {
                            if j == k
                                sb.reenter = true
                            else if seen[j] != k {
                                seen[j] = k
                                todo[top] = j
                                top++
                            }
                        }
                    }
                }
                j = estart[u]
                while j < estart[u + 1] {
                    long dst = eto[j]
                    if dst == k
                        sb.reenter = true
                    else if seen[dst] != k {
                        seen[dst] = k
                        todo[top] = dst
                        top++
                    }
                    j++
                }
            }
        }
    }

    sub name_char(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.'
    }

    sub names_in_assembly(^^ubyte text, long length) {
        if text == 0
            return
        long i = 0
        while i < length {
            if not name_char(text[i]) or (text[i] >= '0' and text[i] <= '9') or text[i] == '.' {
                i++
                ; (a number is skipped whole)
                while i < length and text[i - 1] >= '0' and text[i - 1] <= '9' and name_char(text[i])
                    i++
                continue
            }
            long start = i
            long lastdot = -1
            while i < length and name_char(text[i]) {
                if text[i] == '.'
                    lastdot = i
                i++
            }
            ^^strtab.Sym s = strtab.intern_sym(text + start, (i - start) as uword)
            s.mark |= peep6502.K_TAKEN
            if lastdot >= 0 and lastdot + 1 < i {
                s = strtab.intern_sym(text + lastdot + 1, (i - lastdot - 1) as uword)
                s.mark |= peep6502.K_TAKEN
            }
        }
    }

    sub zp_assign() {
        zp_count = 0
        zp_free_map()
        ^^ir.Var v = prog.vars
        ^^strtab.Sym s
        long size
        ; Those that the program wants there come first: what @requirezp names must be
        ; there (an error when it cannot), what @zp names is there when there is room.
        ubyte round
        for round in 0 to 1 {
            v = prog.vars
            while v != 0 {
                bool required = v.zp != 0 and strings.compare(v.zp, "REQUIRE_ZEROPAGE") == 0
                if zp_wanted(v) and required == (round == 0) and v.zpaddr == 0 and v.kind == ir.V_VAR {
                    size = zp_candidate(v, true)
                    if size != 0 {
                        v.zpaddr = zp_take(size)
                        if v.zpaddr != 0
                            zp_count++
                        else if required {
                            ; (upstream's words)
                            buf.clear(nb)
                            buf.add_str(nb, "no more free space in ZP to allocate ")
                            buf.add_long(nb, size)
                            buf.add_str(nb, " sequential bytes")
                            buf.add_byte(nb, 0)
                            error(strtab.intern_cstr(nb.data), v.name)
                        }
                    }
                    else if required
                        error("@requirezp is not supported by this code generator for a variable of this kind (an array or string with values, an aligned one)", v.name)
                }
                v = v.next
            }
        }
        v = prog.vars
        ; a few bytes for the temporaries that share them (peep6502.share_cells): each
        ; serves every subroutine, which is more than any variable does
        pool_count = 0
        long want = 4               ; (measured on p8vi: four do nearly all of it, more take bytes from the variables)
        ^^ubyte pv = io_platform.env("P8P8_ZP_POOL")
        if pv != 0 and pv[0] != 0
            want = number(pv)
        else if zp_left() < 32
            want = 2                ; (little zero page: two, the rest is worth more to the variables)
        if want > 32
            want = 32
        if not peep6502.enabled
            want = 0
        while pool_count < want and zp_left() > 6 {
            long pa = zp_take(1)
            if pa == 0
                break
            pool_at[pool_count] = pa as ubyte
            pool_count++
        }
        peep6502.pool_size = pool_count
        interrupt_subroutines()
        own_variables()
        ; how often each of the others is named
        v = prog.vars
        while v != 0 {
            s = strtab.intern_sym(v.name, buf.cstr_len(v.name) as uword)
            s.extra = 0
            v = v.next
        }
        ^^ubyte fg = io_platform.env("P8P8_ZP_FOLLOW")
        if fg != 0 and fg[0] != 0
            zp_follow_gain = number(fg)
        zp_count_chunk(prog.initglobals)
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            zp_count_chunk(bl.chunks)
            ^^ir.Sub sb = bl.subs
            while sb != 0 {
                zp_count_chunk(sb.chunks)
                sb = sb.next
            }
            bl = bl.next
        }
        ; the most used first, as long as there is room; some of it is left for the
        ; register cells that survive (cell_equates), which are used more than most
        long reserve = 0            ; (measured: p8vi is smallest with none; P8P8_ZP_CELLS to try others)
        ^^ubyte rv = io_platform.env("P8P8_ZP_CELLS")
        if rv != 0 and rv[0] != 0
            reserve = number(rv)
        repeat {
            if zp_left() <= reserve
                break
            ^^ir.Var best = 0
            long most = 0
            v = prog.vars
            while v != 0 {
                if zp_candidate(v, false) != 0 {
                    s = strtab.intern_sym(v.name, buf.cstr_len(v.name) as uword)
                    if s.extra > most {
                        most = s.extra
                        best = v
                    }
                }
                v = v.next
            }
            if best == 0
                break
            s = strtab.intern_sym(best.name, buf.cstr_len(best.name) as uword)
            s.extra = 0             ; (not looked at again, placed or not)
            best.zpaddr = zp_take(zp_candidate(best, false))
            if best.zpaddr != 0
                zp_count++
        }
        v = prog.vars
        while v != 0 {
            s = strtab.intern_sym(v.name, buf.cstr_len(v.name) as uword)
            s.extra = 0
            v = v.next
        }
    }

    ; The cells that the written code still names (p8r_N, a byte each): the most used
    ; go to what is left of the zero page, the others stay in p8_regfile.
    sub cell_equates() {
        if not peep6502.enabled
            return
        raw("; register cells")
        long n
        ubyte pk = 0
        while pk < pool_count {
            put("p8z_")
            putn(pk)
            put(" = ")
            putn(pool_at[pk])
            nl()
            pk++
        }
        repeat {
            long best = -1
            long most = 0
            for n in 0 to regfile_size - 1 {
                if peep6502.celluse[n] > most {
                    most = peep6502.celluse[n]
                    best = n
                }
            }
            if best < 0
                break
            long at = zp_take(1)
            if at == 0
                break
            put("p8r_")
            putn(best)
            put(" = ")
            putn(at)
            nl()
            peep6502.celluse[best] = 0
        }
        ; the others one after the other behind the float cells
        regfile_used = float_cells
        for n in 0 to regfile_size - 1 {
            if peep6502.celluse[n] > 0 {
                put("p8r_")
                putn(n)
                put(" = p8_regfile+")
                putn(regfile_used)
                nl()
                regfile_used++
            }
        }
        raw("")
    }

    ; the names of the variables in the zero page
    sub zp_equates() {
        raw("; zero page variables")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.zpaddr != 0 {
                put(v.name)
                put(" = ")
                putn(v.zpaddr)
                nl()
            }
            v = v.next
        }
        raw("")
    }

    ; the initial values of the variables in the zero page that have one
    ; In a program for ROM (%option romable) nothing that is written can be in the
    ; program itself: a scalar variable with an initial value lives with the
    ; uninitialized ones in RAM and gets its value from code, like one in the zero
    ; page.  (Arrays and strings with initial values stay in the ROM, read only.)
    bool romable = false

    sub ram_initialized(^^ir.Var v) -> bool {
        return romable and v.kind == ir.V_VAR and v.init != 0 and v.zpaddr == 0 and not v.split
            and array_length(v.typestr) == 0
    }

    sub zp_initial_values() {
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.init == 0 and v.zpaddr != 0 and array_length(v.typestr) != 0 {
                ; an array in the zero page: cleared, like the ones in the BSS
                long bytes = var_size(v)
                ins_imm("ldy", bytes)
                ins("lda", "#0")
                anon_label("-")
                ins("dey", 0)
                ins_indexed("sta", v.name, 0, 'y')
                ins("bne", "-")
            }
            if v.init != 0 and (v.zpaddr != 0 or ram_initialized(v)) {
                long size = element_size(v.typestr)
                long k
                if v.init[0] == '@' {
                    ; an address
                    ins_half("lda", '<', v.init + 1, 0)
                    ins_at("sta", v.name, 0)
                    ins_half("lda", '>', v.init + 1, 0)
                    ins_at("sta", v.name, 1)
                }
                else if starts_with(v.typestr, "float") {
                    float_bytes(irparse.parse_float(v.init))
                    ubyte fbk
                    for fbk in 0 to 4 {
                        ins_imm("lda", fbytes[fbk])
                        ins_at("sta", v.name, fbk)
                    }
                }
                else {
                    long value = number(v.init)
                    for k in 0 to size - 1 {
                        ubyte part = ((value >> ((k as ubyte) * 8)) & 255) as ubyte
                        if part == 0 {
                            ; (outside the zero page it is with the variables that are cleared at the start)
                            if v.zpaddr != 0
                                store_zero(v.name, k)
                        }
                        else {
                            ins_imm("lda", part)
                            ins_at("sta", v.name, k)
                        }
                    }
                }
            }
            v = v.next
        }
    }

    ; ---- the file ----

    ; Writes the program as assembly into the buffer.
    sub generate(^^ir.Program p, ^^buf.Buf output) {
        prog = p
        o = output
        errors = 0
        fconst_count = 0
        breakpoints = 0
        float_errors = 0
        if nb == 0
            nb = buf.new(256)
        ; the CPU: a 65C02 has more instructions (the default without a configuration: a 6502)
        c02 = target.is("cpu", "65c02") or target.is("cpu", "cpu65c02")
        c816 = target.is("cpu", "65816") or target.is("cpu", "65c816") or target.is("cpu", "w65c816")
        c45 = target.is("cpu", "45gs02")
        if cpu_option != 0 {
            c02 = strings.compare(cpu_option, "65c02") == 0
            c816 = strings.compare(cpu_option, "65816") == 0
            c45 = strings.compare(cpu_option, "45gs02") == 0
            if not c02 and not c816 and not c45 and strings.compare(cpu_option, "6502") != 0
                error("this code generator has no instructions for the cpu of -cpu", cpu_option)
        }
        if c816 or c45
            c02 = true              ; (the 65C02's instructions that p8p8 uses are all the 65816's too)
        ; On the 45GS02 "stz" stores the Z register and "(zp)" is "(zp),z".  With Z at zero
        ; they are the 65C02's, and the generated code leaves Z at zero; whether the
        ; machine's ROM does is another matter, so they are only used when asked for
        ; (P8P8_45_STZ, for trying it).
        c02z = c02 and (not c45 or io_platform.env("P8P8_45_STZ") != 0)
        if cpu_option == 0 and target.loaded and not c02 and not target.is("cpu", "6502") and not target.is("cpu", "cpu6502")
            error("this code generator has no instructions for the target's cpu", target.text("cpu"))
        read_options()
        overlay_prepare()
        far_prepare()
        wide_prepare()
        assign_cells()
        count_registers()
        zp_assign()
        peep6502.init(regfile_size)
        peep6502.c02 = c02
        peep6502.c02z = c02z
        peep6502.c45 = c45
        hardware_math = c45 and io_platform.env("P8P8_45_NOMATH") == 0
        peep6502.arms_enabled = io_platform.env("P8P8_NOARMS") == 0
        long fr = 1
        while fr <= ir.regcount {
            ; (the address of a float's cell goes to the float routines)
            if ir.regtypes[fr] == ir.T_FLOAT
                peep6502.opaque_cells(cell_of[fr], 5)
            fr++
        }
        ; (and so does that of a long that is converted to or from a float)
        fr = 1
        while fr <= ir.regcount {
            if reg_fixed[fr] != 0
                peep6502.opaque_cells(cell_of[fr], 4)
            fr++
        }
        if types.far_bits != 0
            peep6502.opaque_cells(far_cells, 5)
        ^^ir.Var v = p.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 and strings.compare(v.name, "cx16.r0") == 0 {
                bool vok
                long vaddr
                vok, vaddr = peep6502.parse_number(v.init)
                if vok
                    peep6502.virtual_registers(vaddr)
            }
            if v.kind == ir.V_VAR and not v.split {
                peep6502.plain_variable(v.name)
                ; a scalar whose address nothing takes cannot be changed through a pointer
                if array_length(v.typestr) == 0 and not v.shared {
                    ^^strtab.Sym vs = strtab.intern_sym(v.name, buf.cstr_len(v.name) as uword)
                    ^^ubyte vtail = unscoped(v.name)
                    ^^strtab.Sym vt = strtab.intern_sym(vtail, buf.cstr_len(vtail) as uword)
                    if vs.mark & peep6502.K_TAKEN == 0 and vt.mark & peep6502.K_TAKEN == 0
                        peep6502.safe_variable(v.name)
                }
            }
            if v.zpaddr != 0
                peep6502.zp_variable(v.name)
            v = v.next
        }
        ; The code is written first, aside: only then is it known which register cells
        ; are left, and their places (like those of the variables in the zero page) are
        ; defined before the code in the file, so that the assembler knows the size of
        ; every instruction when it comes to it.
        if codebuf == 0
            codebuf = buf.new(262144)
        buf.clear(codebuf)
        o = codebuf
        code()
        if wide_enabled {
            join_runs(codebuf)
            if overlay_max != 0
                join_runs(ovlbuf)
        }
        if wide_enabled and io_platform.env("P8P8_WIDESTATS") != 0 {
            ; (for the work on the generator: how much of the word code is 16 bits wide)
            buf.add_str(codebuf, "; 65816: ")
            buf.add_long(codebuf, wide_done)
            buf.add_str(codebuf, " of ")
            buf.add_long(codebuf, wide_total)
            buf.add_str(codebuf, " word instructions in runs\n")
            ubyte op
            for op in 0 to 255 {
                if wide_missed[op] != 0 {
                    buf.add_str(codebuf, "; 8-bit: ")
                    buf.add_str(codebuf, ir.opcode_names[op])
                    buf.add_byte(codebuf, ' ')
                    buf.add_long(codebuf, wide_missed[op])
                    buf.add_byte(codebuf, '\n')
                }
            }
        }
        o = output
        header()
        constants()
        zp_equates()
        cell_equates()
        buf.add_bytes(o, codebuf.data, codebuf.len)
        data()
        bss()
        if romable {
            rom_requirements()
            rom_guard(output)
        }
        if overlay_max != 0
            buf.add_bytes(o, ovlbuf.data, ovlbuf.len)
    }

    sub fixed_longs_in(^^ir.Chunk c) {
        while c != 0 {
            if c.kind != ir.C_ASM {
                ^^ir.Instr i = c.first
                while i != 0 {
                    ; (and which registers the code that is left still names)
                    if i.r1 != 0 and i.r1 <= ir.regcount
                        reg_named[i.r1] = 1
                    if i.r2 != 0 and i.r2 <= ir.regcount
                        reg_named[i.r2] = 1
                    if i.r3 != 0 and i.r3 <= ir.regcount
                        reg_named[i.r3] = 1
                    ^^ir.Arg na = i.args
                    while na != 0 {
                        if na.reg != 0 and na.reg <= ir.regcount
                            reg_named[na.reg] = 1
                        na = na.next
                    }
                    na = i.results
                    while na != 0 {
                        if na.reg != 0 and na.reg <= ir.regcount
                            reg_named[na.reg] = 1
                        na = na.next
                    }
                    if i.op == ir.OP_FFROMSL and i.r2 != 0 and i.r2 <= ir.regcount
                        reg_fixed[i.r2] = 1
                    if i.op == ir.OP_FTOSL and i.r1 != 0 and i.r1 <= ir.regcount
                        reg_fixed[i.r1] = 1
                    i = i.next
                }
            }
            c = c.next
        }
    }

    ; ---- programs for ROM (%option romable) ----

    ; what upstream asks of such a program, in its words
    sub rom_requirements() {
        if prog.floats
            error("When ROMable code is selected, floating point support is not available", 0)
        if vars_address < 0 and not vars_golden and vars_high_bank < 0 and target.text("vars_address") == 0
            error("When ROMable code is selected, variables and memory slabs should be moved to a RAM memory region using either -varsgolden, -varshigh or -varsaddress option or %varsaddress directive", 0)
    }

    ; Nothing in a program for ROM may be written to.  After every instruction of the
    ; finished program that writes to memory (this generator's and the library's
    ; assembly alike) comes a line that makes the assembler stop when the address is
    ; inside the program: a variable that was left there, an array with values, code
    ; that changes itself.  The assembler knows every address; the generator does not.
    sub rom_guard(^^buf.Buf text) {
        ^^buf.Buf guarded = buf.new(text.len + text.len / 4 + 1024)
        long at = 0
        while at < text.len {
            long stop = at
            while stop < text.len and text.data[stop] != '\n'
                stop++
            buf.add_bytes(guarded, text.data + at, stop - at)
            buf.add_byte(guarded, '\n')
            long k = at
            while k < stop and (text.data[k] == ' ' or text.data[k] == '\t')
                k++
            ; (an instruction is indented; a label, a directive, a comment is not one)
            if k > at and k + 4 < stop and rom_writer(text.data + k) and (text.data[k + 3] == ' ' or text.data[k + 3] == '\t') {
                long first = k + 3
                while first < stop and (text.data[first] == ' ' or text.data[first] == '\t')
                    first++
                long last = first
                bool plain = true
                while last < stop and text.data[last] != ';' {
                    if text.data[last] == '"' or text.data[last] == '\\' or text.data[last] == '(' or text.data[last] == '#'
                        plain = false
                    last++
                }
                while last > first and (text.data[last - 1] == ' ' or text.data[last - 1] == '\t')
                    last--
                ; (indexed: the address the index is added to)
                if last - first > 2 and text.data[last - 2] == ',' and (text.data[last - 1] | 32 == 'x' or text.data[last - 1] | 32 == 'y')
                    last -= 2
                while last > first and (text.data[last - 1] == ' ' or text.data[last - 1] == '\t')
                    last--
                bool register = last - first == 1 and text.data[first] | 32 == 'a'
                bool anonymous = last > first and (text.data[first] == '+' or text.data[first] == '-')
                if plain and last > first and not register and not anonymous {
                    buf.add_str(guarded, "    .cerror ((")
                    buf.add_bytes(guarded, text.data + first, last - first)
                    buf.add_str(guarded, ") >= prog8_program_start) && ((")
                    buf.add_bytes(guarded, text.data + first, last - first)
                    buf.add_str(guarded, ") < prog8_program_end), \"ROMable code: this writes into the program: ")
                    buf.add_bytes(guarded, text.data + k, 3)
                    buf.add_byte(guarded, ' ')
                    buf.add_bytes(guarded, text.data + first, last - first)
                    buf.add_str(guarded, "\"\n")
                }
            }
            at = stop + 1
        }
        buf.clear(text)
        buf.add_bytes(text, guarded.data, guarded.len)
    }

    ; is this the mnemonic of an instruction that writes to its operand
    sub rom_writer(^^ubyte m) -> bool {
        ubyte a = m[0] | 32
        ubyte b = m[1] | 32
        ubyte c = m[2] | 32
        when a {
            's' -> return b == 't' and (c == 'a' or c == 'x' or c == 'y' or c == 'z')
            'i' -> return b == 'n' and c == 'c'
            'd' -> return b == 'e' and c == 'c'
            'a' -> return b == 's' and c == 'l'
            'l' -> return b == 's' and c == 'r'
            'r' -> return b == 'o' and (c == 'l' or c == 'r')
            't' -> return (b == 'r' or b == 's') and c == 'b'
        }
        return false
    }

    ^^buf.Buf codebuf = 0

    sub starts_with(^^ubyte s, str prefix) -> bool {
        return buf.bytes_equal(s, prefix, buf.cstr_len(prefix))
    }

    sub header() {
        put("; Program: ")
        put(prog.name)
        nl()
        raw("; Generated by p8p8's 6502 code generator")
        if c816 {
            raw("; Target CPU: 65816")
            raw("")
            raw(".cpu  '65816'")
        }
        else if c45 {
            raw("; Target CPU: 45GS02")
            raw("")
            raw(".cpu  '45gs02'")
        }
        else if c02 {
            raw("; Target CPU: 65C02")
            raw("")
            raw(".cpu  'w65c02'")
        }
        else {
            raw("; Target CPU: 6502")
            raw("")
            raw(".cpu  '6502'")
        }
        raw(".enc 'none'")
        raw("")
        raw("; zero page scratch cells")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 and starts_with(v.name, "P8ZP_SCRATCH") {
                put(v.name)
                put(" = ")
                put(v.init)
                nl()
            }
            v = v.next
        }
        ; the machine's own symbols
        ^^ubyte symbols = target.text("asm_symbols")
        if prog.floats and target.text("asm_symbols_floats") != 0
            symbols = target.text("asm_symbols_floats")
        if symbols != 0
            raw(symbols)
        ^^ubyte custom = target.text("custom_launcher_code")
        if custom != 0 {
            ; the machine brings its whole launcher and startup code
            raw("")
            raw("; ---- custom launcher assembler program ----")
            ; (its text is the same for every program; this says whether this one leaves the
            ; zero page as BASIC needs it, so that the launcher can return or reset)
            if zp_safe
                raw("prog8_zeropage_safe = 1")
            else
                raw("prog8_zeropage_safe = 0")
            put("* = ")
            puthex(load_address)
            nl()
            raw("prog8_program_start:")
            raw(custom)
            raw("")
            return
        }
        raw("")
        if launcher_basic {
            raw("; ---- basic program with sys call ----")
            put("* = ")
            puthex(load_address)
            nl()
            raw("prog8_program_start:")
            raw("    .word  (+), 2026")
            raw("    .null  $9e, format(' %d ', prog8_entrypoint), $3a, $8f, ' prog8'")
            anon_label("+")
            raw("    .word  0")
            raw("prog8_entrypoint:")
        }
        else {
            raw("; ---- program without basic sys call ----")
            put("* = ")
            puthex(load_address)
            nl()
            raw("prog8_program_start:")
        }
        if strings.compare(output_type, "LIBRARY") == 0 {
            ; A library is not started: whoever loads it calls into it.  It begins with a
            ; jump to main.start, and main's code (its %jmptable first) comes right after.
            ins("jmp", "p8b_main.p8s_start")
            raw("")
            return
        }
        ; the startup sequence
        if target.text("startup_code") != 0
            raw(target.text("startup_code"))
        ins("cld", 0)
        ins("tsx", 0)
        ins("stx", "prog8_lib.orig_stackpointer")
        if not no_sysinit
            ins("jsr", "p8_sys_startup.init_system")
        ins("jsr", "p8_sys_startup.init_system_phase2")
        if not zp_safe {
            ; the zero page is used: the machine is reset when the program ends
            ^^ubyte reset = target.text("reset_address")
            if reset == 0
                reset = "sys.reset_system"
            put("    lda  #>")
            raw(reset)
            ins("pha", 0)
            put("    lda  #<")
            raw(reset)
            ins("pha", 0)
        }
        if prog.floats and target.text("startup_code_floats") != 0
            raw(target.text("startup_code_floats"))
        if wide_enabled and wide_rest {
            ; the 65816's native mode while the program runs, with 8-bit registers as in
            ; emulation mode; back to that before the program ends
            raw("    clc")
            raw("    xce")
            ins("jsr", "p8b_main.p8s_start")
            raw("    sec")
            raw("    xce")
        }
        else
            ins("jsr", "p8b_main.p8s_start")
        ins("jmp", "p8_sys_startup.cleanup_at_exit")
        if target.text("exit_code") != 0
            raw(target.text("exit_code"))
        raw("")
    }

    ; "p8c_" plus the name with its dots as underscores
    sub put_const_label(^^ubyte name) {
        put("p8c_")
        long i = 0
        while name[i] != 0 {
            if name[i] == '.'
                buf.add_byte(w(), '_')
            else
                buf.add_byte(w(), name[i])
            i++
        }
    }

    ; is this the name of something directly in a block ("block.name")?
    sub block_level(^^ubyte name) -> bool {
        ubyte dots = 0
        long i = 0
        while name[i] != 0 {
            if name[i] == '.'
                dots++
            i++
        }
        return dots <= 1
    }

    ; the name without its last part
    sub owner_name(^^ubyte name) -> ^^ubyte {
        long cut = 0
        long i = 0
        while name[i] != 0 {
            if name[i] == '.'
                cut = i
            i++
        }
        return strtab.intern(name, cut as uword)
    }

    sub constants() {
        raw("; constants")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_CONST and v.init != 0 {
                if not v.noprefix {
                    put_const_label(v.name)
                    put(" = ")
                    put(v.init)
                    nl()
                }
                ; under its own name too, for assembly code: a block's constant always, a
                ; subroutine's when the subroutine is in the program (else there is no such scope)
                if block_level(v.name) or find_sub(owner_name(v.name)) != 0 {
                    put(v.name)
                    put(" = ")
                    put(v.init)
                    nl()
                }
            }
            v = v.next
        }
        raw("")
        raw("; memory-mapped variables")
        v = prog.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 and not starts_with(v.name, "P8ZP_SCRATCH") {
                put(v.name)
                put(" = ")
                put(v.init)
                nl()
            }
            v = v.next
        }
        raw("")
    }

    ; ---- code ----

    ; is name "parent.something"
    sub nested_in(^^ubyte name, ^^ubyte parent) -> bool {
        long n = buf.cstr_len(parent)
        return buf.bytes_equal(name, parent, n) and name[n] == '.'
    }

    ; the subroutine that this one is nested in, or 0
    ; the subroutine that s is declared in: the innermost one, when they are nested deeper
    sub parent_of(^^ir.Block bl, ^^ir.Sub s) -> ^^ir.Sub {
        ^^ir.Sub other = bl.subs
        ^^ir.Sub parent = 0
        while other != 0 {
            if other != s and not other.is_asm and nested_in(s.name, other.name) {
                if parent == 0 or buf.cstr_len(other.name) > buf.cstr_len(parent.name)
                    parent = other
            }
            other = other.next
        }
        return parent
    }

    ; the last part of a scoped name
    sub unscoped(^^ubyte name) -> ^^ubyte {
        long i = buf.cstr_len(name)
        while i > 0 and name[i - 1] != '.'
            i--
        return name + i
    }

    ; The struct types, for assembly code that asks for a struct's size or a field's
    ; offset ("#size(p8t_Node)", "#p8t_Node.p8v_value"): as upstream defines them.
    sub struct_definitions() {
        ^^ir.Var v = prog.vars
        bool any = false
        while v != 0 {
            if v.kind == ir.V_STRUCT and v.typestr != 0 {
                if not any
                    raw("; struct types")
                any = true
                ^^ubyte f = v.typestr
                ; the parameters: one for every field that is not an array
                put(v.name)
                put("    .struct ")
                long at = 0
                long number = 0
                while f[at] != 0 {
                    long stop = at
                    bool array = false
                    while f[stop] != 0 and f[stop] != ';' {
                        if f[stop] == '['
                            array = true
                        stop++
                    }
                    if not array {
                        if number != 0
                            put(",")
                        put("f")
                        putn(number)
                        number++
                    }
                    at = stop
                    if f[at] == ';'
                        at++
                }
                nl()
                at = 0
                number = 0
                while f[at] != 0 {
                    ; "type name" or "type[n] name"
                    long space = at
                    while f[space] != 0 and f[space] != ' ' and f[space] != ';'
                        space++
                    long bracket = at
                    while bracket < space and f[bracket] != '['
                        bracket++
                    long fend = space
                    while f[fend] != 0 and f[fend] != ';'
                        fend++
                    put("p8v_")
                    if f[space] == ' '
                        buf.add_bytes(w(), f + space + 1, fend - space - 1)
                    ^^ubyte directive = ".byte"
                    long size = 1
                    if buf.bytes_equal(f + at, "byte", 4) {
                        directive = ".char"
                    }
                    else if buf.bytes_equal(f + at, "uword", 5) or buf.bytes_equal(f + at, "pointer", 7) {
                        directive = ".word"
                        size = 2
                    }
                    else if buf.bytes_equal(f + at, "word", 4) {
                        directive = ".sint"
                        size = 2
                    }
                    else if buf.bytes_equal(f + at, "long", 4) {
                        directive = ".dint"
                        size = 4
                    }
                    else if buf.bytes_equal(f + at, "float", 5) {
                        directive = 0
                        size = 5
                    }
                    if bracket < space {
                        ; an array: so many bytes, with no value
                        long count = 0
                        long d = bracket + 1
                        while f[d] >= '0' and f[d] <= '9' {
                            count = count * 10 + (f[d] - '0')
                            d++
                        }
                        put("  .fill ")
                        putn(count * size)
                    }
                    else {
                        if directive == 0
                            put("  .fill 5, \\f")
                        else {
                            put("  ")
                            put(directive)
                            put("  \\f")
                        }
                        putn(number)
                        number++
                    }
                    nl()
                    at = fend
                    if f[at] == ';'
                        at++
                }
                raw("    .endstruct")
                put(v.name)
                put("_size=")
                putn(v.size)
                nl()
            }
            v = v.next
        }
        if any
            raw("")
    }

    sub global_inits_code() {
        raw("run_global_inits:")
        peep6502.begin(o)
        zp_initial_values()
        chunk_code(prog.initglobals, 0)
        ins("rts", 0)
        peep6502.flush()
        raw("")
    }

    sub code() {
        ; The blocks come first, main before the others, right after the startup code as
        ; upstream has them: a library's jump table has its fixed place there, and a
        ; cartridge's main block sets the assembler's address around its header.
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            block_code(bl)
            bl = bl.next
        }
        overlay_thunks()
        global_inits_code()
        out_count = 0
        overlay_code()
        overlay_out_stubs()
    }

    ; ---- overlays ----
    ; A block with "%overlay n" has its code in overlay n: on the Commander X16 a bank of
    ; high memory, which is in the window at $a000 only while its code runs.  The
    ; variables, strings and arrays of such a block are in main memory like all others,
    ; so an overlay is code only and never has to be written back.  A call within an
    ; overlay, and from an overlay into the main program, is a plain jsr.  A call into an
    ; overlay from outside it goes to a thunk in main memory that brings the overlay in,
    ; calls, and puts back what was there (the target's "overlay_thunk"); the address of
    ; a subroutine in an overlay is its thunk's.
    ; The assembly has every overlay at the window's address.  It is assembled once for
    ; the main program and once for each overlay (prog8_overlay = 0, 1, 2...): the part
    ; that is wanted is there, the others are virtual, so every run has the same labels.
    ubyte overlay_max = 0
    ubyte cur_overlay = 0
    long overlay_start = 0
    long overlay_end = 0
    ^^buf.Buf ovlbuf = 0

    sub overlay_prepare() {
        overlay_max = 0
        cur_overlay = 0
        overlay_start = target.number("overlay_window_start", 0)
        overlay_end = target.number("overlay_window_end", 0)
        bool possible = overlay_start != 0 and target.text("overlay_thunk") != 0 and not overlays_off
        overlay_returns = possible and target.text("overlay_return") != 0
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            if not possible
                bl.overlay = 0          ; (a machine without them: one program, as if nothing was said)
            else if bl.overlay != 0 and strings.compare(bl.name, "p8b_main") == 0 {
                error("the main block cannot be in an overlay (its subroutines can, one by one)", 0)
                bl.overlay = 0
            }
            ; every subroutine gets the overlay its code is in: its own, or its block's; one
            ; that is declared in another is written with that one, and goes where it goes
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if not possible
                    s.overlay = 0
                else if parent_of(bl, s) == 0 {
                    if s.overlay == 0
                        s.overlay = bl.overlay
                    else if strings.compare(s.name, "p8b_main.p8s_start") == 0 {
                        error("main.start cannot be in an overlay", 0)
                        s.overlay = 0
                    }
                    if s.overlay > overlay_max
                        overlay_max = s.overlay
                }
                s = s.next
            }
            s = bl.subs
            while s != 0 {
                ^^ir.Sub outer = parent_of(bl, s)
                if outer != 0 {
                    if possible and s.overlay != 0
                        error("%overlay is for a subroutine at block level; one inside another goes with it", s.name)
                    ^^ir.Sub top = outer
                    while outer != 0 {
                        top = outer
                        outer = parent_of(bl, outer)
                    }
                    s.overlay = top.overlay
                }
                s = s.next
            }
            bl = bl.next
        }
        ; An overlay that the program names but that has nothing in it (none of its
        ; subroutines is used, so there is no code): said, and the program is still built
        ; as one with overlays, so that what is written does not depend on it.
        if possible {
            ubyte wanted = 1
            repeat 255 {
                if ir.overlay_wanted[wanted] {
                    if not overlay_used(wanted) {
                        out.err()
                        out.puts("warning: overlay ")
                        buf.clear(nb)
                        buf.add_long(nb, wanted)
                        buf.add_byte(nb, 0)
                        out.puts(nb.data)
                        out.puts(" has nothing in it: none of its subroutines is used")
                        out.nl()
                    }
                    if wanted > overlay_max
                        overlay_max = wanted
                }
                wanted++
            }
        }
        long most = target.number("overlay_max", 255)
        if overlay_max > most {
            error("the target has no room for an overlay of that number", target.text("overlay_max"))
            overlay_max = most as ubyte
        }
        ; (a window in main memory: the program itself ends below it)
        if overlay_max != 0 and memtop > overlay_start and load_address < overlay_start
            memtop = overlay_start
    }

    ; the overlay that the subroutine of this name is in (0: none, or no subroutine)
    sub overlay_of(^^ubyte sym) -> ubyte {
        ^^ir.Sub s = find_sub(sym)
        if s == 0
            return 0
        return s.overlay
    }

    ; "p8ovt_" and the subroutine's name with its dots as underscores
    sub thunk_name(^^ubyte sym) -> ^^ubyte {
        return thunk_named("p8ovt_", sym)
    }

    ; (the thunk for a call from another overlay, on a target that has one of its own for
    ; that: "overlay_thunk_cross")
    sub cross_thunk_name(^^ubyte sym) -> ^^ubyte {
        if target.text("overlay_thunk_cross") == 0
            return thunk_name(sym)
        return thunk_named("p8ovx_", sym)
    }

    sub thunk_named(str prefix, ^^ubyte sym) -> ^^ubyte {
        buf.clear(nb)
        buf.add_str(nb, prefix)
        long k = 0
        while sym[k] != 0 {
            if sym[k] == '.'
                buf.add_byte(nb, '_')
            else
                buf.add_byte(nb, sym[k])
            k++
        }
        buf.add_byte(nb, 0)
        return strtab.intern_cstr(nb.data)
    }

    ; What a call of this subroutine names: itself, or its thunk when it is in an overlay
    ; that the code being written is not in.
    sub overlay_entry(^^ubyte sym) -> ^^ubyte {
        if overlay_max == 0 or sym == 0
            return sym
        ubyte ov = overlay_of(sym)
        if ov == 0 or ov == cur_overlay
            return sym
        if cur_overlay != 0
            return cross_thunk_name(sym)
        return thunk_name(sym)
    }

    ; a target's text with %t as the subroutine and %n as the overlay, its lines indented
    sub put_template(^^ubyte template, ^^ubyte subroutine, ubyte overlay) {
        long k = 0
        put("    ")
        while template[k] != 0 {
            if template[k] == '%' and template[k + 1] == 't' {
                put(subroutine)
                k++
            }
            else if template[k] == '%' and template[k + 1] == 'n' {
                putn(overlay)
                k++
            }
            else if template[k] == '\n' {
                nl()
                put("    ")
            }
            else
                buf.add_byte(w(), template[k])
            k++
        }
        nl()
    }

    ; A call out of an overlay into the main program or the library.  What is called may
    ; leave another bank in the window (a program's own data), and then the code that
    ; called is not there to go on.  So on a target with "overlay_return" such a call
    ; goes to a stub in main memory that calls the subroutine, puts the overlay back
    ; (that text: %n is the overlay) and returns into it.  There is one stub for each
    ; subroutine and overlay that calls it; the fast text is for an ordinary
    ; subroutine, after which the flags need not survive.  A call through a pointer has
    ; a stub of its own for each overlay.  (A call into another overlay goes through
    ; that one's thunk, which puts back what was there itself.)
    const uword OUT_STUBS = 1024
    bool overlay_returns = false    ; the target has "overlay_return"
    bool overlays_off = false       ; -nooverlays: one program, whatever the source and the target say
    ^^pointer out_names = 0         ; the stubs' names
    ^^pointer out_callees = 0       ; what each calls (0: through the pointer in the scratch word)
    ^^ubyte out_overlays = 0
    uword out_count = 0

    sub overlay_out(^^ubyte callee_name) -> ^^ubyte {
        if cur_overlay == 0 or not overlay_returns
            return callee_name
        if callee_name != 0 and (callee_name[0] == '$' or (callee_name[0] >= '0' and callee_name[0] <= '9'))
            return callee_name          ; (a routine of the ROM by its address: it leaves the bank as it is)
        if callee_name != 0 {
            ^^ir.Sub callee = find_sub(callee_name)
            if callee != 0 and callee.overlay != 0
                return callee_name      ; (the same overlay, or through a thunk)
            ; From a block with "%option overlay_data" a routine of the library is called
            ; with the overlay still in the window: the block has data beside its code
            ; (an asset), and hands the library its address to copy or unpack it.
            if cur_block != 0 and cur_block.overlay_data and in_library(callee_name)
                return callee_name
        }
        buf.clear(nb)
        buf.add_str(nb, "p8ovr_")
        buf.add_long(nb, cur_overlay)
        buf.add_byte(nb, '_')
        if callee_name == 0
            buf.add_str(nb, "pointer")
        else {
            long k = 0
            while callee_name[k] != 0 {
                if callee_name[k] == '.'
                    buf.add_byte(nb, '_')
                else
                    buf.add_byte(nb, callee_name[k])
                k++
            }
        }
        buf.add_byte(nb, 0)
        ^^ubyte name = strtab.intern_cstr(nb.data)
        if out_names == 0 {
            out_names = mem.alloc(OUT_STUBS as long * sizeof(pointer))
            out_callees = mem.alloc(OUT_STUBS as long * sizeof(pointer))
            out_overlays = mem.alloc(OUT_STUBS)
        }
        uword n = 0
        while n < out_count {
            ^^ubyte known = out_names[n]
            if known == name
                return name
            n++
        }
        if out_count == OUT_STUBS {
            error("too many different calls out of overlays for this code generator (1024)", callee_name)
            return callee_name
        }
        out_names[out_count] = name
        out_callees[out_count] = callee_name
        out_overlays[out_count] = cur_overlay
        out_count++
        return name
    }

    ; is this the name of a subroutine in a block of the library?
    sub in_library(^^ubyte name) -> bool {
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            if bl.library {
                ^^ir.Sub s = bl.subs
                while s != 0 {
                    if s.name == name or strings.compare(s.name, name) == 0
                        return true
                    s = s.next
                }
            }
            bl = bl.next
        }
        return false
    }

    ; the stubs, in main memory: each is the target's text (%t: what is called, %n: the
    ; overlay to come back into), and for each overlay that has any the routines they
    ; end in (the target's "overlay_back" and "overlay_back_full")
    sub overlay_out_stubs() {
        if out_count == 0
            return
        raw("; ---- the ways out of the overlays and back ----")
        uword n
        for n in 0 to out_count - 1 {
            ^^ubyte callee_name = out_callees[n]
            ^^ubyte template = target.text("overlay_return")
            put(out_names[n])
            raw("  .proc")
            if callee_name == 0
                put_template(template, "_through", out_overlays[n])
            else {
                ^^ir.Sub callee = find_sub(callee_name)
                if callee != 0 and not callee.is_asm and target.text("overlay_return_fast") != 0
                    template = target.text("overlay_return_fast")
                put_template(template, callee_name, out_overlays[n])
            }
            if callee_name == 0
                raw("_through  jmp  (P8ZP_SCRATCH_W1)")
            raw("    .pend")
        }
        ubyte ov
        for ov in 1 to overlay_max {
            if overlay_used(ov) {
                if target.text("overlay_back") != 0 {
                    put("p8_overlay_back_")
                    putn(ov)
                    raw("  .proc")
                    put_template(target.text("overlay_back"), 0, ov)
                    raw("    .pend")
                }
                if target.text("overlay_back_full") != 0 {
                    put("p8_overlay_backp_")
                    putn(ov)
                    raw("  .proc")
                    put_template(target.text("overlay_back_full"), 0, ov)
                    raw("    .pend")
                }
            }
        }
        raw("")
    }

    ; the thunks of one kind: for calls from the main program, or (cross) from another
    ; overlay where the target has other code for that
    sub thunks_of_kind(bool cross) {
        ^^ubyte full = target.text("overlay_thunk")
        ^^ubyte fast = target.text("overlay_thunk_fast")
        if cross {
            full = target.text("overlay_thunk_cross")
            fast = target.text("overlay_thunk_cross_fast")
        }
        if fast == 0
            fast = full
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if s.overlay != 0 and parent_of(bl, s) == 0 and not (s.is_asm and s.is_inline) {
                    ; (a subroutine in assembly may take and give anything, flags too)
                    ^^ubyte template = fast
                    if s.is_asm
                        template = full
                    if cross
                        put(cross_thunk_name(s.name))
                    else
                        put(thunk_name(s.name))
                    raw("  .proc")
                    put_template(template, s.name, s.overlay)
                    raw("    .pend")
                }
                s = s.next
            }
            bl = bl.next
        }
    }

    ; a thunk for every subroutine of the overlay blocks (the assembler leaves out the
    ; ones nothing calls)
    sub overlay_thunks() {
        if overlay_max == 0
            return
        raw("; ---- the ways into the overlays ----")
        thunks_of_kind(false)
        if target.text("overlay_thunk_cross") != 0
            thunks_of_kind(true)
        ^^ubyte support = target.text("overlay_support")
        if support != 0 {
            ; the target's code that brings an overlay in, and what it needs to know
            put("p8_overlay_window = ")
            puthex(overlay_start)
            nl()
            put("p8_overlay_size = ")
            puthex(overlay_end - overlay_start)
            nl()
            put("p8_overlay_select = ")
            puthex(target.number("overlay_select", 0))
            nl()
            put("p8_overlay_store = ")
            puthex(target.number("overlay_store", 0))
            nl()
            if target.number("overlay_image_size", 0) == 0 {
                ; (for a machine that copies an overlay in: how much of it there is)
                raw("p8_overlay_sizes:")
                ubyte sn
                for sn in 1 to overlay_max {
                    if overlay_used(sn) {
                        put("    .word  p8ov_size_")
                        putn(sn)
                        nl()
                    }
                    else
                        raw("    .word  0")
                }
            }
            raw("p8_overlay_file  .macro")
            put("    .byte  ")
            petscii_name(w(), prog.name)
            raw("")
            raw("    .endm")
            put("    .include \"")
            put(support)
            raw("\"")
        }
        raw("")
    }

    ; "name.non" as the bytes a Commodore DOS takes for it, for .byte: small letters are
    ; its unshifted ones and capitals its shifted ones; everything else is as it is (an
    ; underscore is $5f, which is what the key gives and what the X16's DOS takes for it)
    sub petscii_name(^^buf.Buf dest, ^^ubyte name) {
        long k = 0
        while name[k] != 0 {
            ubyte c = name[k]
            if c >= 'a' and c <= 'z'
                c -= 32
            else if c >= 'A' and c <= 'Z'
                c += 128
            buf.add_long(dest, c)
            buf.add_byte(dest, ',')
            k++
        }
        buf.add_str(dest, "46,78,79,78")       ; ".NON"
    }

    sub overlay_used(ubyte n) -> bool {
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            if bl.overlay == n and (bl.subs != 0 or bl.chunks != 0)
                return true
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if s.overlay == n
                    return true
                s = s.next
            }
            bl = bl.next
        }
        return false
    }

    ; the overlays themselves, after everything else in the file
    sub overlay_code() {
        if overlay_max == 0
            return
        if ovlbuf == 0
            ovlbuf = buf.new(65536)
        buf.clear(ovlbuf)
        ^^buf.Buf main_o = o
        o = ovlbuf
        raw("")
        raw("; ---- the overlays ----")
        ubyte n
        for n in 1 to overlay_max {
            ^^ir.Block bl
            if overlay_used(n) {
                put("p8ov_part_")
                putn(n)
                raw("  .segment")
                cur_overlay = n
                bl = prog.blocks
                while bl != 0 {
                    block_code(bl)
                    bl = bl.next
                }
                cur_overlay = 0
                raw("    .endm")
                put("    .if prog8_overlay == ")
                putn(n)
                nl()
                put("* = ")
                puthex(overlay_start)
                nl()
                put("    #p8ov_part_")
                putn(n)
                nl()
                put("    .cerror * > ")
                puthex(overlay_end)
                put(", \"overlay ")
                putn(n)
                put(" is too large by \", * - ")
                puthex(overlay_end)
                raw(", \" bytes\"")
                put("p8ov_size_")
                putn(n)
                put(" = * - ")
                puthex(overlay_start)
                nl()
                raw("    .else")
                put("    .virtual ")
                puthex(overlay_start)
                nl()
                put("    #p8ov_part_")
                putn(n)
                nl()
                put("p8ov_size_")
                putn(n)
                put(" = * - ")
                puthex(overlay_start)
                nl()
                raw("    .endv")
                raw("    .endif")
            }
        }
        o = main_o
    }

    ; What of a block is in the part being written (cur_overlay: 0 is the main program).
    ; The block itself, with its own assembly and labels, is in the part its %overlay
    ; names; a subroutine that names another part is written there by itself, outside the
    ; block's scope but under its full name, so that it is the same subroutine to
    ; everything that names it.
    ^^ir.Block cur_block = 0        ; the block whose code is being written

    sub block_code(^^ir.Block bl) {
        cur_block = bl
        if bl.overlay != cur_overlay {
            ^^ir.Sub lone = bl.subs
            while lone != 0 {
                if lone.overlay == cur_overlay and parent_of(bl, lone) == 0
                    subroutine(bl, lone, false)
                lone = lone.next
            }
            return
        }
        if true {
            if bl.address != 0 {
                put("* = ")
                put(bl.address)
                nl()
            }
            put(bl.name)
            if bl.force_output
                raw("  .block")
            else
                raw("  .proc")
            ; the block's own chunks (assembly, labels, included files) and its subroutines,
            ; in the order of the source: a layout may count on it
            ^^ir.Chunk c = bl.chunks
            ^^ir.Sub s = bl.subs
            repeat {
                while s != 0 and parent_of(bl, s) != 0
                    s = s.next          ; (a nested one is written with its parent)
                if c == 0 and s == 0
                    break
                if s == 0 or (c != 0 and c.order < s.order) {
                    peep6502.begin(o)
                    if c.label != 0
                        label(c.label)
                    if c.kind == ir.C_ASM
                        asm_text(c.text, c.textlen)
                    else
                        chunk_code(c, 0)
                    peep6502.flush()
                    c = c.next
                }
                else {
                    if s.overlay == cur_overlay
                        subroutine(bl, s, false)
                    s = s.next
                }
            }
            if bl.force_output
                raw("  .bend")
            else
                raw("  .pend")
            raw("")
        }
    }

    sub asm_text(^^ubyte text, long length) {
        if text == 0
            return
        buf.add_bytes(w(), text, length)
        if length == 0 or text[length - 1] != '\n'
            nl()
    }

    ; A subroutine is a .proc, which the assembler leaves out when nothing refers to it;
    ; in a block with %option force_output it is a .block, which is always there (and so
    ; are the names declared in it).
    sub scope_start(^^ir.Block bl) {
        if bl.force_output
            raw("  .block")
        else
            raw("  .proc")
    }

    sub scope_end(^^ir.Block bl) {
        if bl.force_output
            raw("    .bend")
        else
            raw("    .pend")
    }

    sub subroutine(^^ir.Block bl, ^^ir.Sub s, bool nested) {
        crumb.name = s.name
        if s.is_asm {
            ; an asmsub: its assembly, unless it is inlined at every call
            if s.is_inline or s.asmtext == 0 or s.asm_is_ir
                return
            raw("")
            if nested
                put(unscoped(s.name))
            else
                put(s.name)
            scope_start(bl)
            asm_text(s.asmtext, s.asmlen)
            scope_end(bl)
            return
        }
        raw("")
        put("; ---- Subroutine: ")
        put(s.name)
        raw(" ----")
        if nested
            put(unscoped(s.name))
        else
            put(s.name)
        scope_start(bl)
        peep6502.begin(o)
        peep6502.pooling = not s.no_pool
        if not s.reenter
            peep6502.own_scope(s.name)
        cursub = s
        wide_entry_count = 0
        wide_stub_count = 0
        wide_pending = false
        bool widely = wide_enabled and not s.no_pool
        store_register_params(s)
        if strings.compare(s.name, "p8b_main.p8s_start") == 0 {
            ; (also when something calls main.start without the startup code, as a library does)
            ins("jsr", "prog8_lib.program_startup_clear_bss")
            ins("jsr", "run_global_inits")
        }
        ^^ubyte own = unscoped(s.name)
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            ; (the .proc defines the subroutine's own name)
            ^^ubyte clabel = 0
            if c.label != 0 and strings.compare(c.label, s.name) != 0 and strings.compare(c.label, own) != 0
                clabel = c.label
            if widely and c.kind != ir.C_ASM {
                ; (the 65816: the chunk writes its own label, by where the code before it left off)
                fuse_indexed(c)
                wide_chunk(c, clabel)
            }
            else {
                wide_flush()
                if clabel != 0
                    label(clabel)
                if c.kind == ir.C_ASM and c45 and q_scanned_sub == s and q_sub_longs {
                    ; (assembly text may count on Z being zero, and nothing is known of
                    ; how the code that comes here left it)
                    raw("    ldz  #0")
                }
                if c.kind == ir.C_ASM
                    asm_text(c.text, c.textlen)
                else
                    chunk_code(c, s)
            }
            c = c.next
        }
        wide_flush()
        wide_write_stubs()
        peep6502.flush()
        cursub = 0
        ; the subroutines nested in this one
        ^^ir.Sub inner = bl.subs
        while inner != 0 {
            if inner != s and nested_in(inner.name, s.name) and parent_of(bl, inner) == s
                subroutine(bl, inner, true)
            inner = inner.next
        }
        scope_end(bl)
    }

    ; ---- an index through a pointer ----
    ;
    ; pointer[index] with a byte index arrives as: copy the pointer, add the index (a
    ; byte made a word), follow the sum.  When the sum is used for nothing else, the
    ; 6502 does that in one step, (pointer),y: the copy and the addition are dropped
    ; and the load or store gets the index register (scale 255 marks it).

    ^^ubyte reg_uses = 0            ; how many times each register is named in the program (255: or more)
    ^^ubyte reg_zext = 0            ; 1: it is a byte made a word with zeros above

    sub note_register(uword r) {
        if r != 0 and r <= ir.regcount and reg_uses[r] != 255
            reg_uses[r]++
    }

    sub count_chunks(^^ir.Chunk c) {
        while c != 0 {
            if c.kind != ir.C_ASM {
                ^^ir.Instr i = c.first
                while i != 0 {
                    note_register(i.r1)
                    note_register(i.r2)
                    note_register(i.r3)
                    ^^ir.Arg a = i.args
                    while a != 0 {
                        note_register(a.reg)
                        a = a.next
                    }
                    a = i.results
                    while a != 0 {
                        note_register(a.reg)
                        a = a.next
                    }
                    if i.r1 != 0 and i.r1 <= ir.regcount {
                        if i.op == ir.OP_LOADMZ or (i.op == ir.OP_EXT and i.type == ir.T_BYTE)
                            reg_zext[i.r1] = 1
                    }
                    i = i.next
                }
            }
            c = c.next
        }
    }

    sub count_registers() {
        reg_uses = mem.alloc((ir.regcount as long) + 2)
        reg_zext = mem.alloc((ir.regcount as long) + 2)
        count_chunks(prog.initglobals)
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            count_chunks(bl.chunks)
            ^^ir.Sub sb = bl.subs
            while sb != 0 {
                count_chunks(sb.chunks)
                sb = sb.next
            }
            bl = bl.next
        }
    }

    sub fuse_indexed(^^ir.Chunk c) {
        if types.far_bits != 0 {
            ; (a chunk with an instruction on far memory is left as it is: the patterns
            ; here are written for memory that an instruction names directly)
            ^^ir.Instr fi = c.first
            while fi != 0 {
                if far_operand(fi)
                    return
                fi = fi.next
            }
        }
        fuse_floats(c)
        ^^ir.Instr a = c.first
        while a != 0 {
            ^^ir.Instr b = a.next
            mark_ay_chain(a)
            if a.scale == 251 or a.scale == 252 {
                a = a.next
                continue
            }
            if a.op == ir.OP_INC and a.r1 != 0 and (a.type == ir.T_POINTER or a.type == ir.T_WORD) {
                ; (pointer + 1 is written as an increment: the same thing)
                a.op = ir.OP_ADD
                a.mode = ir.M_RI
                a.value = 1
            }
            if a.op == ir.OP_ADD and a.mode == ir.M_RI and a.r1 != 0 and a.r1 <= ir.regcount and reg_uses[a.r1] == 3
                    and a.value >= 0 and a.value < 250 and (a.type == ir.T_POINTER or a.type == ir.T_WORD) {
                ; pointer + constant, followed only: the constant becomes the displacement
                ^^ir.Instr u = b
                ubyte steps = 0
                while u != 0 and steps < 8 {
                    if (u.op == ir.OP_LOADI or u.op == ir.OP_STOREI or u.op == ir.OP_STOREZI) and u.r2 == a.r1 and u.r1 != a.r1 and u.scale != 255 {
                        if u.offset >= 0 and u.offset + (a.value as long) + type_size(u.type) <= 256 {
                            u.offset += a.value as long
                            a.op = ir.OP_NOP
                            reg_uses[a.r1] = 2
                        }
                        break
                    }
                    if u.r1 == a.r1 or u.r2 == a.r1 or u.r3 == a.r1 or u.args != 0
                        break
                    u = u.next
                    steps++
                }
            }
            if b != 0 and b.next != 0 and a.op == ir.OP_LOADR and b.op == ir.OP_ADDR and b.r1 == a.r1 and b.mode == ir.M_RR {
                ^^ir.Instr d = b.next
                if (d.op == ir.OP_LOADI or d.op == ir.OP_STOREI or d.op == ir.OP_STOREZI) and d.r2 == a.r1 and d.offset == 0
                        and d.scale != 255 and type_size(d.type) == 1 and a.r1 <= ir.regcount and b.r2 <= ir.regcount
                        and reg_uses[a.r1] == 3 and reg_zext[b.r2] == 1 and reg_uses[b.r2] == 2 {
                    a.op = ir.OP_NOP
                    b.op = ir.OP_NOP
                    d.r2 = a.r2
                    d.r3 = b.r2
                    d.scale = 255
                }
            }
            if b != 0 and a.op == ir.OP_LOADI and type_size(a.type) == 1 and a.r1 != 0 and a.r1 <= ir.regcount and reg_uses[a.r1] == 2
                    and (b.op == ir.OP_ADDR or b.op == ir.OP_SUBR or b.op == ir.OP_ANDR or b.op == ir.OP_ORR or b.op == ir.OP_XORR)
                    and b.mode == ir.M_RR and type_size(b.type) == 1 and b.r2 == a.r1 and b.r1 != a.r1 and b.r1 != a.r2 and b.r1 != a.r3
                    and a.offset >= 0 and a.offset <= 255 {
                ; a byte through a pointer that is only an operand: the operation takes it from there
                b.r2 = a.r2
                b.r3 = a.r3
                b.offset = a.offset
                b.scale = 254
                if a.scale == 255
                    b.scale = 253
                a.op = ir.OP_NOP
            }
            if b != 0 and b.next != 0 and a.op == ir.OP_LOADM and b.op == ir.OP_LOADM and type_size(a.type) == 2 and type_size(b.type) == 2
                    and a.sym == b.sym and a.offset == b.offset and a.value == b.value and a.r1 != b.r1
                    and b.r1 <= ir.regcount and reg_uses[b.r1] == 2 {
                ; a word variable times itself
                ^^ir.Instr sq = b.next
                if (sq.op == ir.OP_MULR or sq.op == ir.OP_MULSR) and sq.mode == ir.M_RR and sq.r1 == a.r1 and sq.r2 == b.r1
                        and type_size(sq.type) == 2 {
                    b.op = ir.OP_NOP
                    sq.r2 = 0
                    sq.scale = 250
                }
            }
            if b != 0 and b.next != 0 and b.next.next != 0 and a.op == ir.OP_LOADX and b.op == ir.OP_LOADX
                    and type_size(a.type) == 1 and type_size(b.type) == 1 and a.r1 != b.r1 and a.r1 <= ir.regcount and b.r1 <= ir.regcount
                    and reg_uses[a.r1] == 2 and reg_uses[b.r1] == 2 and a.r2 != a.r1 and b.r2 != a.r1 {
                ; A word from a split array that is only stored in a variable:
                ;     loadx high / loadx low / concat word,high,low / storem word
                ; Each half goes straight to its place.
                ^^ir.Instr cc = b.next
                ^^ir.Instr st = cc.next
                if cc.op == ir.OP_CONCAT and cc.r2 == a.r1 and cc.r3 == b.r1 and cc.r1 <= ir.regcount and reg_uses[cc.r1] == 2
                        and st.op == ir.OP_STOREM and st.r1 == cc.r1 and type_size(st.type) == 2 and st.scale < 250 {
                    ; (cc becomes the load of the low half, b and st the two stores)
                    cc.op = b.op
                    cc.type = b.type
                    cc.t1 = b.t1
                    cc.t2 = b.t2
                    cc.t3 = b.t3
                    cc.mode = b.mode
                    cc.scale = b.scale
                    cc.sym = b.sym
                    cc.offset = b.offset
                    cc.value = b.value
                    cc.r1 = b.r1
                    cc.r2 = b.r2
                    cc.r3 = b.r3
                    b.op = ir.OP_STOREM
                    b.type = ir.T_BYTE
                    b.t1 = st.t1
                    b.t2 = st.t2
                    b.t3 = st.t3
                    b.mode = st.mode
                    b.scale = st.scale
                    b.sym = st.sym
                    b.offset = st.offset + 1
                    b.value = st.value
                    b.r1 = a.r1
                    b.r2 = 0
                    b.r3 = 0
                    st.type = ir.T_BYTE
                    st.r1 = cc.r1
                }
            }
            if b != 0 and b.next != 0 and a.op == ir.OP_LOAD and a.sym == 0 and a.r1 != 0 and a.r1 <= ir.regcount
                    and (b.op == ir.OP_LOADMZ or b.op == ir.OP_LOADM) and b.r1 != a.r1 and b.r1 <= ir.regcount and reg_uses[b.r1] == 2 {
                ; constant * variable, the constant first: the variable times the constant,
                ; which is shifts and additions when the constant has few bits
                ^^ir.Instr m = b.next
                if m.op == ir.OP_MULR and m.mode == ir.M_RR and m.r1 == a.r1 and m.r2 == b.r1 and type_size(m.type) <= 2
                        and (b.op == ir.OP_LOADMZ or b.type == m.type) and (b.op == ir.OP_LOADM or type_size(m.type) == 2)
                        and shift_add_cost(a.value, type_size(m.type)) <= 180 {
                    b.r1 = a.r1
                    a.op = ir.OP_NOP
                    m.op = ir.OP_MUL
                    m.mode = ir.M_RI
                    m.value = a.value
                    m.r2 = 0
                }
            }
            if b != 0 and a.op == ir.OP_ADDR and a.mode == ir.M_RR and a.r1 != a.r2 and a.r1 <= ir.regcount and a.r2 <= ir.regcount
                    and (b.op == ir.OP_LOADI or b.op == ir.OP_STOREI or b.op == ir.OP_STOREZI) and b.r2 == a.r1 and b.r1 != a.r1
                    and b.offset == 0 and b.scale != 255 and type_size(b.type) == 1
                    and reg_uses[a.r1] == 3 and reg_zext[a.r2] == 1 and reg_uses[a.r2] == 2 {
                ; a pointer (from anywhere: a variable, most often) + a byte, followed only:
                ; the byte is the index
                a.op = ir.OP_NOP
                b.r3 = a.r2
                b.scale = 255
            }
            a = a.next
        }
    }

    sub chunk_code(^^ir.Chunk c, ^^ir.Sub s) {
        if c == 0
            return
        fuse_indexed(c)
        if wide_enabled and (s == 0 or not s.no_pool) {
            ; (a subroutine's chunks come by way of subroutine(), which has their labels)
            wide_chunk(c, 0)
            wide_flush()
            return
        }
        ^^ir.Instr i = c.first
        if c45 {
            quad_chunk(c)
            q_index = 0
            while i != 0 {
                instruction(i)
                i = i.next
                q_index++
            }
            q_flush()
            if s == 0
                z_restore()         ; (the code of the globals' initial values is followed by other code)
            return
        }
        while i != 0 {
            instruction(i)
            i = i.next
        }
    }

    ; ---- the 65816: word arithmetic in the 16-bit accumulator ----
    ;
    ; A run of consecutive IR instructions on words is written for the 16-bit
    ; accumulator, between one "rep #$20" and one "sep #$20".  That needs the
    ; 65816's native mode.  Where the machine's ROM is written for it (the
    ; target's native65816 = rest: the Commander X16) the whole program runs
    ; in native mode with 8-bit registers, which is what the 6502 code here
    ; and the library's assembly expect, and the entry code switches to it
    ; around main.start.  Elsewhere the program stays in emulation mode and
    ; each run switches for itself (the C64's ROM divides floats wrongly in
    ; native mode).  About a run:
    ; - the run names no virtual register that is also named outside it, so
    ;   nothing has to pass through the byte cells of the 8-bit code;
    ; - a register that is loaded from a variable is that variable until it is
    ;   changed, one that is loaded with a number is that number, and one value
    ;   at a time is in the accumulator; a second one that is still needed waits
    ;   in one of the two scratch words;
    ; - a run that would need more than that is written as 8-bit code after all.
    ; The peephole passes take the run for text: they know nothing across it.
    ; Not in a subroutine that may run from an interrupt: the machine's ROM
    ; calls those in emulation mode, where there are no 16 bits.

    bool wide_enabled = false
    bool wide_rest = false          ; the program stays in native mode (the target's native65816 = rest)
    ^^pointer whome = 0             ; per virtual register: the chunk that names it, or MANY
    ^^long wfirst = 0               ; the first and last instruction of that chunk that names it
    ^^long wlast = 0
    ^^ubyte wkind = 0               ; in a run: where its value is (W_...)
    ^^pointer wsrc = 0              ; W_ALIAS, W_CONST: the instruction that loaded it
    long wcap = 0
    ^^buf.Buf wb = 0                ; the text of the run being tried
    bool wfail = false
    uword wacc = 0                  ; the register whose value the accumulator holds, or 0
    ^^ir.Instr wmirror = 0          ; the accumulator's value is also in this instruction's memory operand, or 0
    bool w1_used = false
    bool w2_used = false
    ^^ir.Chunk wchunk = 0
    uword[64] waliases              ; the registers that are a variable, in this run
    ubyte walias_count = 0
    const ubyte W_ACC = 0           ; in the accumulator (or nowhere yet)
    const ubyte W_ALIAS = 1         ; the variable it was loaded from
    const ubyte W_CONST = 2         ; a number or an address
    const ubyte W_S1 = 3            ; a scratch word
    const ubyte W_S2 = 4
    const long MANY = 1

    sub wide_note(uword r, ^^ir.Chunk c) {
        if r == 0 or r >= wcap
            return
        pointer here = c
        if whome[r] == 0
            whome[r] = here
        else if whome[r] != here
            whome[r] = MANY
    }

    sub wide_note_chunk(^^ir.Chunk c) {
        while c != 0 {
            ^^ir.Instr i = c.first
            while i != 0 {
                wide_note(i.r1, c)
                wide_note(i.r2, c)
                wide_note(i.r3, c)
                ^^ir.Arg a = i.args
                while a != 0 {
                    wide_note(a.reg, c)
                    a = a.next
                }
                a = i.results
                while a != 0 {
                    wide_note(a.reg, c)
                    a = a.next
                }
                i = i.next
            }
            c = c.next
        }
    }

    ; which chunk names each virtual register, over the whole program
    sub wide_prepare() {
        wide_enabled = false
        bool wide_wanted = c816 and io_platform.env("P8P8_NOWIDE") == 0 and find_sub("p8b_main.p8s_start") != 0
        ; (the 45GS02's 32-bit code wants to know where a register is used too)
        if not wide_wanted and not c45
            return
        wide_enabled = wide_wanted
        wide_done = 0
        wide_total = 0
        sys.memset(&wide_missed, sizeof(long) * 256, 0)
        wide_rest = target.is("native65816", "rest") and io_platform.env("P8P8_NATIVE_RUN") == 0
        long needed = ir.regcount as long + 1
        if needed > wcap {
            whome = mem.alloc(needed * sizeof(pointer))
            wsrc = mem.alloc(needed * sizeof(pointer))
            wfirst = mem.alloc(needed * 4)
            wlast = mem.alloc(needed * 4)
            wkind = mem.alloc(needed)
            wcap = needed
        }
        long k
        for k in 0 to wcap - 1
            whome[k] = 0
        if wb == 0
            wb = buf.new(4096)
        wide_note_chunk(prog.initglobals)
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                wide_note_chunk(s.chunks)
                s = s.next
            }
            bl = bl.next
        }
    }

    sub is_word(ubyte t) -> bool {
        return t == ir.T_WORD or t == ir.T_POINTER
    }

    ; can the instruction be part of a 16-bit run?  0: no, 1: yes, 2: yes, and the run ends
    ; with it (a comparison), 3: the same, a comparison that branches itself
    sub wide_ok(^^ir.Instr i) -> ubyte {
        if not is_word(i.type) or i.scale >= 251
            return 0
        if far_operand(i)
            return 0
        when i.op {
            ir.OP_LOADM, ir.OP_STOREM, ir.OP_STOREZM, ir.OP_STOREIM, ir.OP_LOAD, ir.OP_LOADR,
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_ANDR, ir.OP_ORR, ir.OP_XORR,
            ir.OP_ADD, ir.OP_SUB, ir.OP_AND, ir.OP_OR, ir.OP_XOR,
            ir.OP_ADDM, ir.OP_SUBM, ir.OP_ANDM, ir.OP_ORM, ir.OP_XORM, ir.OP_ADDIM, ir.OP_SUBIM,
            ir.OP_INCM, ir.OP_DECM, ir.OP_INC, ir.OP_DEC, ir.OP_LSL, ir.OP_LSR, ir.OP_LSLM, ir.OP_LSRM,
            ir.OP_NEG, ir.OP_INV -> return 1
            ir.OP_LSLI, ir.OP_LSRI -> {
                if i.value >= 1 and i.value <= 15
                    return 1
                return 0
            }
            ir.OP_CMP, ir.OP_CMPI -> return 2
            ir.OP_BGT, ir.OP_BGTR, ir.OP_BLT, ir.OP_BGE, ir.OP_BGER, ir.OP_BLE,
            ir.OP_BGTS, ir.OP_BGTSR, ir.OP_BLTS, ir.OP_BGES, ir.OP_BGESR, ir.OP_BLES -> return 3
        }
        return 0
    }

    sub wide_index_reg(uword r, long index) {
        if r == 0 or r >= wcap
            return
        pointer here = wchunk
        if whome[r] != here
            return
        if wfirst[r] < 0
            wfirst[r] = index
        wlast[r] = index
    }

    sub wide_reset_reg(uword r) {
        if r != 0 and r < wcap
            wfirst[r] = -1
    }

    ; is register r named only inside instructions first .. last of this chunk
    sub wide_inside(uword r, long first, long last) -> bool {
        if r == 0
            return true
        if r >= wcap
            return false
        pointer here = wchunk
        return whome[r] == here and wfirst[r] >= first and wlast[r] <= last
    }

    long wide_done = 0
    long wide_total = 0
    long[256] wide_missed           ; per opcode: the word instructions that were written 8 bits wide

    sub wide_chunk(^^ir.Chunk c, ^^ubyte lbl) {
        wchunk = c
        ^^ir.Instr i = c.first
        long index = 0
        while i != 0 {
            if is_word(i.type)
                wide_total++
            wide_reset_reg(i.r1)
            wide_reset_reg(i.r2)
            wide_reset_reg(i.r3)
            ^^ir.Arg ra = i.args
            while ra != 0 {
                wide_reset_reg(ra.reg)
                ra = ra.next
            }
            ra = i.results
            while ra != 0 {
                wide_reset_reg(ra.reg)
                ra = ra.next
            }
            i = i.next
        }
        i = c.first
        ^^ir.Arg a
        while i != 0 {
            wide_index_reg(i.r1, index)
            wide_index_reg(i.r2, index)
            wide_index_reg(i.r3, index)
            ; (a call names registers too: its arguments and results)
            a = i.args
            while a != 0 {
                wide_index_reg(a.reg, index)
                a = a.next
            }
            a = i.results
            while a != 0 {
                wide_index_reg(a.reg, index)
                a = a.next
            }
            index++
            i = i.next
        }
        i = c.first
        index = 0
        ; the start of the chunk: its label, and whether what came before is 16 bits wide still
        long length = 0
        if i != 0
            length = wide_length(i, 0)
        if length != 0 and not wide_try(i, 0, length)
            length = 0
        if wide_pending and length != 0 and win_count != 0
            wide_close(false)       ; (what comes into the run is fetched 8 bits wide)
        if wide_pending {
            if length != 0 {
                ; The run before fell through to here and this chunk begins with a run:
                ; the accumulator stays as it is.  Whoever else jumps to the label comes
                ; in 8 bits wide, by a few lines after the subroutine's end.
                if lbl != 0 {
                    wide_stub(lbl)
                    wide_entry_label(lbl)
                }
            }
            else {
                wide_close(false)
                if lbl != 0
                    label(lbl)
            }
        }
        else {
            if lbl != 0
                label(lbl)
            if length != 0 {
                wide_enter()
                if lbl != 0 and win_count == 0
                    wide_entry_label(lbl)
            }
        }
        if length != 0 {
            length = wide_finish(i, length)
            wide_done += length
            repeat length
                i = i.next
            index += length
        }
        while i != 0 {
            length = wide_length(i, index)
            if length != 0 and wide_try(i, index, length) {
                wide_enter()
                length = wide_finish(i, length)
                wide_done += length
                repeat length
                    i = i.next
                index += length
                continue
            }
            if is_word(i.type)
                wide_missed[i.op]++
            instruction(i)
            i = i.next
            index++
        }
    }

    ; the length of the run that can begin at instruction i (at index of the chunk): at
    ; least three instructions that name no register which is named outside them, or 0
    sub wide_length(^^ir.Instr i, long index) -> long {
        if wide_ok(i) == 0
            return 0
        long length = 0
        ^^ir.Instr j = i
        while j != 0 {
            ubyte ok = wide_ok(j)
            if ok == 0
                break
            length++
            j = j.next
            if ok >= 2
                break
        }
        while length >= 3 {
            ; (a load at the end does nothing that the 8-bit code after it would not do)
            j = i
            repeat length - 1
                j = j.next
            if j.op == ir.OP_LOADM or j.op == ir.OP_LOAD or j.op == ir.OP_LOADR {
                length--
                continue
            }
            ; every value that comes in or goes out costs about what an instruction gains
            if wide_classify(i, index, length) and length >= 3 + win_count + wout_count
                    and (wout_count == 0 or wide_ok(j) == 1)
                return length
            length--
        }
        win_count = 0
        wout_count = 0
        return 0
    }

    ; The registers of a run that are not its own: those that come into it with a value
    ; (win) and those whose value is needed after it (wout).  Outside a run every byte
    ; of a register is in a cell of its own, so they are carried over in 8-bit code
    ; before and after the run.
    uword[3] win
    ubyte[3] win_kind               ; W_ACC, W_S1 or W_S2: where the run finds it
    ubyte win_count = 0
    uword[3] wout
    ubyte[3] wout_kind              ; where the run leaves it
    ubyte wout_count = 0
    uword[24] wseen
    bool[24] wseen_written
    long[24] wseen_last
    ubyte wseen_count = 0

    sub wide_seen(uword r, bool defined, bool written, long index) -> bool {
        if r == 0
            return true
        if r >= wcap
            return false
        ubyte k = 0
        while k < wseen_count {
            if wseen[k] == r
                break
            k++
        }
        if k == wseen_count {
            if k == len(wseen)
                return false
            wseen[k] = r
            wseen_written[k] = false
            wseen_count++
            if not defined {
                ; it has a value from before the run
                if win_count == len(win)
                    return false
                win[win_count] = r
                win_count++
            }
        }
        if written
            wseen_written[k] = true
        wseen_last[k] = index
        return true
    }

    ; fills win and wout for the run of length instructions from i; false: not such a run
    sub wide_classify(^^ir.Instr i, long index, long length) -> bool {
        win_count = 0
        wout_count = 0
        wseen_count = 0
        pointer here = wchunk
        long last = index + length - 1
        ^^ir.Instr j = i
        long k
        for k in 0 to length - 1 {
            if j.r3 != 0
                return false
            bool defined = false
            bool written = true
            when j.op {
                ir.OP_LOADM, ir.OP_LOAD, ir.OP_LOADR -> defined = true
                ir.OP_STOREM, ir.OP_CMP, ir.OP_CMPI -> written = false
                else -> {
                    if wide_ok(j) == 3
                        written = false
                }
            }
            if not wide_seen(j.r2, false, false, index + k) or not wide_seen(j.r1, defined, written, index + k)
                return false
            j = j.next
        }
        ubyte n
        for n in 0 to wseen_count - 1 {
            uword r = wseen[n]
            bool foreign = whome[r] != here
            if wseen_written[n] and (foreign or wlast[r] > last) {
                if wout_count == len(wout)
                    return false
                wout[wout_count] = r
                wout_count++
            }
            if foreign {
                ; (named in other chunks as well: for this run, how long it is needed in it)
                wlast[r] = wseen_last[n]
                if wseen_written[n]
                    wlast[r] = last + 1
            }
        }
        ; where the values that come in are: the one the first instruction works on in the
        ; accumulator, the others in the scratch words
        uword first = 0
        ubyte scratch = W_S1
        for n in 0 to 2 {
            if n < win_count {
                if not defined_by(i) and win[n] == i.r1
                    first = i.r1
            }
        }
        if first == 0 {
            for n in 0 to 2 {
                if n < win_count and win[n] == i.r2
                    first = i.r2
            }
        }
        for n in 0 to 2 {
            if n < win_count {
                if whome[win[n]] == here and wfirst[win[n]] >= index
                    return false            ; (used before it has a value?)
                if win[n] == first
                    win_kind[n] = W_ACC
                else {
                    if scratch == 0
                        return false
                    win_kind[n] = scratch
                    if scratch == W_S1
                        scratch = W_S2
                    else
                        scratch = 0
                }
            }
        }
        return true
    }

    sub defined_by(^^ir.Instr i) -> bool {
        return i.op == ir.OP_LOADM or i.op == ir.OP_LOAD or i.op == ir.OP_LOADR
    }

    ; The 8-bit code before a run: the values that come into it, from the cells of their
    ; registers into the scratch words and (last) both halves of the accumulator.
    sub wide_enter() {
        fac_reg = 0
        ubyte n
        for n in 0 to 2 {
            if n < win_count and win_kind[n] != W_ACC {
                ^^ubyte lowname = "P8ZP_SCRATCH_W1"
                ^^ubyte high = "P8ZP_SCRATCH_W1+1"
                if win_kind[n] == W_S2 {
                    lowname = "P8ZP_SCRATCH_W2"
                    high = "P8ZP_SCRATCH_W2+1"
                }
                lda_reg(win[n], 0)
                ins("sta", lowname)
                lda_reg(win[n], 1)
                ins("sta", high)
            }
        }
        for n in 0 to 2 {
            if n < win_count and win_kind[n] == W_ACC {
                lda_reg(win[n], 1)
                raw("    xba")
                lda_reg(win[n], 0)
            }
        }
        wide_open()
    }

    ; and the 8-bit code after it: the values that go out, into the cells
    sub wide_leave() {
        ubyte n
        for n in 0 to 2 {
            if n < wout_count and wout_kind[n] == W_ACC {
                ins("sta", cell(wout[n], 0))
                raw("    xba")
                ins("sta", cell(wout[n], 1))
            }
        }
        for n in 0 to 2 {
            if n < wout_count and wout_kind[n] != W_ACC {
                if wout_kind[n] == W_S1 {
                    ins("lda", "P8ZP_SCRATCH_W1")
                    ins("sta", cell(wout[n], 0))
                    ins("lda", "P8ZP_SCRATCH_W1+1")
                    ins("sta", cell(wout[n], 1))
                }
                else {
                    ins("lda", "P8ZP_SCRATCH_W2")
                    ins("sta", cell(wout[n], 0))
                    ins("lda", "P8ZP_SCRATCH_W2+1")
                    ins("sta", cell(wout[n], 1))
                }
            }
        }
    }

    ; Where one run ends and the next begins with nothing in between (the label
    ; that stood there was not needed), the accumulator stays 16 bits wide.
    sub join_runs(^^buf.Buf b) {
        ^^ubyte seam = "    sep  #$20\n    .as\n    rep  #$20\n    .al\n"
        if not wide_rest
            seam = "    sep  #$20\n    .as\n    sec\n    xce\n    clc\n    xce\n    rep  #$20\n    .al\n"
        long n = buf.cstr_len(seam)
        long from = 0
        long dst = 0
        while from < b.len {
            if b.data[from] == ' ' and from + n <= b.len and buf.bytes_equal(b.data + from, seam, n)
                from += n
            else {
                b.data[dst] = b.data[from]
                dst++
                from++
            }
        }
        b.len = dst
    }

    ; ---- writing a run ----

    sub wl(str text) {
        buf.add_str(wb, "    ")
        buf.add_str(wb, text)
        buf.add_byte(wb, '\n')
    }

    ; the memory operand of instruction m
    sub wmem_text(^^ir.Instr m) {
        wstore_at = -1
        memory_operand(m)
        buf.add_str(wb, mem_symbol)
        if mem_offset > 0 {
            buf.add_byte(wb, '+')
            buf.add_long(wb, mem_offset)
        }
        else if mem_offset < 0
            buf.add_long(wb, mem_offset)
    }

    ; "    mnemonic  memory"
    sub wmem(str mnemonic, ^^ir.Instr m) {
        buf.add_str(wb, "    ")
        buf.add_str(wb, mnemonic)
        buf.add_str(wb, "  ")
        wmem_text(m)
        buf.add_byte(wb, '\n')
    }

    ; the accumulator into the memory operand of m, which it then equals
    sub wsta(^^ir.Instr m) {
        if wstore_at >= 0 and wide_exact(wstore_m, m) {
            ; nothing has named memory since the last store to this variable: that one goes
            long from = wstore_at
            while wb.data[from] != '\n'
                from++
            from++
            long to_ = wstore_at
            while from < wb.len {
                wb.data[to_] = wb.data[from]
                to_++
                from++
            }
            wb.len = to_
        }
        long at = wb.len
        wmem("sta", m)
        wmirror = m
        if m.sym != 0 and peep6502.scanned(m.sym).mark & peep6502.K_PLAIN != 0 {
            wstore_at = at
            wstore_m = m
        }
    }

    long wstore_at = -1             ; where in wb the last store to a plain variable is, while nothing has named memory since
    ^^ir.Instr wstore_m = 0

    ; "    mnemonic  #number"
    sub wimm(str mnemonic, quad value) {
        buf.add_str(wb, "    ")
        buf.add_str(wb, mnemonic)
        buf.add_str(wb, "  #")
        buf.add_long(wb, (value & $ffff) as long)
        buf.add_byte(wb, '\n')
    }

    ; "    mnemonic  operand", the operand being where register r's value is (not the accumulator)
    sub wop(str mnemonic, uword r) {
        buf.add_str(wb, "    ")
        buf.add_str(wb, mnemonic)
        buf.add_str(wb, "  ")
        ^^ir.Instr src
        when wkind[r] {
            W_ALIAS -> {
                src = wsrc[r]
                wmem_text(src)
            }
            W_CONST -> {
                src = wsrc[r]
                buf.add_byte(wb, '#')
                if src.sym != 0 {
                    buf.add_str(wb, src.sym)
                    if src.offset > 0 {
                        buf.add_byte(wb, '+')
                        buf.add_long(wb, src.offset)
                    }
                    else if src.offset < 0
                        buf.add_long(wb, src.offset)
                }
                else
                    buf.add_long(wb, (src.value & $ffff) as long)
            }
            W_S1 -> buf.add_str(wb, "P8ZP_SCRATCH_W1")
            W_S2 -> buf.add_str(wb, "P8ZP_SCRATCH_W2")
            else -> wfail = true
        }
        buf.add_byte(wb, '\n')
    }

    sub wide_release(uword r) {
        when wkind[r] {
            W_S1 -> w1_used = false
            W_S2 -> w2_used = false
        }
    }

    ; the value in the accumulator is put aside, when it is needed after instruction index
    sub wide_save(long index) {
        if wacc == 0
            return
        if wlast[wacc] > index
            wide_spill()
        wacc = 0
    }

    ; the accumulator's value into a scratch word; it stays in the accumulator too
    sub wide_spill() {
        if not w1_used {
            w1_used = true
            wl("sta  P8ZP_SCRATCH_W1")
            wkind[wacc] = W_S1
        }
        else if not w2_used {
            w2_used = true
            wl("sta  P8ZP_SCRATCH_W2")
            wkind[wacc] = W_S2
        }
        else
            wfail = true
    }

    ; register r's value into the accumulator (what was there is put aside when needed)
    sub wide_load(uword r, long index) {
        if wacc == r
            return
        wide_save(index - 1)
        ^^ir.Instr from = wsrc[r]
        if wkind[r] == W_ALIAS and wmirror != 0 and wide_exact(from, wmirror) {
            ; (it is the variable that was just stored from, or loaded into, the accumulator)
        }
        else {
            wop("lda", r)
            wmirror = 0
            if wkind[r] == W_ALIAS
                wmirror = from
        }
        if wlast[r] <= index
            wide_release(r)
        ; (it keeps its other place as well, as long as it is not changed)
        wacc = r
    }

    ; register r is about to be changed in the accumulator: it has no other place any more
    sub wide_own(uword r) {
        wide_release(r)
        wkind[r] = W_ACC
        wmirror = 0
    }

    ; are the two memory operands the very same place
    sub wide_exact(^^ir.Instr a, ^^ir.Instr b) -> bool {
        return a.sym == b.sym and a.offset == b.offset
    }

    ; do the two memory operands name the same variable (any part of it)
    sub wide_same(^^ir.Instr a, ^^ir.Instr b) -> bool {
        if a.sym != 0 or b.sym != 0
            return a.sym == b.sym
        return a.offset == b.offset
    }

    ; instruction m (at index) writes its memory operand: no register that is still
    ; needed may be that variable
    sub wide_written(^^ir.Instr m, long index) {
        if wmirror != 0 and wide_same(wmirror, m)
            wmirror = 0
        ubyte k = 0
        while k < walias_count {
            uword r = waliases[k]
            if wkind[r] == W_ALIAS and wlast[r] > index {
                ^^ir.Instr src = wsrc[r]
                if wide_same(src, m)
                    wfail = true
            }
            k++
        }
    }

    ; the accumulator (register r) with the value of register x: "    mnemonic  x"
    sub wide_binary(^^ir.Instr i, long index, str mnemonic, bool commutes, ubyte carry) {
        uword r1 = i.r1
        uword r2 = i.r2
        if wacc == r2 and r1 != r2 {
            ; the second operand is the one in the accumulator
            if not commutes or wlast[r2] > index {
                wide_spill()
                if wfail
                    return
            }
            if commutes {
                when carry {
                    1 -> wl("clc")
                    2 -> wl("sec")
                }
                wop(mnemonic, r1)
            }
            else {
                ubyte where = wkind[r2]
                wop("lda", r1)
                wmirror = 0
                when carry {
                    1 -> wl("clc")
                    2 -> wl("sec")
                }
                wop(mnemonic, r2)
                if wlast[r2] <= index {
                    wide_release(r2)
                    wkind[r2] = W_ACC
                }
            }
            if commutes and wlast[r2] <= index
                wide_release(r2)
            wide_own(r1)
            wacc = r1
            return
        }
        wide_load(r1, index)
        wide_own(r1)
        when carry {
            1 -> wl("clc")
            2 -> wl("sec")
        }
        if r1 == r2 {
            ; (with itself: it is only in the accumulator now)
            wl("sta  P8ZP_SCRATCH_REG")
            wfail = true
            return
        }
        wop(mnemonic, r2)
        if wlast[r2] <= index
            wide_release(r2)
    }

    ; memory = memory <operation> register r1, for an operation that commutes
    sub wide_memory(^^ir.Instr i, long index, str mnemonic, ubyte carry) {
        uword r = i.r1
        wide_written(i, index)
        if wacc == r {
            if wlast[r] > index
                wide_spill()
        }
        else {
            wide_save(index - 1)
            wmem("lda", i)
            wmirror = 0
            wacc = 0
            when carry {
                1 -> wl("clc")
                2 -> wl("sec")
            }
            wop(mnemonic, r)
            if wlast[r] <= index
                wide_release(r)
            wsta(i)
            return
        }
        when carry {
            1 -> wl("clc")
            2 -> wl("sec")
        }
        wmem(mnemonic, i)
        wsta(i)
        wacc = 0
    }

    sub wide_instruction(^^ir.Instr i, long index) {
        uword r = i.r1
        long k
        when i.op {
            ir.OP_LOADM -> {
                if i.sym != 0 and peep6502.scanned(i.sym).mark & peep6502.K_PLAIN != 0 and walias_count < len(waliases) {
                    ; a plain variable: the register is the variable, until one of them changes
                    wkind[r] = W_ALIAS
                    wsrc[r] = i
                    waliases[walias_count] = r
                    walias_count++
                }
                else {
                    ; (anything else is read now, and once)
                    wide_save(index - 1)
                    wmem("lda", i)
                    wmirror = 0
                    wkind[r] = W_ACC
                    wacc = r
                }
            }
            ir.OP_LOAD -> {
                wkind[r] = W_CONST
                wsrc[r] = i
            }
            ir.OP_LOADR -> {
                uword from = i.r2
                if wacc == from {
                    if wlast[from] > index
                        wide_spill()
                    wkind[r] = W_ACC
                    wacc = r
                }
                else if wkind[from] == W_ALIAS or wkind[from] == W_CONST {
                    wkind[r] = wkind[from]
                    wsrc[r] = wsrc[from]
                    if wkind[r] == W_ALIAS {
                        if walias_count < len(waliases) {
                            waliases[walias_count] = r
                            walias_count++
                        }
                        else
                            wfail = true
                    }
                }
                else {
                    wide_save(index - 1)
                    wop("lda", from)
                    wmirror = 0
                    if wlast[from] <= index
                        wide_release(from)
                    wkind[r] = W_ACC
                    wacc = r
                }
            }
            ir.OP_STOREM -> {
                if wkind[r] == W_ALIAS and wacc != r {
                    ^^ir.Instr same = wsrc[r]
                    if wide_exact(same, i)
                        return              ; (the variable into itself)
                }
                wide_written(i, index)
                if wkind[r] == W_CONST and wacc != r {
                    ^^ir.Instr number = wsrc[r]
                    if number.sym == 0 and number.value & $ffff == 0 {
                        wmem("stz", i)
                        return
                    }
                }
                wide_load(r, index)
                wsta(i)
            }
            ir.OP_STOREZM -> {
                wide_written(i, index)
                wmem("stz", i)
            }
            ir.OP_STOREIM -> {
                wide_written(i, index)
                if i.value & $ffff == 0
                    wmem("stz", i)
                else {
                    wide_save(index - 1)
                    wimm("lda", i.value)
                    wsta(i)
                    wacc = 0
                }
            }
            ir.OP_ADDR -> wide_binary(i, index, "adc", true, 1)
            ir.OP_SUBR -> wide_binary(i, index, "sbc", false, 2)
            ir.OP_ANDR -> wide_binary(i, index, "and", true, 0)
            ir.OP_ORR -> wide_binary(i, index, "ora", true, 0)
            ir.OP_XORR -> wide_binary(i, index, "eor", true, 0)
            ir.OP_ADD -> {
                wide_load(r, index)
                wide_own(r)
                wl("clc")
                wimm("adc", i.value)
            }
            ir.OP_SUB -> {
                wide_load(r, index)
                wide_own(r)
                wl("sec")
                wimm("sbc", i.value)
            }
            ir.OP_AND -> {
                wide_load(r, index)
                wide_own(r)
                wimm("and", i.value)
            }
            ir.OP_OR -> {
                wide_load(r, index)
                wide_own(r)
                wimm("ora", i.value)
            }
            ir.OP_XOR -> {
                wide_load(r, index)
                wide_own(r)
                wimm("eor", i.value)
            }
            ir.OP_ADDM -> wide_memory(i, index, "adc", 1)
            ir.OP_ANDM -> wide_memory(i, index, "and", 0)
            ir.OP_ORM -> wide_memory(i, index, "ora", 0)
            ir.OP_XORM -> wide_memory(i, index, "eor", 0)
            ir.OP_SUBM -> {
                ; memory = memory - r1
                wide_written(i, index)
                if wacc == r {
                    wide_spill()
                    if wfail
                        return
                }
                else
                    wide_save(index - 1)
                wmem("lda", i)
                wmirror = 0
                wl("sec")
                wop("sbc", r)
                if wlast[r] <= index
                    wide_release(r)
                wsta(i)
                wacc = 0
            }
            ir.OP_ADDIM, ir.OP_SUBIM -> {
                wide_written(i, index)
                wide_save(index - 1)
                wmem("lda", i)
                wmirror = 0
                if i.op == ir.OP_ADDIM {
                    wl("clc")
                    wimm("adc", i.value)
                }
                else {
                    wl("sec")
                    wimm("sbc", i.value)
                }
                wsta(i)
                wacc = 0
            }
            ir.OP_INCM -> {
                wide_written(i, index)
                wmem("inc", i)
            }
            ir.OP_DECM -> {
                wide_written(i, index)
                wmem("dec", i)
            }
            ir.OP_LSLM -> {
                wide_written(i, index)
                wmem("asl", i)
            }
            ir.OP_LSRM -> {
                wide_written(i, index)
                wmem("lsr", i)
            }
            ir.OP_INC -> {
                wide_load(r, index)
                wide_own(r)
                wl("inc  a")
            }
            ir.OP_DEC -> {
                wide_load(r, index)
                wide_own(r)
                wl("dec  a")
            }
            ir.OP_LSL, ir.OP_LSLI -> {
                if wide_rotation(i, index)
                    return
                wide_load(r, index)
                wide_own(r)
                k = 1
                if i.op == ir.OP_LSLI
                    k = i.value as long
                if k >= 8 {
                    ; by eight: the low byte becomes the high one
                    wl("and  #$00ff")
                    wl("xba")
                    k -= 8
                }
                repeat k as ubyte
                    wl("asl  a")
            }
            ir.OP_LSR, ir.OP_LSRI -> {
                if wide_rotation(i, index)
                    return
                wide_load(r, index)
                wide_own(r)
                k = 1
                if i.op == ir.OP_LSRI
                    k = i.value as long
                if k == 15 {
                    ; only the top bit is left: through the carry
                    wl("asl  a")
                    wl("lda  #0")
                    wl("rol  a")
                    k = 0
                }
                else if k >= 8 {
                    wl("xba")
                    wl("and  #$00ff")
                    k -= 8
                }
                repeat k as ubyte
                    wl("lsr  a")
            }
            ir.OP_NEG -> {
                wide_load(r, index)
                wide_own(r)
                wl("eor  #$ffff")
                wl("inc  a")
            }
            ir.OP_INV -> {
                wide_load(r, index)
                wide_own(r)
                wl("eor  #$ffff")
            }
            ir.OP_CMPI -> {
                wide_load(r, index)
                wimm("cmp", i.value)
            }
            ir.OP_CMP -> {
                uword other = i.r2
                if wacc == other and r != other {
                    wide_spill()
                    if wfail
                        return
                    ubyte kept = wkind[other]
                    wop("lda", r)
                    wmirror = 0
                    wop("cmp", other)
                    wacc = r
                }
                else {
                    wide_load(r, index)
                    if r == other
                        wfail = true
                    else
                        wop("cmp", other)
                }
            }
            ir.OP_BGT, ir.OP_BGTR, ir.OP_BLT, ir.OP_BGE, ir.OP_BGER, ir.OP_BLE -> {
                ; unsigned: the carry and the zero flag of a comparison say it all
                if i.mode == ir.M_RIT {
                    wide_load(r, index)
                    wimm("cmp", i.value)
                }
                else {
                    uword second = i.r2
                    if wacc == second and r != second {
                        wide_spill()
                        if wfail
                            return
                        wop("lda", r)
                        wmirror = 0
                        wop("cmp", second)
                        wacc = r
                    }
                    else {
                        wide_load(r, index)
                        if r == second
                            wfail = true
                        else
                            wop("cmp", second)
                    }
                }
            }
            ir.OP_BLTS, ir.OP_BGES, ir.OP_BGESR -> {
                ; signed: the sign of r1 - x, set right when the subtraction overflows
                wide_load(r, index)
                wide_own(r)
                wl("sec")
                if i.mode == ir.M_RIT
                    wimm("sbc", i.value)
                else if i.r2 == r
                    wfail = true
                else
                    wop("sbc", i.r2)
                wl("bvc  +")
                wl("eor  #$8000")
                buf.add_str(wb, "+\n")
            }
            ir.OP_BGTS, ir.OP_BGTSR, ir.OP_BLES -> {
                ; signed, the other way round: the sign of x - r1
                if wacc == r {
                    wide_spill()
                    if wfail
                        return
                    wacc = 0
                }
                if i.mode == ir.M_RIT {
                    wide_save(index - 1)
                    wimm("lda", i.value)
                    wmirror = 0
                    wacc = 0
                }
                else {
                    if i.r2 == r {
                        wfail = true
                        return
                    }
                    wide_load(i.r2, index)
                    wide_own(i.r2)
                }
                wl("sec")
                wop("sbc", r)
                wl("bvc  +")
                wl("eor  #$8000")
                buf.add_str(wb, "+\n")
                wacc = 0
            }
            else -> wfail = true
        }
    }

    long wend = 0                   ; the index of the run's last instruction
    ubyte wskip = 0                 ; the instructions after this one that it has done as well

    ; by how many bits a shift instruction shifts
    sub shift_count(^^ir.Instr i) -> long {
        if i.op == ir.OP_LSLI or i.op == ir.OP_LSRI
            return i.value as long
        return 1
    }

    ; Is the shift i the beginning of a rotation of a variable, (v << n) | (v >> (16 - n)):
    ;     shift r1 / loadm r2,[v] / the other shift of r2 / orr of the two
    ; where r1 is v?  Then it is written as a rotation: the bit that an asl pushes out comes
    ; back in with adc #0, and the like.  Only for the counts where that is the shorter code.
    sub wide_rotation(^^ir.Instr i, long index) -> bool {
        uword r = i.r1
        if wkind[r] != W_ALIAS or index + 3 > wend
            return false
        ^^ir.Instr a = i.next
        ^^ir.Instr b = a.next
        ^^ir.Instr c = b.next
        ^^ir.Instr var = wsrc[r]
        if a.op != ir.OP_LOADM or a.r1 == r or not wide_exact(a, var)
            return false
        uword other = a.r1
        bool left = i.op == ir.OP_LSL or i.op == ir.OP_LSLI
        if left {
            if b.op != ir.OP_LSR and b.op != ir.OP_LSRI
                return false
        }
        else if b.op != ir.OP_LSL and b.op != ir.OP_LSLI
            return false
        if b.r1 != other or shift_count(i) + shift_count(b) != 16 or c.op != ir.OP_ORR
            return false
        uword result = c.r1
        uword dead = c.r2
        if not ((result == r and dead == other) or (result == other and dead == r))
            return false
        if wlast[dead] > index + 3
            return false
        long n = shift_count(i)             ; to the left by n
        if not left
            n = 16 - n
        if n > 4 and n < 12 and n != 8
            return false
        wide_load(r, index)
        wide_own(r)
        if n == 8
            wl("xba")
        else if n <= 4 {
            repeat n as ubyte {
                wl("asl  a")
                wl("adc  #0")
            }
        }
        else {
            repeat (16 - n) as ubyte {
                wl("lsr  a")
                wl("bcc  +")
                wl("ora  #$8000")
                buf.add_str(wb, "+\n")
            }
        }
        if result != r {
            wkind[r] = W_ACC
            wkind[result] = W_ACC
            wacc = result
        }
        wskip = 3
        return true
    }

    ; the branch, or the two, of a comparison that branches: to target
    sub wide_branches(ubyte opcode, ^^ubyte target) {
        when opcode {
            ir.OP_BGE, ir.OP_BGER -> ins("bcs", target)
            ir.OP_BLT -> ins("bcc", target)
            ir.OP_BGT, ir.OP_BGTR -> {
                ins("beq", "+")
                ins("bcs", target)
                anon_label("+")
            }
            ir.OP_BLE -> {
                ins("bcc", target)
                ins("beq", target)
            }
            ir.OP_BLTS, ir.OP_BGTS, ir.OP_BGTSR -> ins("bmi", target)
            else -> ins("bpl", target)
        }
    }

    ; Works the run of length instructions from i (at index of the chunk) out for
    ; the 16-bit accumulator, into wb; false when it will not go.
    sub wide_try(^^ir.Instr i, long index, long length) -> bool {
        buf.clear(wb)
        wfail = false
        wacc = 0
        wmirror = 0
        w1_used = false
        w2_used = false
        walias_count = 0
        ^^ir.Instr j = i
        long k
        for k in 0 to length - 1 {
            if j.r1 != 0
                wkind[j.r1] = W_ACC
            if j.r2 != 0
                wkind[j.r2] = W_ACC
            j = j.next
        }
        ubyte n
        for n in 0 to 2 {
            if n < win_count {
                wkind[win[n]] = win_kind[n]
                when win_kind[n] {
                    W_ACC -> wacc = win[n]
                    W_S1 -> w1_used = true
                    W_S2 -> w2_used = true
                }
            }
        }
        j = i
        wstore_at = -1
        wend = index + length - 1
        k = 0
        while k < length {
            wskip = 0
            wide_instruction(j, index + k)
            if wfail
                return false
            ; (a rotation is four instructions in one)
            repeat wskip + 1
                j = j.next
            k += wskip + 1
        }
        for n in 0 to 2 {
            if n < wout_count {
                ; where the run leaves what is needed after it
                uword o = wout[n]
                if wacc == o
                    wout_kind[n] = W_ACC
                else if wkind[o] == W_S1 or wkind[o] == W_S2
                    wout_kind[n] = wkind[o]
                else
                    return false
            }
        }
        return true
    }

    bool wide_pending = false       ; the code written last left the accumulator 16 bits wide

    ; from 8 bits to 16
    sub wide_open() {
        if not wide_rest {
            ; (into native mode for the run only)
            raw("    clc")
            raw("    xce")
        }
        raw("    rep  #$20")
        raw("    .al")
    }

    ; and back; with keep, the flags of a comparison survive it for the branch that follows
    sub wide_close(bool keep) {
        wide_pending = false
        raw("    sep  #$20")
        raw("    .as")
        if not wide_rest {
            if keep {
                raw("    php")
                raw("    sec")
                raw("    xce")
                raw("    plp")
            }
            else {
                raw("    sec")
                raw("    xce")
            }
        }
    }

    sub wide_flush() {
        if wide_pending
            wide_close(false)
    }

    ; the 16-bit way into the chunk with this label: a branch from the end of a run
    ; that is 16 bits wide already (a loop back to here) goes to it
    sub wide_entry_label(^^ubyte lbl) {
        label(wide_entry_name(lbl))
        if wide_entry_count < len(wide_entries) {
            wide_entries[wide_entry_count] = lbl
            wide_entry_count++
        }
    }

    ; Writes the run that wide_try worked out (the accumulator is 16 bits wide), and what
    ; follows it; gives the number of IR instructions that are done with.
    sub wide_finish(^^ir.Instr i, long length) -> long {
        buf.add_bytes(w(), wb.data, wb.len)
        if wout_count != 0 {
            wide_close(false)
            wide_leave()
            return length
        }
        ^^ir.Instr last = i
        repeat length - 1
            last = last.next
        ^^ir.Instr after = last.next
        bool branched = false
        if wide_ok(last) == 3 {
            if wide_entry(last.sym) {
                ; to a 16-bit way in: taken as it is; the path that falls through goes on
                wide_branches(last.op, wide_entry_name(last.sym))
                if after == 0 {
                    wide_pending = true
                    return length
                }
                wide_close(false)
                return length
            }
            ; anywhere else: back to 8 bits first, the flags kept
            wide_close(true)
            wide_branches(last.op, last.sym)
            return length
        }
        if wide_ok(last) == 2 and after != 0 and after.sym != 0 and wide_entry(after.sym) {
            ^^ubyte mnemonic = 0
            when after.op {
                ir.OP_BSTEQ -> mnemonic = "beq"
                ir.OP_BSTNE -> mnemonic = "bne"
                ir.OP_BSTCC -> mnemonic = "bcc"
                ir.OP_BSTCS -> mnemonic = "bcs"
                ir.OP_BSTNEG -> mnemonic = "bmi"
                ir.OP_BSTPOS -> mnemonic = "bpl"
            }
            if mnemonic != 0 {
                ; the branch that follows goes to a 16-bit way in: it is taken as it is,
                ; and only the path that falls through goes back to 8 bits
                ins(mnemonic, wide_entry_name(after.sym))
                branched = true
                length++
                after = after.next
            }
        }
        if after == 0 and (branched or wide_ok(last) != 2) {
            ; the chunk ends here: the next one may go on 16 bits wide
            wide_pending = true
            return length
        }
        wide_close(wide_ok(last) == 2 and not branched)
        return length
    }

    ; The 8-bit way into a chunk that is entered 16 bits wide from above: written
    ; after the subroutine, it widens the accumulator and jumps to the 16-bit way in.
    ^^ubyte[32] wide_stubs
    ubyte wide_stub_count = 0

    sub wide_stub(^^ubyte lbl) {
        if wide_stub_count < len(wide_stubs) {
            wide_stubs[wide_stub_count] = lbl
            wide_stub_count++
        }
        else
            error("too many chunks that are entered 16 bits wide in one subroutine", lbl)
    }

    sub wide_write_stubs() {
        ubyte k = 0
        while k < wide_stub_count {
            label(wide_stubs[k])
            wide_open()
            ins("jmp", wide_entry_name(wide_stubs[k]))
            raw("    .as")
            k++
        }
        wide_stub_count = 0
    }

    ^^ubyte[32] wide_entries        ; the labels of this subroutine's chunks that have a 16-bit way in
    ubyte wide_entry_count = 0

    sub wide_entry(^^ubyte name) -> bool {
        ubyte k = 0
        while k < wide_entry_count {
            if strings.compare(wide_entries[k], name) == 0
                return true
            k++
        }
        return false
    }

    ; "label_w16"
    sub wide_entry_name(^^ubyte name) -> ^^ubyte {
        buf.clear(nb)
        buf.add_str(nb, name)
        buf.add_str(nb, "_w16")
        buf.add_byte(nb, 0)
        return strtab.intern_cstr(nb.data)
    }

    ; ---- instructions ----

    ; the memory operand of an instruction: its symbol (or a number as text) and offset
    ^^ubyte mem_symbol = 0
    long mem_offset = 0
    ^^buf.Buf mb = 0

    sub memory_operand(^^ir.Instr i) {
        if mb == 0
            mb = buf.new(64)
        if i.sym != 0 {
            mem_symbol = i.sym
            mem_offset = i.offset
            return
        }
        ; a fixed address
        buf.clear(mb)
        buf.add_byte(mb, '$')
        long v = i.offset           ; (the address of a fixed memory operand is in the offset field)
        ubyte shift = 12
        repeat 4 {
            buf.add_byte(mb, buf.hex_digit(((v >> shift) & 15) as ubyte))
            if shift >= 4
                shift -= 4
        }
        buf.add_byte(mb, 0)
        mem_symbol = mb.data
        mem_offset = 0
    }

    long float_errors = 0

    ; ---- operands ----
    ;
    ; The second operand of an operation is a constant, a register's cell or a
    ; memory location; operand_ins writes an instruction that takes its byte k.

    const ubyte K_IMM = 0
    const ubyte K_REG = 1
    const ubyte K_MEM = 2
    ubyte okind = K_IMM
    quad ovalue = 0
    uword oreg = 0

    sub operand_imm(quad value) {
        okind = K_IMM
        ovalue = value
    }

    sub operand_reg(uword r) {
        okind = K_REG
        oreg = r
    }

    sub operand_mem(^^ir.Instr i) {
        okind = K_MEM
        memory_operand(i)
    }

    sub operand_ins(str mnemonic, ubyte k) {
        when okind {
            K_IMM -> ins_imm(mnemonic, ((ovalue >> (k * 8)) & 255) as long)
            K_REG -> ins(mnemonic, cell(oreg, k))
            else -> ins_at(mnemonic, mem_symbol, mem_offset + k)
        }
    }

    ; the operand of the instruction's mode: #value, r2, or [memory]
    sub second_operand(^^ir.Instr i) {
        when i.mode {
            ir.M_RI, ir.M_RIT, ir.M_IM -> operand_imm(i.value)
            ir.M_RM, ir.M_M -> operand_mem(i)
            else -> operand_reg(i.r2)
        }
    }

    ; r1 = r1 op operand, byte by byte ("and", "ora", "eor"; "adc" and "sbc" carry on)
    sub combine(str mnemonic, uword r, ubyte size) {
        ubyte k
        for k in 0 to size - 1 {
            if okind == K_IMM {
                ; a byte of the constant that changes nothing, or makes the result zero
                ubyte what = trivial(mnemonic, ((ovalue >> (k * 8)) & 255) as ubyte)
                if what == 1
                    continue
                if what == 2 {
                    ins("lda", "#0")
                    sta_reg(r, k)
                    continue
                }
            }
            lda_reg(r, k)
            operand_ins(mnemonic, k)
            sta_reg(r, k)
        }
    }

    ; and/ora/eor with this constant byte: 1 = the value stays as it is, 2 = it becomes 0, 0 = neither
    sub trivial(str mnemonic, ubyte value) -> ubyte {
        if mnemonic[0] == 'a' and mnemonic[1] == 'n' {
            if value == 255
                return 1
            if value == 0
                return 2
        }
        else if (mnemonic[0] == 'o' or mnemonic[0] == 'e') and value == 0
            return 1
        return 0
    }

    ; memory = memory op r, byte by byte
    sub combine_memory(str mnemonic, ^^ir.Instr i, ubyte size) {
        memory_operand(i)
        ubyte k
        for k in 0 to size - 1 {
            if i.mode == ir.M_IM {
                ubyte what = trivial(mnemonic, ((i.value >> (k * 8)) & 255) as ubyte)
                if what == 1
                    continue
                if what == 2 {
                    store_zero(mem_symbol, mem_offset + k)
                    continue
                }
            }
            ins_at("lda", mem_symbol, mem_offset + k)
            if i.mode == ir.M_IM
                ins_imm(mnemonic, ((i.value >> (k * 8)) & 255) as long)
            else
                ins(mnemonic, cell(i.r1, k))
            ins_at("sta", mem_symbol, mem_offset + k)
        }
    }

    ; the location that inc, dec, the shifts and the rotates work on: a register's
    ; cell or a memory operand
    bool loc_mem = false
    uword loc_reg = 0

    sub location(^^ir.Instr i) {
        loc_mem = i.mode == ir.M_M
        loc_reg = i.r1
        if loc_mem
            memory_operand(i)
    }

    sub loc_ins(str mnemonic, ubyte k) {
        if loc_mem
            ins_at(mnemonic, mem_symbol, mem_offset + k)
        else
            ins(mnemonic, cell(loc_reg, k))
    }

    ; one shift to the left of the location; the bit shifted out is in the carry
    sub shift_left(ubyte size, bool through_carry) {
        ubyte k
        for k in 0 to size - 1 {
            if k == 0 and not through_carry
                loc_ins("asl", 0)
            else
                loc_ins("rol", k)
        }
    }

    ; one shift to the right; signed keeps the top bit
    sub shift_right(ubyte size, bool signed, bool through_carry) {
        ubyte k = size
        if signed {
            loc_ins("lda", size - 1)
            ins("asl", "a")             ; the sign into the carry
        }
        while k > 0 {
            k--
            if k == size - 1 and not signed and not through_carry
                loc_ins("lsr", k)
            else
                loc_ins("ror", k)
        }
    }

    ; What multiplying by a constant with shifts and additions costs, in cycles,
    ; roughly: one shift for every bit below the highest, one addition for
    ; every other bit that is set.  Very large for a constant that will not do.
    sub shift_add_cost(quad value, ubyte size) -> long {
        long v = value as long
        if size == 1
            v &= 255
        else
            v &= $ffff
        if v < 3
            return 100000
        long shifts = 0
        long adds = 0
        long top = 0
        long bit = 1
        long k
        for k in 0 to 15 {
            if v & bit != 0 {
                top = k
                adds++
            }
            bit <<= 1
        }
        shifts = top
        adds--
        if size == 1
            return shifts * 2 + adds * 5
        return shifts * 7 + adds * 20
    }

    ; r1 = r1 * value: from the highest bit of the constant down, the result is
    ; doubled, and the number added for a bit that is set.  A byte in A; a word
    ; with its low byte in A and its high byte in the scratch word W1, the number
    ; itself in W2.
    sub shift_add_multiply(uword r, quad value, ubyte size) {
        long v = value as long
        if size == 1
            v &= 255
        else
            v &= $ffff
        long top = 15
        while top > 0 and (v >> (top as ubyte)) & 1 == 0
            top--
        lda_reg(r, 0)
        ins("sta", "P8ZP_SCRATCH_W2")
        if size == 2 {
            ins("ldy", cell(r, 1))
            ins("sty", "P8ZP_SCRATCH_W2+1")
            ins("sty", "P8ZP_SCRATCH_W1+1")
        }
        long k = top
        while k > 0 {
            k--
            ins("asl", "a")
            if size == 2
                ins("rol", "P8ZP_SCRATCH_W1+1")
            if (v >> (k as ubyte)) & 1 != 0 {
                ins("clc", 0)
                ins("adc", "P8ZP_SCRATCH_W2")
                if size == 2 {
                    ins("tay", 0)
                    ins("lda", "P8ZP_SCRATCH_W1+1")
                    ins("adc", "P8ZP_SCRATCH_W2+1")
                    ins("sta", "P8ZP_SCRATCH_W1+1")
                    ins("tya", 0)
                }
            }
        }
        sta_reg(r, 0)
        if size == 2 {
            ins("lda", "P8ZP_SCRATCH_W1+1")
            sta_reg(r, 1)
        }
    }

    ; does the library have a routine that multiplies by this constant?
    sub small_multiply(ubyte size, quad value) -> bool {
        if size == 1 {
            when value {
                3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 20, 25 -> return true
            }
        }
        else if size == 2 {
            when value {
                3, 5, 6, 7, 9, 10, 12, 15, 20, 25, 40, 50, 80, 100 -> return true
            }
        }
        return false
    }

    ; the n of a value that is 2 to the n and fits the size (below 2 to the 31), or -1
    sub power_of_two(quad value, ubyte size) -> byte {
        byte n = 0
        quad bit = 1
        while n < size * 8 and n < 31 {
            if value == bit
                return n
            bit <<= 1
            n++
        }
        return -1
    }

    ; a shift by a count that is known: the single shift repeated, in a loop when that is shorter
    sub shift_times(^^ir.Instr i, ubyte size, long count, ubyte kind) {
        if count <= 0
            return
        if size == 1 and not loc_mem and count >= 2 and count <= 7 {
            ; a byte in a register, more than once: in A (an instruction of one byte each)
            lda_reg(loc_reg, 0)
            repeat count as ubyte {
                when kind {
                    0 -> ins("asl", "a")
                    1 -> ins("lsr", "a")
                    else -> {
                        ins("cmp", "#$80")      ; the sign into the carry
                        ins("ror", "a")
                    }
                }
            }
            sta_reg(loc_reg, 0)
            return
        }
        if size == 2 and not loc_mem and count >= 8 and count <= 15 and kind != 2 {
            ; a word by eight or more: its bytes move, and the rest is a shift of one byte
            if kind == 0 {
                lda_reg(loc_reg, 0)
                repeat (count - 8) as ubyte
                    ins("asl", "a")
                sta_reg(loc_reg, 1)
                ins("lda", "#0")
                sta_reg(loc_reg, 0)
            }
            else {
                lda_reg(loc_reg, 1)
                repeat (count - 8) as ubyte
                    ins("lsr", "a")
                sta_reg(loc_reg, 0)
                ins("lda", "#0")
                sta_reg(loc_reg, 1)
            }
            return
        }
        if count * size <= 6 {
            repeat count as ubyte
                one_shift(size, kind)
            return
        }
        ins_imm("ldy", count)
        anon_label("-")
        one_shift(size, kind)
        ins("dey", 0)
        ins("bne", "-")
    }

    ; kind 0: left, 1: right unsigned, 2: right signed
    sub one_shift(ubyte size, ubyte kind) {
        when kind {
            0 -> shift_left(size, false)
            1 -> shift_right(size, false, false)
            else -> shift_right(size, true, false)
        }
    }

    ; a shift by the count in a register
    sub shift_by_register(^^ir.Instr i, ubyte size, ubyte kind) {
        ins("ldy", cell(i.r2, 0))
        ins("beq", "+")
        anon_label("-")
        one_shift(size, kind)
        ins("dey", 0)
        ins("bne", "-")
        anon_label("+")
    }

    ; ---- comparing ----

    ; Compares r with the operand by subtracting, lowest byte first.  Afterwards the
    ; carry is set when r >= operand (unsigned), and with for_sign the N flag says
    ; r < operand for signed numbers.  The Z flag is only right for one byte.
    sub subtract_compare(uword r, ubyte size, bool for_sign) {
        ubyte k
        ubyte first = 0
        if okind == K_IMM and not for_sign {
            ; the low bytes of a constant that are zero take nothing away: they are left out
            while first < size - 1 and (ovalue >> (first * 8)) & 255 == 0
                first++
        }
        for k in first to size - 1 {
            lda_reg(r, k)
            if k == first and not for_sign
                operand_ins("cmp", k)
            else {
                if k == 0
                    ins("sec", 0)
                operand_ins("sbc", k)
            }
        }
        if for_sign {
            ins("bvc", "+")
            ins("eor", "#$80")
            anon_label("+")
        }
    }

    ; the same with the two swapped: carry set when operand >= r, N when operand < r
    sub subtract_compare_swapped(uword r, ubyte size, bool for_sign) {
        ubyte k
        for k in 0 to size - 1 {
            operand_ins("lda", k)
            if k == 0 and not for_sign
                ins("cmp", cell(r, 0))
            else {
                if k == 0
                    ins("sec", 0)
                ins("sbc", cell(r, k))
            }
        }
        if for_sign {
            ins("bvc", "+")
            ins("eor", "#$80")
            anon_label("+")
        }
    }

    ; Z set when r equals the operand
    sub equal_compare(uword r, ubyte size) {
        ubyte k
        if okind == K_IMM and ovalue == 0 and size > 1 {
            ; with zero: all its bytes together (from the last one, which is the one that
            ; was written last and is in A more often than not)
            lda_reg(r, size - 1)
            k = size - 1
            while k != 0 {
                k--
                ins("ora", cell(r, k))
            }
            return
        }
        for k in 0 to size - 1 {
            lda_reg(r, k)
            operand_ins("cmp", k)
            if k != size - 1
                ins("bne", "+")
        }
        if size > 1
            anon_label("+")
    }

    ; cmp and cmpi set the flags for the branch on status that follows
    sub compare(^^ir.Instr i, ubyte size) {
        second_operand(i)
        ubyte following = ir.OP_NOP
        if i.next != 0
            following = i.next.op
        if size == 1
            subtract_compare(i.r1, 1, false)
        else if following == ir.OP_BSTEQ or following == ir.OP_BSTNE
            equal_compare(i.r1, size)
        else if following == ir.OP_BSTNEG or following == ir.OP_BSTPOS {
            ; the sign of the difference
            subtract_compare(i.r1, size, false)
        }
        else
            subtract_compare(i.r1, size, false)
    }

    ; the compare and branch instructions: bgt, bge, blt, ble, signed or not, r1 with #value or r2
    sub compare_branch(^^ir.Instr i, ubyte size) {
        if i.mode == ir.M_RIT
            operand_imm(i.value)
        else
            operand_reg(i.r2)
        when i.op {
            ir.OP_BGE, ir.OP_BGER -> {
                subtract_compare(i.r1, size, false)
                ins("bcs", i.sym)
            }
            ir.OP_BLT -> {
                subtract_compare(i.r1, size, false)
                ins("bcc", i.sym)
            }
            ir.OP_BGT, ir.OP_BGTR -> {
                subtract_compare_swapped(i.r1, size, false)
                ins("bcc", i.sym)
            }
            ir.OP_BLE -> {
                subtract_compare_swapped(i.r1, size, false)
                ins("bcs", i.sym)
            }
            ir.OP_BGES, ir.OP_BGESR -> {
                subtract_compare(i.r1, size, true)
                ins("bpl", i.sym)
            }
            ir.OP_BLTS -> {
                subtract_compare(i.r1, size, true)
                ins("bmi", i.sym)
            }
            ir.OP_BGTS, ir.OP_BGTSR -> {
                subtract_compare_swapped(i.r1, size, true)
                ins("bmi", i.sym)
            }
            ir.OP_BLES -> {
                subtract_compare_swapped(i.r1, size, true)
                ins("bpl", i.sym)
            }
        }
    }

    ; the operands of a 32 bit multiplication or division: r1 in cx16.r12 and r13, the
    ; operand in cx16.r14 and r15, where the result appears too
    sub long_operands(^^ir.Instr i) {
        ubyte k
        for k in 0 to 3 {
            lda_reg(i.r1, k)
            ins_at("sta", "cx16.r12", k)
        }
        for k in 0 to 3 {
            operand_ins("lda", k)
            ins_at("sta", "cx16.r14", k)
        }
    }

    sub long_result(uword r) {
        ubyte k
        for k in 0 to 3 {
            ins_at("lda", "cx16.r14", k)
            sta_reg(r, k)
        }
    }

    ; ---- pointers and indexes ----

    ; the pointer in a register into the scratch pair, to be followed with (zp),y
    ^^ir.Instr prev_instr = 0       ; the instruction written before this one, in the same chunk
    ^^ir.Instr this_instr = 0

    ; Is a word store better done high byte first?  When the instruction before it left
    ; that byte in A: a load through a pointer.  Only for a plain variable: the order of
    ; writes to anything else may matter.
    sub high_first(^^ir.Instr i) -> bool {
        if prev_instr == 0 or prev_instr.op != ir.OP_LOADI or prev_instr.r1 != i.r1 or type_size(prev_instr.type) != 2
            return false
        return i.sym != 0 and peep6502.scanned(i.sym).mark & peep6502.K_PLAIN != 0
    }

    ; A word that is loaded from a variable, has bytes added to it or subtracted from it,
    ; and is stored (fuse_indexed marked the chain): the low byte stays in A and the high
    ; byte in Y, which only moves on a carry.
    sub ay_chain(^^ir.Instr head) {
        memory_operand(head)
        ins_at("lda", mem_symbol, mem_offset)
        ins_at("ldy", mem_symbol, mem_offset + 1)
        ^^ir.Instr j = head.next
        ^^ir.Instr zx = 0
        while j != 0 and j.scale == 252 {
            when j.op {
                ir.OP_LOADMZ -> zx = j
                ir.OP_ADDR -> {
                    ins("clc", 0)
                    memory_operand(zx)
                    ins_at("adc", mem_symbol, mem_offset)
                    ins("bcc", "+")
                    ins("iny", 0)
                    anon_label("+")
                }
                ir.OP_SUBR -> {
                    ins("sec", 0)
                    memory_operand(zx)
                    ins_at("sbc", mem_symbol, mem_offset)
                    ins("bcs", "+")
                    ins("dey", 0)
                    anon_label("+")
                }
                ir.OP_ADD, ir.OP_INC -> {
                    ins("clc", 0)
                    if j.op == ir.OP_INC
                        ins_imm("adc", 1)
                    else
                        ins_imm("adc", j.value as long)
                    ins("bcc", "+")
                    ins("iny", 0)
                    anon_label("+")
                }
                ir.OP_SUB, ir.OP_DEC -> {
                    ins("sec", 0)
                    if j.op == ir.OP_DEC
                        ins_imm("sbc", 1)
                    else
                        ins_imm("sbc", j.value as long)
                    ins("bcs", "+")
                    ins("dey", 0)
                    anon_label("+")
                }
                ir.OP_STOREM -> {
                    memory_operand(j)
                    ins_at("sta", mem_symbol, mem_offset)
                    ins_at("sty", mem_symbol, mem_offset + 1)
                }
            }
            j = j.next
        }
    }

    ; finds such a chain from the load a, and marks it
    sub mark_ay_chain(^^ir.Instr a) {
        uword r = a.r1
        if a.op != ir.OP_LOADM or type_size(a.type) != 2 or r == 0 or r > ir.regcount or a.scale >= 250
            return
        ubyte ops = 0
        ^^ir.Instr j = a.next
        ^^ir.Instr zx = 0
        ^^ir.Instr tail = 0
        while j != 0 and tail == 0 {
            if j.scale >= 250
                return
            when j.op {
                ir.OP_LOADMZ -> {
                    ; the byte for the addition that follows
                    ^^ir.Instr user = j.next
                    if zx != 0 or j.r1 > ir.regcount or reg_uses[j.r1] != 2 or user == 0 or user.r2 != j.r1
                            or (user.op != ir.OP_ADDR and user.op != ir.OP_SUBR)
                        return
                    zx = j
                }
                ir.OP_ADDR, ir.OP_SUBR -> {
                    if j.r1 != r or zx == 0 or j.r2 != zx.r1 or j.mode != ir.M_RR or type_size(j.type) != 2
                        return
                    zx = 0
                    ops++
                }
                ir.OP_ADD, ir.OP_SUB -> {
                    if j.r1 != r or j.mode != ir.M_RI or j.sym != 0 or j.value < 1 or j.value > 255 or type_size(j.type) != 2
                        return
                    ops++
                }
                ir.OP_INC, ir.OP_DEC -> {
                    if j.r1 != r or type_size(j.type) != 2
                        return
                    ops++
                }
                ir.OP_STOREM -> {
                    if j.r1 != r or type_size(j.type) != 2 or zx != 0
                        return
                    tail = j
                }
                else -> return
            }
            j = j.next
        }
        if tail == 0 or ops == 0 or reg_uses[r] != ops + 2
            return
        a.scale = 251
        j = a.next
        while j != tail {
            j.scale = 252
            j = j.next
        }
        tail.scale = 252
    }

    ; r1 = r1 <operation> the byte a pointer points at (fuse_indexed put the load and the
    ; operation together: scale 254 with a constant offset, 253 with a byte index in r3).
    ; The value stays in A from one such operation to the next.
    sub combine_indirect(^^ir.Instr i, str mnemonic) -> bool {
        if i.scale != 253 and i.scale != 254
            return false
        pointer_to_scratch(i.r2)
        if i.scale == 253
            ins("ldy", cell(i.r3, 0))
        else
            ins_imm("ldy", i.offset)
        lda_reg(i.r1, 0)
        if mnemonic[0] == 'a' and mnemonic[1] == 'd'
            ins("clc", 0)
        else if mnemonic[0] == 's'
            ins("sec", 0)
        ins(mnemonic, "(P8ZP_SCRATCH_W1),y")
        sta_reg(i.r1, 0)
        return true
    }

    sub pointer_to_scratch(uword r) {
        lda_reg(r, 0)
        ins("sta", "P8ZP_SCRATCH_W1")
        lda_reg(r, 1)
        ins("sta", "P8ZP_SCRATCH_W1+1")
    }

    ; Y for element r2 of an array of elements of this size (1, 2 or 4 bytes)
    sub index_to_y(^^ir.Instr i) {
        if i.scale <= 1 {
            ins("ldy", cell(i.r2, 0))
            return
        }
        lda_reg(i.r2, 0)
        ins("asl", "a")
        if i.scale == 4
            ins("asl", "a")
        else if i.scale == 5 {
            ; a float: four times and once more
            ins("asl", "a")
            ins("clc", 0)
            ins("adc", cell(i.r2, 0))
        }
        else if i.scale != 2
            error("array elements of this size not supported yet", i.sym)
        ins("tay", 0)
    }

    ; the same in X (for the 65816's 24-bit addresses, which only X indexes)
    sub index_to_x(^^ir.Instr i) {
        if i.scale <= 1 {
            ins("ldx", cell(i.r2, 0))
            return
        }
        index_to_y(i)
        ins("tyx", 0)
    }

    ; ---- floats ----
    ;
    ; A float is five bytes in Microsoft's format, in a cell or a variable like any
    ; other value.  Arithmetic goes through the ROM's accumulator FAC1 with the
    ; routines of the floats library, which take the address of a float in A and Y
    ; (X and Y to store).

    ubyte[5] fbytes

    ; the five bytes of a number, as upstream's Mflpt5 makes them (not rounded)
    sub float_bytes(float value) {
        ubyte k
        for k in 0 to 4
            fbytes[k] = 0
        if value == 0.0
            return
        ubyte sign = 0
        if value < 0.0 {
            sign = $80
            value = -value
        }
        long exponent = 128 + 32
        while value >= 4294967296.0 {
            value /= 2.0
            exponent++
        }
        while value < 2147483648.0 {
            value *= 2.0
            exponent--
        }
        if exponent <= 0
            return              ; too small: zero
        if exponent > 255 {
            error("floating point number out of range", 0)
            return
        }
        fbytes[0] = exponent as ubyte
        ubyte digit = (value / 16777216.0) as ubyte
        value -= (digit as float) * 16777216.0
        fbytes[1] = (digit & $7f) | sign
        digit = (value / 65536.0) as ubyte
        value -= (digit as float) * 65536.0
        fbytes[2] = digit
        digit = (value / 256.0) as ubyte
        value -= (digit as float) * 256.0
        fbytes[3] = digit
        fbytes[4] = value as ubyte
    }

    ; the address of a register's cell in A and Y, or in X and Y
    sub cell_address(uword r, str low) {
        long offset = 0
        if r < cell_cap
            offset = cell_of[r]
        ins_half(low, '<', "p8_regfile", offset)
        ins_half("ldy", '>', "p8_regfile", offset)
    }

    sub fac1_load(uword r) {
        cell_address(r, "lda")
        ins("jsr", "floats.MOVFM")
    }

    sub fac1_store(uword r) {
        cell_address(r, "ldx")
        ins("jsr", "floats.MOVMF")
    }

    ; ---- floats: what is in FAC1, and operands that are taken from where they are ----
    ;
    ; The ROM's routines work on FAC1 and a number in memory.  fac_reg is the register
    ; whose value FAC1 holds after the instruction before this one (0: not known).  A
    ; result is only put into its register's cell when the instruction that follows does
    ; not take it from FAC1; a variable or a constant that is loaded only to be the
    ; second operand is used where it is (fuse_floats: scale 249 and 248).
    long breakpoints = 0            ; the %breakpoint labels written (p8_breakpoint_N)
    uword fac_reg = 0               ; set by the instruction that is being written
    uword fac_prev = 0              ; what the one before it left
    ^^ir.Chunk fchunk = 0
    ^^ir.Instr fwait = 0            ; a load of a variable that the next instruction does: its first operand
    ^^ir.Instr fwait_prev = 0
    float[64] fconsts               ; the constants that are operands, in the data as p8_fconst_N
    ubyte fconst_count = 0

    sub float_op(^^ir.Instr i) -> bool {
        when i.op {
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_DIVSR -> return i.type == ir.T_FLOAT and i.mode == ir.M_RR
        }
        return false
    }

    sub float_commutes(^^ir.Instr i) -> bool {
        return i.op == ir.OP_ADDR or i.op == ir.OP_MULR or i.op == ir.OP_MULSR
    }

    sub names_register(^^ir.Instr i, uword r) -> ubyte {
        ubyte count = 0
        if i.r1 == r
            count++
        if i.r2 == r
            count++
        if i.r3 == r
            count++
        ^^ir.Arg a = i.args
        while a != 0 {
            if a.reg == r
                count++
            a = a.next
        }
        a = i.results
        while a != 0 {
            if a.reg == r
                count++
            a = a.next
        }
        return count
    }

    ; is register r named nowhere after instruction n (in this chunk, and in no other)
    sub dies_at(uword r, ^^ir.Instr n) -> bool {
        if r == 0 or r > ir.regcount or fchunk == 0 or reg_uses[r] == 255
            return false
        uword count = 0
        ^^ir.Instr j = fchunk.first
        bool after = false
        while j != 0 {
            ubyte here = names_register(j, r)
            if after and here != 0
                return false
            count += here
            if j == n
                after = true
            j = j.next
        }
        return count == reg_uses[r]
    }

    ; does the instruction after i take register r's new value from FAC1
    sub fac_consumer(uword r, ^^ir.Instr i) -> bool {
        ^^ir.Instr n = i.next
        while n != 0 and n.op == ir.OP_NOP
            n = n.next
        if n == 0
            return false
        if float_op(n) {
            if float_commutes(n)
                return n.r1 == r and n.r2 != r
            return n.r2 == r and n.r1 != r and n.scale < 248 and dies_at(r, n)
        }
        if n.op == ir.OP_STOREM and n.type == ir.T_FLOAT
            return n.r1 == r and dies_at(r, n)
        if n.op == ir.OP_FCOMP
            return n.r2 == r and n.r3 != r and n.r1 != r and dies_at(r, n)
        return false
    }

    ; FAC1 holds register r's new value: into its cell, unless the next instruction takes it
    sub fac_result(uword r, ^^ir.Instr i) {
        if not fac_consumer(r, i)
            fac1_store(r)
        fac_reg = r
    }

    sub fconst_name(float value) -> ^^ubyte {
        ubyte k = 0
        while k < fconst_count {
            if fconsts[k] == value
                break
            k++
        }
        if k == fconst_count {
            fconsts[k] = value
            fconst_count++
        }
        buf.clear(nb)
        buf.add_str(nb, "p8_fconst_")
        buf.add_long(nb, k)
        buf.add_byte(nb, 0)
        return strtab.intern_cstr(nb.data)
    }

    ; the address of the second operand of a float operation in A and Y (or X and Y)
    sub second_address(^^ir.Instr i, str low) {
        if i.scale == 249 {
            memory_operand(i)
            ins_half(low, '<', mem_symbol, mem_offset)
            ins_half("ldy", '>', mem_symbol, mem_offset)
        }
        else if i.scale == 248 {
            ^^ubyte name = fconst_name(i.fvalue)
            ins_half(low, '<', name, 0)
            ins_half("ldy", '>', name, 0)
        }
        else
            cell_address(i.r2, low)
    }

    ; r1 = r1 op r2 with a routine that works on FAC1 and the float at A and Y
    ; (for the two that are not symmetric, FSUB and FDIV, FAC1 is the second operand)
    sub float_arithmetic(^^ir.Instr i, str routine) {
        if i.mode != ir.M_RR {
            error("this form of float arithmetic is not supported yet", 0)
            return
        }
        if float_commutes(i) and fac_prev == i.r1 and (i.scale >= 248 or i.r2 != i.r1) {
            ; (the first operand is in FAC1 already)
            second_address(i, "lda")
            ins("jsr", routine)
        }
        else if i.scale < 248 and fac_prev == i.r2 and i.r2 != i.r1 {
            ; (the second one is)
            cell_address(i.r1, "lda")
            ins("jsr", routine)
        }
        else {
            second_address(i, "lda")
            ins("jsr", "floats.MOVFM")
            if fwait_prev != 0 and fwait_prev.r1 == i.r1 {
                ; (the first operand is a variable, used where it is)
                memory_operand(fwait_prev)
                ins_half("lda", '<', mem_symbol, mem_offset)
                ins_half("ldy", '>', mem_symbol, mem_offset)
            }
            else
                cell_address(i.r1, "lda")
            ins("jsr", routine)
        }
        fac_result(i.r1, i)
    }

    ; A variable or a constant that is loaded to be the second operand of the operation
    ; right after it, and for nothing else: the operation takes it from where it is.
    sub fuse_floats(^^ir.Chunk c) {
        fchunk = c
        fac_reg = 0
        this_instr = 0
        ^^ir.Instr a = c.first
        while a != 0 {
            ^^ir.Instr b = a.next
            if b != 0 and a.type == ir.T_FLOAT and (a.op == ir.OP_LOADM or a.op == ir.OP_LOAD) and a.r1 != 0 and a.r1 <= ir.regcount
                    and reg_uses[a.r1] == 2 and float_op(b) and b.r2 == a.r1 and b.r1 != a.r1 and b.scale < 248 {
                if a.op == ir.OP_LOADM {
                    b.sym = a.sym
                    b.offset = a.offset
                    b.value = a.value
                    b.scale = 249
                    b.r2 = 0
                    a.op = ir.OP_NOP
                }
                else if a.sym == 0 and fconst_count < len(fconsts) - 1 {
                    b.fvalue = a.fvalue
                    b.scale = 248
                    b.r2 = 0
                    a.op = ir.OP_NOP
                }
            }
            else if b != 0 and a.type == ir.T_FLOAT and (a.op == ir.OP_LOADM or a.op == ir.OP_LOAD) and a.r1 != 0 and a.r1 <= ir.regcount
                    and reg_uses[a.r1] == 2 and b.op == ir.OP_FCOMP and b.r3 == a.r1 and b.r2 != a.r1 and b.r1 != a.r1 and b.scale < 248 {
                ; (the same for what a number is compared with)
                if a.op == ir.OP_LOADM {
                    b.sym = a.sym
                    b.offset = a.offset
                    b.value = a.value
                    b.scale = 249
                    b.r3 = 0
                    a.op = ir.OP_NOP
                }
                else if a.sym == 0 and fconst_count < len(fconsts) - 1 {
                    b.fvalue = a.fvalue
                    b.scale = 248
                    b.r3 = 0
                    a.op = ir.OP_NOP
                }
            }
            a = a.next
        }
    }

    ; Translates a float instruction; false when it is one that the code for integers
    ; handles as five bytes.
    sub float_instruction(^^ir.Instr i) -> bool {
        ubyte k
        when i.op {
            ir.OP_NOP -> {
            }
            ir.OP_LOADM -> {
                if i.type != ir.T_FLOAT
                    return false
                ^^ir.Instr user = i.next
                while user != 0 and user.op == ir.OP_NOP
                    user = user.next
                if user != 0 and float_op(user) and not float_commutes(user) and user.r1 == i.r1 and (user.scale >= 248 or user.r2 != i.r1) {
                    ; the first operand of a subtraction or a division: that takes it from the variable
                    fwait = i
                    return true
                }
                if not fac_consumer(i.r1, i)
                    return false
                ; (only to be worked on: straight into FAC1)
                memory_operand(i)
                ins_half("lda", '<', mem_symbol, mem_offset)
                ins_half("ldy", '>', mem_symbol, mem_offset)
                ins("jsr", "floats.MOVFM")
                fac_reg = i.r1
            }
            ir.OP_STOREM -> {
                if i.type != ir.T_FLOAT or fac_prev != i.r1 or not dies_at(i.r1, i)
                    return false
                ; (the result is in FAC1, and wanted nowhere else)
                memory_operand(i)
                ins_half("ldx", '<', mem_symbol, mem_offset)
                ins_half("ldy", '>', mem_symbol, mem_offset)
                ins("jsr", "floats.MOVMF")
            }
            ir.OP_LOADR, ir.OP_LOADX, ir.OP_STOREX, ir.OP_LOADI, ir.OP_STOREI,
            ir.OP_STOREZM, ir.OP_STOREZX, ir.OP_STOREZI, ir.OP_CALL, ir.OP_CALLI, ir.OP_CALLFAR, ir.OP_CALLFARVB, ir.OP_SYSCALL,
            ir.OP_PUSH, ir.OP_POP -> return false
            ir.OP_LOAD -> {
                float_bytes(i.fvalue)
                for k in 0 to 4 {
                    ins_imm("lda", fbytes[k])
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_STOREIM -> {
                float_bytes(i.fvalue)
                memory_operand(i)
                for k in 0 to 4 {
                    ins_imm("lda", fbytes[k])
                    ins_at("sta", mem_symbol, mem_offset + k)
                }
            }
            ir.OP_ADDR, ir.OP_ADD -> float_arithmetic(i, "floats.FADD")
            ir.OP_SUBR, ir.OP_SUB -> float_arithmetic(i, "floats.FSUB")
            ir.OP_MULR, ir.OP_MULSR, ir.OP_MUL, ir.OP_MULS -> float_arithmetic(i, "floats.FMULT")
            ir.OP_DIVR, ir.OP_DIVSR, ir.OP_DIV, ir.OP_DIVS -> float_arithmetic(i, "floats.FDIV")
            ir.OP_NEG -> {
                ; the sign bit, unless the number is zero
                lda_reg(i.r1, 0)
                ins("beq", "+")
                lda_reg(i.r1, 1)
                ins("eor", "#$80")
                sta_reg(i.r1, 1)
                anon_label("+")
            }
            ir.OP_FABS -> {
                for k in 0 to 4 {
                    lda_reg(i.r2, k)
                    if k == 1
                        ins("and", "#$7f")
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_SGN -> {
                fac1_load(i.r2)
                ins("jsr", "floats.SIGN")
                sta_reg(i.r1, 0)
            }
            ir.OP_SQRT -> {
                fac1_load(i.r2)
                ins("jsr", "floats.SQR")
                fac1_store(i.r1)
            }
            ir.OP_INC -> {
                cell_address(i.r1, "lda")
                ins("jsr", "floats.inc_var_f")
            }
            ir.OP_DEC -> {
                cell_address(i.r1, "lda")
                ins("jsr", "floats.dec_var_f")
            }
            ir.OP_INCM, ir.OP_DECM -> {
                memory_operand(i)
                ins_half("lda", '<', mem_symbol, mem_offset)
                ins_half("ldy", '>', mem_symbol, mem_offset)
                if i.op == ir.OP_INCM
                    ins("jsr", "floats.inc_var_f")
                else
                    ins("jsr", "floats.dec_var_f")
            }
            ir.OP_FFROMUB -> {
                ins("ldy", cell(i.r2, 0))
                ins("jsr", "floats.FREADUY")
                fac1_store(i.r1)
            }
            ir.OP_FFROMSB -> {
                lda_reg(i.r2, 0)
                ins("jsr", "floats.FREADSA")
                fac1_store(i.r1)
            }
            ir.OP_FFROMSL -> {
                ; a long: the library's routine takes its address
                cell_address(i.r2, "lda")
                ins("jsr", "floats.internal_long_AY_to_FAC")
                fac1_store(i.r1)
            }
            ir.OP_FTOSL -> {
                ; (the float at cx16.r0 into the long at A and Y)
                cell_address(i.r2, "lda")
                ins("sta", "cx16.r0")
                ins("sty", "cx16.r0+1")
                cell_address(i.r1, "lda")
                ins("jsr", "floats.cast_as_long")
            }
            ir.OP_LOADHR -> {
                ; a float that a subroutine returns next to other values is in FAC1
                if i.type != ir.T_FLOAT
                    return false
                fac1_store(i.r1)
            }
            ir.OP_STOREHR -> {
                if i.type != ir.T_FLOAT
                    return false
                fac1_load(i.r1)
            }
            ir.OP_FFROMUW, ir.OP_FFROMSW -> {
                ins("ldy", cell(i.r2, 1))
                lda_reg(i.r2, 0)
                if i.op == ir.OP_FFROMUW
                    ins("jsr", "floats.GIVUAYFAY")
                else
                    ins("jsr", "floats.GIVAYFAY")
                fac1_store(i.r1)
            }
            ir.OP_FTOUB, ir.OP_FTOUW -> {
                fac1_load(i.r2)
                ins("jsr", "floats.cast_FAC1_as_uw_into_ya")
                ins("sty", cell(i.r1, 0))
                if i.op == ir.OP_FTOUW
                    sta_reg(i.r1, 1)
            }
            ir.OP_FTOSB, ir.OP_FTOSW -> {
                fac1_load(i.r2)
                ins("jsr", "floats.cast_FAC1_as_w_into_ay")
                sta_reg(i.r1, 0)
                if i.op == ir.OP_FTOSW
                    ins("sty", cell(i.r1, 1))
            }
            ir.OP_FCOMP -> {
                ; 0, 1 when the first is greater, 255 when it is less
                if fac_prev != i.r2
                    fac1_load(i.r2)
                if i.scale >= 248
                    second_address(i, "lda")
                else
                    cell_address(i.r3, "lda")
                ins("jsr", "floats.FCOMP")
                sta_reg(i.r1, 0)
            }
            ir.OP_RETURNR -> {
                fac1_load(i.r1)
                ins("rts", 0)
            }
            else -> {
                if float_errors == 0
                    error("a floating point instruction is not supported yet by this code generator", ir.opcode_names[i.op])
                float_errors++
            }
        }
        return true
    }

    ^^ir.Sub cursub = 0             ; the subroutine whose code is being written, or 0

    ; A return: which registers carry a value to the caller (for peep6502).  Only for a
    ; subroutine that returns nothing or one value is that known here; one that
    ; returns several has put them in registers before.
    sub return_uses(ubyte size) {
        ubyte mask = 255
        if cursub != 0 and not cursub.is_asm {
            ^^ubyte r = cursub.returns
            if r == 0 or r[0] == 0
                mask = 0
            else {
                bool several = false
                long k = 0
                while r[k] != 0 {
                    if r[k] == ','
                        several = true
                    k++
                }
                if not several {
                    when size {
                        1 -> mask = 1
                        2 -> mask = 5
                        4, 5 -> mask = 0        ; (in the virtual registers, or in FAC1)
                    }
                }
            }
        }
        ins("rts", 0)
        peep6502.last_uses(mask)
    }

    ; the registers that the arguments of a call are in
    sub call_uses(^^ir.Instr i, bool in_registers) -> ubyte {
        ubyte mask = 0
        if in_registers {
            when convention(find_sub(i.sym)) {
                CONV_A -> mask = 1
                CONV_A_Y, CONV_AY -> mask = 5
            }
        }
        ^^ir.Arg a = i.args
        while a != 0 {
            when a.slot {
                0 -> mask |= 1
                1 -> mask |= 2
                2 -> mask |= 4
                3 -> mask |= 3
                4 -> mask |= 5
                5 -> mask |= 6
            }
            a = a.next
        }
        return mask
    }

    ; The 45GS02 counts a word in the zero page up or down in one instruction (inw, dew:
    ; two bytes of code, where the 6502 has six for the one and seventeen for the other).
    ; For a variable that is there.
    sub word_step(^^ir.Instr i, str mnemonic, ubyte size) -> bool {
        if not c45 or size != 2 or i.mode != ir.M_M or i.sym == 0 or i.scale >= 200
            return false
        ^^ir.Var v = prog.vars
        while v != 0 and v.name != i.sym and strings.compare(v.name, i.sym) != 0
            v = v.next
        if v == 0 or v.zpaddr == 0 or v.kind != ir.V_VAR
            return false
        memory_operand(i)
        q_text(mnemonic, mem_symbol, mem_offset)
        return true
    }

    ; ---- memory beyond the first 64 KB ----
    ; An instruction whose memory operand is at an address of more than 16 bits.  Both
    ; CPUs reach such memory through a pointer in the zero page (the 65816 with three
    ; bytes and [dp],y; the 45GS02 with four and [zp],z; the two scratch words are four
    ; bytes in a row).  The value is fetched into a few bytes of the register file, the
    ; instruction is written as for a variable there, and what it changed is put back:
    ; so every instruction that has a memory operand can have a far one.
    long far_cells = 0

    ; the memory mapped variables that are in far memory, and where: an instruction may
    ; name one instead of giving its address
    const ubyte FAR_NAMES = 64
    ^^pointer far_names = 0
    long[FAR_NAMES] far_addresses
    ubyte far_count = 0

    sub far_prepare() {
        far_count = 0
        if types.far_bits == 0
            return
        if far_names == 0
            far_names = mem.alloc(FAR_NAMES as long * sizeof(pointer))
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 {
                long address = number(v.init)
                if address > $ffff {
                    if far_count == FAR_NAMES
                        error("too many variables in far memory for this code generator (64)", v.name)
                    else {
                        far_names[far_count] = v.name
                        far_addresses[far_count] = address
                        far_count++
                    }
                }
            }
            v = v.next
        }
    }

    ; the address of the far variable of that name, or -1
    sub far_named(^^ubyte name) -> long {
        ubyte k = 0
        while k < far_count {
            ^^ubyte known = far_names[k]
            if known == name or strings.compare(known, name) == 0
                return far_addresses[k]
            k++
        }
        return -1
    }

    ; The address of the instruction's memory operand when that is more than 16 bits, or -1.
    sub far_address(^^ir.Instr i) -> long {
        if types.far_bits == 0 or (i.mode != ir.M_M and i.mode != ir.M_RM and i.mode != ir.M_IM)
            return -1
        if i.sym == 0 {
            if i.offset > $ffff
                return i.offset
            return -1
        }
        if far_count == 0
            return -1
        long base = far_named(i.sym)
        if base < 0
            return -1
        return base + i.offset
    }

    sub far_operand(^^ir.Instr i) -> bool {
        return far_address(i) >= 0
    }

    sub far_line(str text) {
        put("    ")
        put(text)
        nl()
    }

    ; "    mnemonic  p8_regfile+N" for byte k of the value's place
    sub far_cell(str mnemonic, ubyte k) {
        put("    ")
        put(mnemonic)
        put("  p8_regfile+")
        putn(far_cells + k)
        nl()
    }

    ; On the 65816 an instruction can name an address of 24 bits itself ("lda $040000",
    ; and with ",x"), so a far operand at a known address needs no pointer: far_byte
    ; writes that address while far_long is set.
    bool far_long = false
    bool far_long_x = false
    long far_long_address = 0

    ; the pointer to the operand of i: its address, and the index when it has one
    sub far_pointer(long address, ^^ir.Instr i, bool indexed) {
        if far_long {
            far_long_address = address
            far_long_x = indexed
            if indexed
                index_to_x(i)           ; (only x indexes an address of 24 bits)
            return
        }
        ubyte bytes = 3
        if c45
            bytes = 4
        ubyte k
        if indexed
            index_to_y(i)           ; (the index times the element size, as for an array nearby)
        for k in 0 to bytes - 1 {
            put("    lda  #")
            putn((address >> (k * 8)) & 255)
            nl()
            if indexed and k == 0 {
                far_line("sty  P8ZP_SCRATCH_W1")
                far_line("clc")
                far_line("adc  P8ZP_SCRATCH_W1")
            }
            else if indexed
                far_line("adc  #0")
            put("    sta  P8ZP_SCRATCH_W1+")
            putn(k)
            nl()
        }
    }

    ; A = byte k behind the pointer, or the other way round
    sub far_byte(str mnemonic, ubyte k) {
        if far_long {
            ; (an instruction like any other for the peephole passes: they see what
            ; becomes of A)
            buf.clear(nb)
            buf.add_str(nb, "@l ")
            buf.add_long(nb, far_long_address + k)
            if far_long_x
                buf.add_str(nb, ",x")
            buf.add_byte(nb, 0)
            ins(mnemonic, strtab.intern_cstr(nb.data))
            return
        }
        if c45 {
            put("    ldz  #")
            putn(k)
            nl()
            put("    ")
            put(mnemonic)
            far_line("  [P8ZP_SCRATCH_W1],z")
        }
        else {
            put("    ldy  #")
            putn(k)
            nl()
            put("    ")
            put(mnemonic)
            far_line("  [P8ZP_SCRATCH_W1],y")
        }
    }

    ; A load or store through a register that is a long: an address in far memory that
    ; the program worked out.  The register's bytes are the pointer.
    sub far_indirect(^^ir.Instr i) {
        ubyte size = type_size(i.type)
        ubyte bytes = 3
        if c45 {
            bytes = 4
            q_flush()
        }
        ubyte k
        for k in 0 to bytes - 1 {
            lda_reg(i.r2, k)
            if i.offset != 0 {
                ; (a displacement: added in)
                if k == 0
                    far_line("clc")
                put("    adc  #")
                putn((i.offset >> (k * 8)) & 255)
                nl()
            }
            put("    sta  P8ZP_SCRATCH_W1+")
            putn(k)
            nl()
        }
        if i.op == ir.OP_LOADI {
            if c45 and size == 4 {
                far_line("ldz  #0")
                far_line("ldq  [P8ZP_SCRATCH_W1],z")
                far_cell("stq", 0)
            }
            else for k in 0 to size - 1 {
                far_byte("lda", k)
                far_cell("sta", k)
            }
            if c45
                far_line("ldz  #0")
            ; (from its place in the register file into the register, as any value)
            for k in 0 to size - 1 {
                far_cell("lda", k)
                sta_reg(i.r1, k)
            }
            return
        }
        for k in 0 to size - 1 {
            if i.op == ir.OP_STOREZI
                far_line("lda  #0")
            else {
                lda_reg(i.r1, k)
                far_cell("sta", 4)      ; (through memory: the peephole passes do not see A go into the store)
                far_cell("lda", 4)
            }
            far_byte("sta", k)
        }
        if c45
            far_line("ldz  #0")
    }

    sub far_instruction(^^ir.Instr i) {
        ubyte size = type_size(i.type)
        bool indexed = i.op == ir.OP_LOADX or i.op == ir.OP_STOREX or i.op == ir.OP_STOREZX
        bool only_writes = i.op == ir.OP_STOREM or i.op == ir.OP_STOREZM or i.op == ir.OP_STOREIM or i.op == ir.OP_STOREX or i.op == ir.OP_STOREZX
        bool only_reads = i.op == ir.OP_LOADM or i.op == ir.OP_LOADMZ or i.op == ir.OP_LOADX or (i.mode == ir.M_RM and not only_writes)
        ubyte k
        long address = far_address(i)
        ^^ubyte saved_sym = i.sym
        if c45
            q_flush()               ; (nothing in the 32-bit register across this)
        far_long = not c45
        if far_long and (i.op == ir.OP_LOADM or i.op == ir.OP_LOADX) and i.type != ir.T_FLOAT {
            ; a plain load: from far memory into the register
            far_pointer(address, i, indexed)
            for k in 0 to size - 1 {
                far_byte("lda", k)
                sta_reg(i.r1, k)
            }
            far_long = false
            return
        }
        if far_long and (i.op == ir.OP_STOREM or i.op == ir.OP_STOREX) and i.type != ir.T_FLOAT {
            ; a plain store: from the register into far memory
            far_pointer(address, i, indexed)
            for k in 0 to size - 1 {
                lda_reg(i.r1, k)
                far_byte("sta", k)
            }
            far_long = false
            return
        }
        if far_long and (i.op == ir.OP_STOREZM or i.op == ir.OP_STOREZX) and i.type != ir.T_FLOAT {
            far_pointer(address, i, indexed)
            ins_imm("lda", 0)
            for k in 0 to size - 1
                far_byte("sta", k)
            far_long = false
            return
        }
        if far_long and i.op == ir.OP_STOREIM and i.type != ir.T_FLOAT {
            ; a constant: each byte, and one that is the byte before it is in A already
            far_pointer(address, i, false)
            ubyte before = 0
            for k in 0 to size - 1 {
                ubyte part = ((i.value >> (k * 8)) & 255) as ubyte
                if k == 0 or part != before
                    ins_imm("lda", part)
                before = part
                far_byte("sta", k)
            }
            far_long = false
            return
        }
        if not only_writes {
            far_pointer(address, i, indexed)
            if c45 and size == 4 {
                ; four bytes are one load and one store on this CPU
                far_line("ldz  #0")
                far_line("ldq  [P8ZP_SCRATCH_W1],z")
                far_cell("stq", 0)
            }
            else for k in 0 to size - 1 {
                far_byte("lda", k)
                far_cell("sta", k)
            }
            if c45
                far_line("ldz  #0")
        }
        ; the instruction itself, on the value's place in the register file
        ubyte saved_op = i.op
        long saved_offset = i.offset
        uword saved_r2 = i.r2
        ubyte saved_scale = i.scale
        buf.clear(nb)
        buf.add_str(nb, "p8_regfile+")
        buf.add_long(nb, far_cells)
        buf.add_byte(nb, 0)
        i.sym = strtab.intern_cstr(nb.data)
        i.offset = 0
        when i.op {
            ir.OP_LOADX -> i.op = ir.OP_LOADM
            ir.OP_STOREX -> i.op = ir.OP_STOREM
            ir.OP_STOREZX -> i.op = ir.OP_STOREZM
        }
        if indexed {
            i.scale = 1
            i.r2 = 0
        }
        instruction(i)
        if c45
            q_flush()
        i.op = saved_op
        i.sym = saved_sym
        i.offset = saved_offset
        i.r2 = saved_r2
        i.scale = saved_scale
        if not only_reads {
            ; (the pointer again: the instruction may have used the scratch words)
            far_pointer(address, i, indexed)
            if c45 and size == 4 {
                far_cell("ldq", 0)
                far_line("stq  [P8ZP_SCRATCH_W1]")
            }
            else for k in 0 to size - 1 {
                far_cell("lda", k)
                far_byte("sta", k)
            }
            if c45
                far_line("ldz  #0")
        }
        far_long = false
    }

    ; ---- the 45GS02's 32-bit instructions ----
    ; A, X, Y and Z together are the register Q.  A long is loaded, combined and stored
    ; in one instruction each: "ldq a / clc / adq b / stq a" where the 6502 has four
    ; times "lda / adc / sta".  The lines are written as they are (the peephole passes
    ; know neither the instructions nor that a register's cell is named in them: a
    ; long's cell has a fixed place on this CPU).  Z is zero again after every such piece
    ; of code: the machine's ROM is written for that, and so is "stz" as the 65C02's.

    ; What a line does to "the N and Z flags are those of Q's value".  The instructions
    ; that make a value in Q set them for all 32 bits.  stq does not leave them alone:
    ; its prefix is two real "neg a", which set them by the low byte (seen in xmega65,
    ; and the CPU's own description has the prefix executed).
    sub q_note(str mnemonic) {
        if mnemonic[0] == 's' and mnemonic[1] == 't' and mnemonic[2] == 'q'
            qflags = false
        else if mnemonic[2] == 'q' and mnemonic[0] != 'c' and mnemonic[0] != 'b'
            qflags = true           ; ldq adq sbq anq orq eoq inq deq
        else if mnemonic[0] == '.' or (mnemonic[3] == ' ' and mnemonic[4] == ' ' and mnemonic[5] == 'q')
            qflags = true           ; the negation's bytes; asl q, lsr q, asr q
        else if mnemonic[0] != 'c' or mnemonic[1] != 'l' or mnemonic[2] != 'c' {
            if mnemonic[0] != 's' or mnemonic[1] != 'e' or mnemonic[2] != 'c'
                qflags = false      ; (anything but clc and sec)
        }
    }

    sub q_text(str mnemonic, ^^ubyte operand, long offset) {
        q_note(mnemonic)
        put("    ")
        put(mnemonic)
        if operand != 0 {
            put("  ")
            put(operand)
            if offset > 0 {
                put("+")
                putn(offset)
            }
            else if offset < 0
                putn(offset)
        }
        nl()
    }

    sub q_reg(str mnemonic, uword r) {
        q_text(mnemonic, cell(r, 0), 0)
    }

    sub q_mem(str mnemonic, ^^ir.Instr i) {
        memory_operand(i)
        q_text(mnemonic, mem_symbol, mem_offset)
    }

    ; Q = a constant
    sub q_constant(quad value) {
        qflags = false
        ^^ubyte letters = "axyz"
        ubyte k
        for k in 0 to 3 {
            put("    ld")
            buf.add_byte(w(), letters[k])
            put("  #")
            putn(((value >> (k * 8)) & 255) as long)
            nl()
        }
    }

    ; Between instructions on longs the value stays in Q, and a long that was only
    ; fetched from a variable is that variable until something stores to it: so
    ; "c = a + b" is "ldq a / clc / adq b / stq c".  What Q holds, which registers are
    ; variables for now, and whether Z has to be made zero again:
    uword qacc = 0                  ; the register whose value Q holds, or 0
    bool qacc_stored = true         ; and its cell (or the variable it is) has that value too
    bool qz_dirty = false
    bool qflags = false             ; the N and Z flags are those of Q's value (the instruction that made it set them)
    const ubyte QALIASES = 8
    uword[QALIASES] qalias_reg
    ^^pointer qalias_src = 0        ; the LOADM instructions they came from
    ubyte qalias_count = 0
    long q_index = 0                ; the instruction's place in its chunk
    ^^ir.Sub q_scanned_sub = 0      ; the subroutine q_sub_longs is about
    bool q_sub_longs = false        ; it has instructions on longs: Z is used in it

    ; Z is zero again.  The machine's ROM is written for a Z of zero, so it is made zero
    ; before the generated code is left: before a call, a return, a jump out of the
    ; subroutine and assembly text.  In between it is whatever the last 32-bit
    ; instruction left: the generated code itself never counts on it.
    sub z_restore() {
        if c45 and qz_dirty {
            q_text("ldz", "#0", 0)
            qz_dirty = false
        }
    }

    ; Is Z wanted zero by an instruction from i on, before the next one on longs?  Then
    ; it is made zero here, next to the 32-bit code or at the head of the chunk, and
    ; not in the middle of what the peephole passes are working on.
    sub z_wanted_from(^^ir.Instr i) -> bool {
        while i != 0 {
            if i.type == ir.T_LONG and i.scale < 200
                return false
            if z_matters(i)
                return true
            i = i.next
        }
        return false
    }

    ; does control leave the generated code with this instruction?
    sub z_matters(^^ir.Instr i) -> bool {
        when i.op {
            ir.OP_CALL, ir.OP_CALLFAR, ir.OP_CALLFARVB, ir.OP_CALLI, ir.OP_SYSCALL, ir.OP_JUMPI,
            ir.OP_RETURN, ir.OP_RETURNR, ir.OP_RETURNI -> return true
            ir.OP_JUMP -> {
                ; a jump to another subroutine
                if cursub == 0 or i.sym == 0
                    return true
                ^^ir.Chunk c = cursub.chunks
                while c != 0 {
                    if c.label != 0 and strings.compare(c.label, i.sym) == 0
                        return false
                    c = c.next
                }
                return true
            }
        }
        return i.type == ir.T_FLOAT or i.t1 == ir.T_FLOAT
    }
    ^^ir.Instr qmirror = 0          ; Q's value is also in this instruction's memory operand (it was just stored there)

    ; where each register of chunk c is named (the tables of the 65816's runs)
    sub quad_chunk(^^ir.Chunk c) {
        wchunk = c
        qacc = 0
        qacc_stored = true
        ; (Z is zero where a subroutine begins; where another chunk begins it is whatever
        ; the code that jumps there left, when the subroutine has longs at all)
        if cursub != q_scanned_sub or cursub == 0 {
            q_scanned_sub = cursub
            q_sub_longs = false
            ^^ir.Chunk sc = c
            if cursub != 0
                sc = cursub.chunks
            while sc != 0 and not q_sub_longs {
                if sc.kind != ir.C_ASM {
                    ^^ir.Instr si = sc.first
                    while si != 0 {
                        if si.type == ir.T_LONG {
                            q_sub_longs = true
                            break
                        }
                        si = si.next
                    }
                }
                if cursub == 0
                    break
                sc = sc.next
            }
            qz_dirty = false
        }
        else
            qz_dirty = q_sub_longs
        if qz_dirty and z_wanted_from(c.first)
            z_restore()
        qalias_count = 0
        qmirror = 0
        if qalias_src == 0
            qalias_src = mem.alloc(QALIASES as long * sizeof(pointer))
        ^^ir.Instr i = c.first
        ^^ir.Arg a
        while i != 0 {
            wide_reset_reg(i.r1)
            wide_reset_reg(i.r2)
            wide_reset_reg(i.r3)
            a = i.args
            while a != 0 {
                wide_reset_reg(a.reg)
                a = a.next
            }
            a = i.results
            while a != 0 {
                wide_reset_reg(a.reg)
                a = a.next
            }
            i = i.next
        }
        long index = 0
        i = c.first
        while i != 0 {
            wide_index_reg(i.r1, index)
            wide_index_reg(i.r2, index)
            wide_index_reg(i.r3, index)
            a = i.args
            while a != 0 {
                wide_index_reg(a.reg, index)
                a = a.next
            }
            a = i.results
            while a != 0 {
                wide_index_reg(a.reg, index)
                a = a.next
            }
            index++
            i = i.next
        }
    }

    ; is the register named in this chunk only?
    sub q_local(uword r) -> bool {
        if r == 0 or r >= wcap
            return false
        pointer here = wchunk
        return whome[r] == here
    }

    ; is its value wanted by the instruction at q_index + ahead or a later one?
    sub q_wanted(uword r, long ahead) -> bool {
        if not q_local(r)
            return true
        return wlast[r] >= q_index + ahead
    }

    sub q_alias(uword r) -> ^^ir.Instr {
        ubyte k = 0
        while k < qalias_count {
            if qalias_reg[k] == r
                return qalias_src[k]
            k++
        }
        return 0
    }

    sub q_unalias(uword r) {
        ubyte k = 0
        while k < qalias_count {
            if qalias_reg[k] == r {
                qalias_count--
                qalias_reg[k] = qalias_reg[qalias_count]
                qalias_src[k] = qalias_src[qalias_count]
                return
            }
            k++
        }
    }

    ; Q's value into its register's cell, when something still wants it there
    sub q_spill(long ahead) {
        if qacc != 0 and not qacc_stored and q_wanted(qacc, ahead) {
            q_reg("stq", qacc)
            qacc_stored = true
        }
    }

    ; "mnemonic  where register r's value is in memory"
    sub q_operand(str mnemonic, uword r) {
        ^^ir.Instr src = q_alias(r)
        if src != 0 {
            q_mem(mnemonic, src)
            return
        }
        if r == qacc and not qacc_stored {
            ; (it is only in Q: the operand is Q itself)
            q_reg("stq", r)
            qacc_stored = true
        }
        q_reg(mnemonic, r)
    }

    ; Q = register r
    sub q_load(uword r) {
        if qacc == r
            return
        q_spill(0)
        ^^ir.Instr src = q_alias(r)
        if src == 0 or qmirror == 0 or src.sym != qmirror.sym or src.offset != qmirror.offset or src.sym == 0 {
            q_operand("ldq", r)     ; (else: the variable it is has just been stored from Q)
        }
        else
            qflags = false
        qacc = r
        qacc_stored = true
        qz_dirty = true
    }

    ; what is in Q now is the new value of register r
    sub q_result(uword r) {
        if qacc != r
            q_spill(1)
        qmirror = 0
        q_unalias(r)
        qacc = r
        qacc_stored = false
        qz_dirty = true
    }

    ; a register that is a variable for now gets a cell of its own
    ; does a register that is a variable for now have to get its cell before the
    ; instruction after this one?
    sub q_aliases_wanted() -> bool {
        ubyte k = 0
        while k < qalias_count {
            if q_wanted(qalias_reg[k], 1)
                return true
            k++
        }
        return false
    }

    sub q_materialize(ubyte k) {
        uword r = qalias_reg[k]
        ^^ir.Instr src = qalias_src[k]
        q_spill(0)
        q_mem("ldq", src)
        q_reg("stq", r)
        qmirror = 0
        qacc = r
        qacc_stored = true
        qz_dirty = true
    }

    ; instruction i is about to store to its memory operand: the registers that are
    ; that variable for now have its old value
    sub q_written(^^ir.Instr i) {
        qmirror = 0
        ubyte k = 0
        while k < qalias_count {
            ^^ir.Instr src = qalias_src[k]
            if src.sym == 0 or i.sym == 0 or src.sym == i.sym {
                uword r = qalias_reg[k]
                if q_wanted(r, 0)
                    q_materialize(k)
                q_unalias(r)
                continue            ; (another one is at k now)
            }
            k++
        }
    }

    ; before an instruction that is not written with Q, and at the end of a chunk:
    ; every value where the 6502's code looks for it, and Z zero
    sub q_flush() {
        if qacc == 0 and qalias_count == 0
            return
        q_spill(0)
        while qalias_count != 0 {
            if q_wanted(qalias_reg[0], 0)
                q_materialize(0)
            q_unalias(qalias_reg[0])
        }
        qz_keep_flags = false
        qflags = false
        qmirror = 0
        qacc = 0
        qacc_stored = true
    }

    sub q_carry(ubyte carry) {
        when carry {
            1 -> q_text("clc", 0, 0)
            2 -> q_text("sec", 0, 0)
        }
    }

    ; register = register op (register, constant or memory); carry 1: an addition,
    ; 2: a subtraction
    sub q_combine(^^ir.Instr i, str mnemonic, ubyte carry) -> bool {
        when i.mode {
            ir.M_RI, ir.M_RIT -> {
                if qconst_count < len(qconsts) {
                    ; the constant is four bytes in the data
                    q_load(i.r1)
                    q_carry(carry)
                    void q_literal(mnemonic, i.value)
                    q_result(i.r1)
                    return true
                }
                ; the constant in Q, combined with the register; a subtraction adds the negative
                quad value = i.value
                if carry == 2
                    value = 0 - value
                if qacc == i.r1 and not qacc_stored {
                    q_reg("stq", i.r1)
                    qacc_stored = true
                }
                q_spill(0)
                q_constant(value)
                qmirror = 0
                qacc = 0
                qz_dirty = true
                if carry != 0
                    q_text("clc", 0, 0)
                if carry == 2
                    q_operand("adq", i.r1)
                else
                    q_operand(mnemonic, i.r1)
            }
            ir.M_RM -> {
                q_load(i.r1)
                q_carry(carry)
                q_mem(mnemonic, i)
            }
            ir.M_RR -> {
                if carry != 2 and qacc == i.r2 and i.r1 != i.r2 {
                    ; the second operand is the one in Q, and the order does not matter
                    q_carry(carry)
                    q_operand(mnemonic, i.r1)
                }
                else {
                    q_load(i.r1)
                    q_carry(carry)
                    q_operand(mnemonic, i.r2)
                }
            }
            else -> return false
        }
        q_result(i.r1)
        return true
    }

    ; memory = memory op (a register or a constant)
    sub q_combine_memory(^^ir.Instr i, str mnemonic, ubyte carry) -> bool {
        if i.mode != ir.M_IM and i.mode != ir.M_RM and i.mode != ir.M_M
            return false
        q_written(i)
        if i.mode == ir.M_IM {
            quad value = i.value
            if carry == 2
                value = 0 - value
            q_spill(0)
            q_constant(value)
            if carry != 0
                q_text("clc", 0, 0)
            if carry == 2
                q_mem("adq", i)
            else
                q_mem(mnemonic, i)
        }
        else if carry == 2 {
            ; memory - register
            if qacc == i.r1 and not qacc_stored {
                q_reg("stq", i.r1)
                qacc_stored = true
            }
            q_spill(0)
            q_mem("ldq", i)
            q_text("sec", 0, 0)
            q_operand(mnemonic, i.r1)
        }
        else {
            q_load(i.r1)
            q_spill(1)              ; (Q is the sum next, not the register)
            q_carry(carry)
            q_mem(mnemonic, i)
        }
        q_mem("stq", i)
        qmirror = 0
        qacc = 0
        qacc_stored = true
        qz_dirty = true
        return true
    }

    ; a one-operand instruction on a register or on memory: the given line, that many times
    sub q_inplace(^^ir.Instr i, str line, ubyte times) {
        if i.mode == ir.M_M {
            q_written(i)
            q_spill(0)
            q_mem("ldq", i)
            repeat times
                q_text(line, 0, 0)
            q_mem("stq", i)
            qmirror = 0
            qacc = 0
            qacc_stored = true
            qz_dirty = true
            return
        }
        q_load(i.r1)
        repeat times
            q_text(line, 0, 0)
        q_result(i.r1)
    }

    long qdiv_cells = 0             ; where p8_qdivs keeps its numbers: 18 bytes of the register file
    bool qdiv_used = false
    bool hardware_math = false      ; the MEGA65's multiplier and divider are there (the 45GS02 is that machine's CPU)
    bool q_long_args = false        ; the long arguments of the call in hand are in their parameters already
    bool qz_keep_flags = false      ; what follows reads the flags: making Z zero must leave them alone

    ; There is no "adq #constant": a constant that is an operand is four bytes in the
    ; program's data, p8_qconst_N.
    long[128] qconsts
    ubyte qconst_count = 0

    ; "mnemonic  p8_qconst_N" for the constant; false when there is no room for another
    sub q_literal(str mnemonic, quad value) -> bool {
        long v = (value & $ffffffff) as long
        ubyte k = 0
        while k < qconst_count and qconsts[k] != v
            k++
        if k == qconst_count {
            if qconst_count == len(qconsts)
                return false
            qconsts[k] = v
            qconst_count++
        }
        q_note(mnemonic)
        put("    ")
        put(mnemonic)
        put("  p8_qconst_")
        putn(k)
        nl()
        return true
    }

    ; "mnemonic  byte k of where register r's value is": the variable it is, or its cell
    sub q_byte(str mnemonic, uword r, ubyte k) {
        ^^ir.Instr src = q_alias(r)
        if src != 0 {
            memory_operand(src)
            ins_at(mnemonic, mem_symbol, mem_offset + k)
        }
        else
            ins(mnemonic, cell(r, k))
    }

    ; before a comparison: the registers that are variables and are wanted afterwards
    ; get their cells now (afterwards the flags must stay as they are)
    sub q_before_compare() {
        q_spill(0)
        ubyte k = 0
        while k < qalias_count {
            if q_wanted(qalias_reg[k], 1) {
                ; (it stays that variable for this instruction)
                uword r = qalias_reg[k]
                ^^ir.Instr src = qalias_src[k]
                q_mem("ldq", src)
                q_reg("stq", r)
                qmirror = 0
                qacc = 0
                qacc_stored = true
                qz_dirty = true
            }
            k++
        }
    }

    ; "mnemonic  the second operand of a comparison": a constant, memory or a register
    sub q_compare_operand(^^ir.Instr i, str mnemonic) -> bool {
        when i.mode {
            ir.M_RI, ir.M_RIT, ir.M_IM -> return q_literal(mnemonic, i.value)
            ir.M_RM, ir.M_M -> q_mem(mnemonic, i)
            else -> q_operand(mnemonic, i.r2)
        }
        return true
    }

    ; Q = the second operand of a comparison
    sub q_load_second(^^ir.Instr i) -> bool {
        when i.mode {
            ir.M_RI, ir.M_RIT, ir.M_IM -> {
                q_spill(0)
                qacc = 0
                qmirror = 0
                qz_dirty = true
                return q_literal("ldq", i.value)
            }
            ir.M_RM, ir.M_M -> {
                q_spill(0)
                q_mem("ldq", i)
                qacc = 0
                qmirror = 0
                qz_dirty = true
            }
            else -> q_load(i.r2)
        }
        return true
    }

    ; after a comparison that branches itself: nothing is in Q or a variable any more,
    ; and Z is zero again with the flags as the comparison left them
    sub q_after_compare() {
        qalias_count = 0
        qmirror = 0
        qacc = 0
        qacc_stored = true
    }

    ; a comparison of longs that branches: unsigned with cpq, signed by the sign of the
    ; difference (the overflow flag turns it round; the top byte is in Z)
    sub q_compare_branch(^^ir.Instr i) -> bool {
        bool swapped = false
        bool signed = false
        ^^ubyte branch = "bcs"
        when i.op {
            ir.OP_BGE, ir.OP_BGER -> branch = "bcs"
            ir.OP_BLT -> branch = "bcc"
            ir.OP_BGT, ir.OP_BGTR -> {
                swapped = true
                branch = "bcc"
            }
            ir.OP_BLE -> {
                swapped = true
                branch = "bcs"
            }
            ir.OP_BGES, ir.OP_BGESR -> {
                signed = true
                branch = "bpl"
            }
            ir.OP_BLTS -> {
                signed = true
                branch = "bmi"
            }
            ir.OP_BGTS, ir.OP_BGTSR -> {
                signed = true
                swapped = true
                branch = "bmi"
            }
            ir.OP_BLES -> {
                signed = true
                swapped = true
                branch = "bpl"
            }
            else -> return false
        }
        if qconst_count == len(qconsts) and i.mode != ir.M_RR
            return false            ; (no room for a constant)
        q_before_compare()
        if swapped {
            ; the operand against the register
            void q_load_second(i)
            q_spill(1)
            if signed {
                q_spill(1)
                q_text("sec", 0, 0)
                q_operand("sbq", i.r1)
            }
            else
                q_operand("cpq", i.r1)
        }
        else {
            q_load(i.r1)
            q_spill(1)
            if signed {
                q_spill(1)
                q_text("sec", 0, 0)
                void q_compare_operand(i, "sbq")
            }
            else {
                void q_compare_operand(i, "cpq")
                qflags = false
            }
                qflags = false
        }
        if signed {
            qacc_stored = true      ; (Q is the difference now)
            qacc = 0
            q_text("tza", 0, 0)
            q_text("bvc", "+", 0)
            q_text("eor", "#$80", 0)
            put("+")
            nl()
        }
        q_after_compare()
        ins(branch, i.sym)
        return true
    }

    ; the long arguments of a call that go into parameter variables: from Q, or from
    ; the variable the register is
    sub quad_arguments(^^ir.Instr i) {
        if i.op == ir.OP_CALL and convention(find_sub(i.sym)) != CONV_NONE
            return
        ^^ir.Arg a = i.args
        while a != 0 {
            if a.slot == 255 and a.name != 0 and a.type == ir.T_LONG and a.reg != 0 {
                q_load(a.reg)
                if starts_with(a.name, "cx16.")
                    q_text("stq", a.name, 0)
                else {
                    if pb == 0
                        pb = buf.new(128)
                    buf.clear(pb)
                    buf.add_str(pb, i.sym)
                    buf.add_byte(pb, '.')
                    buf.add_str(pb, a.name)
                    buf.add_byte(pb, 0)
                    q_text("stq", pb.data, 0)
                }
                q_long_args = true
                ; (the call is the last that wants it: no cell of its own for it)
                if q_local(a.reg) and wlast[a.reg] <= q_index {
                    q_unalias(a.reg)
                    if qacc == a.reg
                        qacc_stored = true
                }
            }
            a = a.next
        }
    }

    ; a long instruction with the 32-bit instructions; false where the instruction is
    ; not one of these (the caller then has q_flush put everything where the 6502's
    ; code looks for it)
    sub quad_instruction(^^ir.Instr i) -> bool {
        when i.op {
            ir.OP_LOAD -> {
                if i.sym != 0
                    return false
                q_spill(0)
                q_constant(i.value)
                q_result(i.r1)
                return true
            }
            ir.OP_LOADM -> {
                if qacc == i.r1 {
                    qacc = 0
                    qacc_stored = true
                }
                q_unalias(i.r1)
                if q_local(i.r1) and qalias_count < QALIASES {
                    ; it is that variable until something stores there
                    qalias_reg[qalias_count] = i.r1
                    qalias_src[qalias_count] = i
                    qalias_count++
                    return true
                }
                q_spill(0)
                q_mem("ldq", i)
                q_reg("stq", i.r1)
                qmirror = 0
                qacc = i.r1
                qacc_stored = true
                qz_dirty = true
                return true
            }
            ir.OP_LOADR -> {
                q_load(i.r2)
                q_result(i.r1)
                return true
            }
            ir.OP_STOREM -> {
                q_written(i)
                q_load(i.r1)
                q_mem("stq", i)
                qmirror = i
                return true
            }
            ir.OP_RETURNR -> {
                ; a long goes back in the virtual registers R14 and R15
                q_load(i.r1)
                q_text("stq", "cx16.r14", 0)
                z_restore()
                qalias_count = 0
                qmirror = 0
                qacc = 0
                qacc_stored = true
                return_uses(4)
                return true
            }
            ir.OP_MUL, ir.OP_MULR, ir.OP_MULS, ir.OP_MULSR -> {
                ; The MEGA65's multiplier: two 32-bit numbers at $d770 and $d774, their
                ; product at $d778 at once.  (The low half is the same for signed numbers.)
                if not hardware_math or i.scale == 250
                    return false
                if i.mode != ir.M_RR and i.mode != ir.M_RM and (qconst_count == len(qconsts) or (i.mode != ir.M_RI and i.mode != ir.M_RIT))
                    return false
                q_load(i.r1)
                q_text("stq", "$d770", 0)
                if i.mode == ir.M_RR and i.r2 == i.r1
                    q_text("stq", "$d774", 0)
                else {
                    q_spill(1)
                    qmirror = 0
                    void q_compare_operand(i, "ldq")
                    q_text("stq", "$d774", 0)
                }
                qacc_stored = true      ; (the register's old value is not wanted: it gets the product)
                qacc = 0
                q_text("ldq", "$d778", 0)
                q_result(i.r1)
                return true
            }
            ir.OP_DIVS, ir.OP_DIVSR, ir.OP_DIV, ir.OP_DIVR -> {
                ; The MEGA65's divider, by way of a routine of the program's own that
                ; sees to the signs: the divisor in its cell, the dividend in Q, and the
                ; quotient comes back in Q.
                if not hardware_math
                    return false
                if i.mode != ir.M_RR and i.mode != ir.M_RM and (qconst_count == len(qconsts) or (i.mode != ir.M_RI and i.mode != ir.M_RIT))
                    return false
                q_spill(0)
                qmirror = 0
                void q_compare_operand(i, "ldq")
                qacc = 0
                qacc_stored = true
                qz_dirty = true
                put("    stq  p8_regfile+")
                putn(qdiv_cells + 4)
                nl()
                q_load(i.r1)
                q_text("jsr", "p8_qdivs", 0)
                qdiv_used = true
                qacc_stored = true
                qacc = 0
                q_result(i.r1)
                return true
            }
            ir.OP_CMP, ir.OP_CMPI -> {
                ; the flags for the branch that follows: all of them are those of the
                ; whole 32 bits
                if i.next != 0 and (i.next.op == ir.OP_BSTEQ or i.next.op == ir.OP_BSTNE or i.next.op == ir.OP_BSTNEG or i.next.op == ir.OP_BSTPOS)
                        and (i.mode == ir.M_RI or i.mode == ir.M_RIT) and (i.value & $ffffffff) == 0
                        and qacc == i.r1 and not q_aliases_wanted() and (qflags or qacc_stored or q_wanted(i.r1, 1)) {
                    ; against zero, and the value is in Q: the instruction that made it
                    ; set the flags for all 32 bits.  When it has to be stored first, the
                    ; store spoils them, and loading it again is the shortest way to
                    ; have them back.
                    q_spill(1)
                    if not qflags
                        q_reg("ldq", i.r1)
                    qalias_count = 0
                    return true
                }
                if i.next != 0 and (i.next.op == ir.OP_BSTEQ or i.next.op == ir.OP_BSTNE) and (i.mode == ir.M_RR or i.mode == ir.M_RI or i.mode == ir.M_RIT or i.mode == ir.M_RM) {
                    ; equal or not: a byte at a time, which is settled by the first byte
                    ; most of the time
                    q_before_compare()      ; (nothing may load Q between this and the branch)
                    if qacc == i.r1 and not qacc_stored {
                        q_reg("stq", i.r1)
                        qacc_stored = true
                    }
                    if i.mode == ir.M_RR and qacc == i.r2 and not qacc_stored {
                        q_reg("stq", i.r2)
                        qacc_stored = true
                    }
                    qacc = 0
                    qmirror = 0
                    qflags = false
                    ubyte ek
                    if (i.mode == ir.M_RI or i.mode == ir.M_RIT) and (i.value & $ffffffff) == 0 {
                        q_byte("lda", i.r1, 3)
                        q_byte("ora", i.r1, 2)
                        q_byte("ora", i.r1, 1)
                        q_byte("ora", i.r1, 0)
                        qalias_count = 0
                        return true
                    }
                    for ek in 0 to 3 {
                        q_byte("lda", i.r1, ek)
                        when i.mode {
                            ir.M_RR -> q_byte("cmp", i.r2, ek)
                            ir.M_RM -> {
                                memory_operand(i)
                                ins_at("cmp", mem_symbol, mem_offset + ek)
                            }
                            else -> ins_imm("cmp", ((i.value >> (ek * 8)) & 255) as long)
                        }
                        if ek != 3
                            ins("bne", "+")
                    }
                    anon_label("+")
                    qalias_count = 0
                    return true
                }
                if qconst_count == len(qconsts) and i.mode != ir.M_RR
                    return false
                q_before_compare()
                q_load(i.r1)
                q_spill(1)              ; (before the comparison: a store spoils the flags)
                void q_compare_operand(i, "cpq")
                qalias_count = 0
                qz_keep_flags = true
                return true
            }
            ir.OP_BGT, ir.OP_BGTR, ir.OP_BLT, ir.OP_BGE, ir.OP_BGER, ir.OP_BLE,
            ir.OP_BGTS, ir.OP_BGTSR, ir.OP_BGES, ir.OP_BGESR, ir.OP_BLTS, ir.OP_BLES -> return q_compare_branch(i)
            ir.OP_AND, ir.OP_ANDR -> return q_combine(i, "anq", 0)
            ir.OP_OR, ir.OP_ORR -> return q_combine(i, "orq", 0)
            ir.OP_XOR, ir.OP_XORR -> return q_combine(i, "eoq", 0)
            ir.OP_ADD, ir.OP_ADDR -> return q_combine(i, "adq", 1)
            ir.OP_SUB, ir.OP_SUBR -> return q_combine(i, "sbq", 2)
            ir.OP_ANDM -> return q_combine_memory(i, "anq", 0)
            ir.OP_ORM -> return q_combine_memory(i, "orq", 0)
            ir.OP_XORM -> return q_combine_memory(i, "eoq", 0)
            ir.OP_ADDM, ir.OP_ADDIM -> return q_combine_memory(i, "adq", 1)
            ir.OP_SUBM, ir.OP_SUBIM -> return q_combine_memory(i, "sbq", 2)
            ir.OP_INC, ir.OP_INCM -> {
                ; (a long in memory: the 6502's "inc / bne" goes no further than the first
                ; byte most of the time)
                if i.mode == ir.M_M or (qacc != i.r1 and q_alias(i.r1) == 0)
                    return false
                q_inplace(i, "inq", 1)
                return true
            }
            ir.OP_DEC, ir.OP_DECM -> {
                q_inplace(i, "deq", 1)
                return true
            }
            ir.OP_NEG, ir.OP_NEGM -> {
                q_inplace(i, ".byte  $42, $42, $42    ; negq", 1)
                return true
            }
            ir.OP_LSL, ir.OP_LSLM -> {
                q_inplace(i, "asl  q", 1)
                return true
            }
            ir.OP_LSR, ir.OP_LSRM -> {
                q_inplace(i, "lsr  q", 1)
                return true
            }
            ir.OP_ASR, ir.OP_ASRM -> {
                q_inplace(i, "asr  q", 1)
                return true
            }
            ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI -> {
                ; a few places: that many shifts of Q (more is quicker by moving bytes)
                if i.value < 1 or i.value > 4 or i.mode == ir.M_M
                    return false
                if i.op == ir.OP_LSLI
                    q_inplace(i, "asl  q", i.value as ubyte)
                else if i.op == ir.OP_LSRI
                    q_inplace(i, "lsr  q", i.value as ubyte)
                else
                    q_inplace(i, "asr  q", i.value as ubyte)
                return true
            }
        }
        return false
    }

    sub instruction(^^ir.Instr i) {
        if i.op != ir.OP_NOP {
            prev_instr = this_instr
            this_instr = i
            ; (what FAC1 holds is only known from one instruction to the next)
            fac_prev = fac_reg
            fac_reg = 0
            fwait_prev = fwait
            fwait = 0
        }
        if far_operand(i) {
            far_instruction(i)
            return
        }
        if types.far_bits != 0 and (i.op == ir.OP_LOADI or i.op == ir.OP_STOREI or i.op == ir.OP_STOREZI) and i.r2 != 0 and i.r2 <= ir.regcount and ir.regtypes[i.r2] == ir.T_LONG {
            far_indirect(i)
            return
        }
        if c45 {
            ; (not an instruction that is marked as part of a fused pattern)
            if i.type == ir.T_LONG and i.scale < 200 and quad_instruction(i)
                return
            q_long_args = false
            if i.op == ir.OP_CALL or i.op == ir.OP_CALLFAR or i.op == ir.OP_CALLFARVB
                quad_arguments(i)
            q_flush()
            ; (not between a comparison and the branch on its flags: after the branch)
            if qz_dirty and i.op != ir.OP_BSTEQ and i.op != ir.OP_BSTNE and i.op != ir.OP_BSTNEG and i.op != ir.OP_BSTPOS and z_wanted_from(i)
                z_restore()
        }
        if i.scale == 252
            return                  ; (written with the head of its chain)
        if i.scale == 251 {
            ay_chain(i)
            return
        }
        ubyte size = type_size(i.type)
        ubyte k
        if i.type == ir.T_FLOAT or i.t1 == ir.T_FLOAT or (i.op >= ir.OP_FFROMUB and i.op <= ir.OP_FCOMP) {
            ; (the loads, stores and copies of a float are those of five bytes, below)
            if float_instruction(i)
                return
        }
        when i.op {
            ir.OP_NOP -> {
            }
            ir.OP_LOAD -> {
                if i.sym != 0 and far_count != 0 and far_named(i.sym) >= 0 {
                    error("the address of a variable in far memory does not fit a pointer (it cannot be passed or pointed to yet)", i.sym)
                    return
                }
                if i.sym != 0 {
                    ; the address of a symbol (of a subroutine in an overlay: its thunk's)
                    ^^ubyte lsym = i.sym
                    if overlay_max != 0 and i.offset == 0 and overlay_of(lsym) != 0 and find_sub(lsym) != 0
                        lsym = thunk_name(lsym)
                    ins_half("lda", '<', lsym, i.offset)
                    sta_reg(i.r1, 0)
                    ins_half("lda", '>', lsym, i.offset)
                    sta_reg(i.r1, 1)
                }
                else {
                    for k in 0 to size - 1 {
                        ins_imm("lda", ((i.value >> (k * 8)) & 255) as long)
                        sta_reg(i.r1, k)
                    }
                }
            }
            ir.OP_LOADM -> {
                memory_operand(i)
                for k in 0 to size - 1 {
                    ins_at("lda", mem_symbol, mem_offset + k)
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_LOADMZ -> {
                memory_operand(i)
                ins_at("lda", mem_symbol, mem_offset)
                sta_reg(i.r1, 0)
                ins("lda", "#0")
                sta_reg(i.r1, 1)
            }
            ir.OP_LOADR -> {
                for k in 0 to size - 1 {
                    lda_reg(i.r2, k)
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_LOADX -> {
                memory_operand(i)
                index_to_y(i)
                for k in 0 to size - 1 {
                    ins_indexed("lda", mem_symbol, mem_offset + k, 'y')
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_STOREX, ir.OP_STOREZX -> {
                memory_operand(i)
                index_to_y(i)
                for k in 0 to size - 1 {
                    if i.op == ir.OP_STOREZX
                        ins("lda", "#0")
                    else
                        lda_reg(i.r1, k)
                    ins_indexed("sta", mem_symbol, mem_offset + k, 'y')
                }
            }
            ir.OP_LOADI -> {
                pointer_to_scratch(i.r2)
                if i.scale == 255 {
                    ; a byte at the pointer plus a byte index (fuse_indexed)
                    ins("ldy", cell(i.r3, 0))
                    ins("lda", "(P8ZP_SCRATCH_W1),y")
                    sta_reg(i.r1, 0)
                    return
                }
                for k in 0 to size - 1 {
                    ins_imm("ldy", i.offset + k)
                    ins("lda", "(P8ZP_SCRATCH_W1),y")
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_STOREI, ir.OP_STOREZI -> {
                pointer_to_scratch(i.r2)
                if i.scale == 255 {
                    ins("ldy", cell(i.r3, 0))
                    if i.op == ir.OP_STOREZI
                        ins("lda", "#0")
                    else
                        lda_reg(i.r1, 0)
                    ins("sta", "(P8ZP_SCRATCH_W1),y")
                    return
                }
                for k in 0 to size - 1 {
                    ins_imm("ldy", i.offset + k)
                    if i.op == ir.OP_STOREZI
                        ins("lda", "#0")
                    else
                        lda_reg(i.r1, k)
                    ins("sta", "(P8ZP_SCRATCH_W1),y")
                }
            }
            ir.OP_STOREM -> {
                memory_operand(i)
                if size == 2 and high_first(i) {
                    ; (the high byte is in A still)
                    lda_reg(i.r1, 1)
                    ins_at("sta", mem_symbol, mem_offset + 1)
                    lda_reg(i.r1, 0)
                    ins_at("sta", mem_symbol, mem_offset)
                    return
                }
                for k in 0 to size - 1 {
                    lda_reg(i.r1, k)
                    ins_at("sta", mem_symbol, mem_offset + k)
                }
            }
            ir.OP_STOREZM -> {
                memory_operand(i)
                for k in 0 to size - 1
                    store_zero(mem_symbol, mem_offset + k)
            }
            ir.OP_STOREIM -> {
                memory_operand(i)
                for k in 0 to size - 1 {
                    ubyte part = ((i.value >> (k * 8)) & 255) as ubyte
                    if part == 0
                        store_zero(mem_symbol, mem_offset + k)
                    else {
                        ins_imm("lda", part)
                        ins_at("sta", mem_symbol, mem_offset + k)
                    }
                }
            }
            ir.OP_LOADHR -> {
                ; from a CPU register: slot 0 A, 1 X, 2 Y, 3 AX, 4 AY, 5 XY
                when i.slot {
                    0 -> sta_reg(i.r1, 0)
                    1 -> ins("stx", cell(i.r1, 0))
                    2 -> ins("sty", cell(i.r1, 0))
                    3 -> {
                        sta_reg(i.r1, 0)
                        ins("stx", cell(i.r1, 1))
                    }
                    4 -> {
                        sta_reg(i.r1, 0)
                        ins("sty", cell(i.r1, 1))
                    }
                    5 -> {
                        ins("stx", cell(i.r1, 0))
                        ins("sty", cell(i.r1, 1))
                    }
                    else -> error("hardware register not supported yet", 0)
                }
            }
            ir.OP_STOREHR -> {
                when i.slot {
                    0 -> lda_reg(i.r1, 0)
                    1 -> ins("ldx", cell(i.r1, 0))
                    2 -> ins("ldy", cell(i.r1, 0))
                    3 -> {
                        ins("ldx", cell(i.r1, 1))
                        lda_reg(i.r1, 0)
                    }
                    4 -> {
                        ins("ldy", cell(i.r1, 1))
                        lda_reg(i.r1, 0)
                    }
                    5 -> {
                        ins("ldx", cell(i.r1, 0))
                        ins("ldy", cell(i.r1, 1))
                    }
                    else -> error("hardware register not supported yet", 0)
                }
            }
            ir.OP_JUMP -> jump_always(i.sym)
            ir.OP_JUMPI -> {
                pointer_to_scratch(i.r1)
                ins("jmp", "(P8ZP_SCRATCH_W1)")
            }
            ir.OP_RETURN -> return_uses(0)
            ir.OP_RETURNR -> {
                ; the value in A, or A and Y for a word
                if size == 2 {
                    ins("ldy", cell(i.r1, 1))
                    lda_reg(i.r1, 0)
                }
                else if size == 1
                    lda_reg(i.r1, 0)
                else if size == 4 {
                    ; a long goes back in the virtual registers R14 and R15
                    for k in 0 to 3 {
                        lda_reg(i.r1, k)
                        ins_at("sta", "cx16.r14", k)
                    }
                }
                else
                    error("return of this size not supported yet", 0)
                return_uses(size)
            }
            ir.OP_RETURNI -> {
                if size == 4 {
                    for k in 0 to 3 {
                        ins_imm("lda", ((i.value >> (k * 8)) & 255) as long)
                        ins_at("sta", "cx16.r14", k)
                    }
                    return_uses(4)
                    return
                }
                if size == 2
                    ins_imm("ldy", ((i.value >> 8) & 255) as long)
                ins_imm("lda", (i.value & 255) as long)
                return_uses(size)
            }
            ir.OP_CALL, ir.OP_CALLFAR, ir.OP_CALLFARVB -> call_instr(i)
            ir.OP_CALLI -> {
                ; a subroutine call through a pointer: the return address by hand
                pointer_to_scratch(i.r1)
                if cur_overlay != 0 and overlay_returns
                    ins("jsr", overlay_out(0))          ; (out of the overlay and back into it)
                else {
                    ins("lda", "#>((+)-1)")
                    ins("pha", 0)
                    ins("lda", "#<((+)-1)")
                    ins("pha", 0)
                    ins("jmp", "(P8ZP_SCRATCH_W1)")
                    anon_label("+")
                }
            }
            ir.OP_SYSCALL -> syscall(i)
            ir.OP_BSTCC -> ins("bcc", i.sym)
            ir.OP_BSTCS -> ins("bcs", i.sym)
            ir.OP_BSTEQ -> ins("beq", i.sym)
            ir.OP_BSTNE -> ins("bne", i.sym)
            ir.OP_BSTNEG -> ins("bmi", i.sym)
            ir.OP_BSTPOS -> ins("bpl", i.sym)
            ir.OP_BSTVC -> ins("bvc", i.sym)
            ir.OP_BSTVS -> ins("bvs", i.sym)
            ir.OP_CMP, ir.OP_CMPI -> compare(i, size)
            ir.OP_BGT, ir.OP_BGTR, ir.OP_BGE, ir.OP_BGER, ir.OP_BLT, ir.OP_BLE,
            ir.OP_BGTS, ir.OP_BGTSR, ir.OP_BGES, ir.OP_BGESR, ir.OP_BLTS, ir.OP_BLES -> compare_branch(i, size)
            ir.OP_AND, ir.OP_ANDR -> {
                if combine_indirect(i, "and")
                    return
                second_operand(i)
                combine("and", i.r1, size)
            }
            ir.OP_OR, ir.OP_ORR -> {
                if combine_indirect(i, "ora")
                    return
                second_operand(i)
                combine("ora", i.r1, size)
            }
            ir.OP_XOR, ir.OP_XORR -> {
                if combine_indirect(i, "eor")
                    return
                second_operand(i)
                combine("eor", i.r1, size)
            }
            ir.OP_ADD, ir.OP_ADDR -> {
                if combine_indirect(i, "adc")
                    return
                second_operand(i)
                ins("clc", 0)
                combine("adc", i.r1, size)
            }
            ir.OP_SUB, ir.OP_SUBR -> {
                if combine_indirect(i, "sbc")
                    return
                second_operand(i)
                ins("sec", 0)
                combine("sbc", i.r1, size)
            }
            ir.OP_ANDM -> combine_memory("and", i, size)
            ir.OP_ORM -> combine_memory("ora", i, size)
            ir.OP_XORM -> combine_memory("eor", i, size)
            ir.OP_ADDM, ir.OP_ADDIM -> {
                ins("clc", 0)
                combine_memory("adc", i, size)
            }
            ir.OP_SUBM, ir.OP_SUBIM -> {
                ins("sec", 0)
                combine_memory("sbc", i, size)
            }
            ir.OP_INC, ir.OP_INCM -> {
                if word_step(i, "inw", size)
                    return
                location(i)
                if size == 1 and not loc_mem {
                    ; in A: the value is there more often than not, and so is what wants the result
                    lda_reg(i.r1, 0)
                    if c02
                        ins("inc", "a")
                    else {
                        ins("clc", 0)
                        ins("adc", "#1")
                    }
                    sta_reg(i.r1, 0)
                    return
                }
                for k in 0 to size - 1 {
                    loc_ins("inc", k)
                    if k != size - 1
                        ins("bne", "+")
                }
                if size > 1
                    anon_label("+")
            }
            ir.OP_DEC, ir.OP_DECM -> {
                if word_step(i, "dew", size)
                    return
                location(i)
                if size == 1 and not loc_mem {
                    lda_reg(i.r1, 0)
                    if c02
                        ins("dec", "a")
                    else {
                        ins("sec", 0)
                        ins("sbc", "#1")
                    }
                    sta_reg(i.r1, 0)
                    return
                }
                if size == 1
                    loc_ins("dec", 0)
                else {
                    ins("sec", 0)
                    for k in 0 to size - 1 {
                        loc_ins("lda", k)
                        if k == 0
                            ins("sbc", "#1")
                        else
                            ins("sbc", "#0")
                        loc_ins("sta", k)
                    }
                }
            }
            ir.OP_NEG, ir.OP_NEGM -> {
                location(i)
                ins("sec", 0)
                for k in 0 to size - 1 {
                    ins("lda", "#0")
                    loc_ins("sbc", k)
                    loc_ins("sta", k)
                }
            }
            ir.OP_INV, ir.OP_INVM -> {
                location(i)
                for k in 0 to size - 1 {
                    loc_ins("lda", k)
                    ins("eor", "#$ff")
                    loc_ins("sta", k)
                }
            }
            ir.OP_LSL, ir.OP_LSLM -> {
                location(i)
                shift_left(size, false)
            }
            ir.OP_LSR, ir.OP_LSRM -> {
                location(i)
                shift_right(size, false, false)
            }
            ir.OP_ASR, ir.OP_ASRM -> {
                location(i)
                shift_right(size, true, false)
            }
            ir.OP_ROXL, ir.OP_ROXLM -> {
                location(i)
                shift_left(size, true)
            }
            ir.OP_ROXR, ir.OP_ROXRM -> {
                location(i)
                shift_right(size, false, true)
            }
            ir.OP_ROL, ir.OP_ROLM -> {
                ; the bit that leaves at the top comes in at the bottom
                location(i)
                shift_left(size, false)
                ins("bcc", "+")
                loc_ins("inc", 0)
                anon_label("+")
            }
            ir.OP_ROR, ir.OP_RORM -> {
                location(i)
                shift_right(size, false, false)
                ins("bcc", "+")
                loc_ins("lda", size - 1)
                ins("ora", "#$80")
                loc_ins("sta", size - 1)
                anon_label("+")
            }
            ir.OP_LSLI -> {
                loc_mem = false
                loc_reg = i.r1
                shift_times(i, size, i.value as long, 0)
            }
            ir.OP_LSRI -> {
                loc_mem = false
                loc_reg = i.r1
                shift_times(i, size, i.value as long, 1)
            }
            ir.OP_ASRI -> {
                loc_mem = false
                loc_reg = i.r1
                shift_times(i, size, i.value as long, 2)
            }
            ir.OP_LSLN -> {
                loc_mem = false
                loc_reg = i.r1
                shift_by_register(i, size, 0)
            }
            ir.OP_LSRN -> {
                loc_mem = false
                loc_reg = i.r1
                shift_by_register(i, size, 1)
            }
            ir.OP_ASRN -> {
                loc_mem = false
                loc_reg = i.r1
                shift_by_register(i, size, 2)
            }
            ir.OP_EXT, ir.OP_EXTL -> {
                ; r1 (the wider type) = r2 with zeros above
                ubyte wide = type_size(i.t1)
                for k in 0 to wide - 1 {
                    if k < size
                        lda_reg(i.r2, k)
                    else if k == size
                        ins("lda", "#0")
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_EXTS, ir.OP_EXTLS -> {
                ubyte swide = type_size(i.t1)
                for k in 0 to size - 1 {
                    lda_reg(i.r2, k)
                    sta_reg(i.r1, k)
                }
                ; the sign in every higher byte
                ins("ora", "#$7f")
                ins("bmi", "+")
                ins("lda", "#0")
                anon_label("+")
                for k in size to swide - 1
                    sta_reg(i.r1, k)
            }
            ir.OP_LSIGB, ir.OP_LSIGW, ir.OP_LSIGL -> {
                ubyte narrow = type_size(i.t1)
                for k in 0 to narrow - 1 {
                    lda_reg(i.r2, k)
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_MSIGB -> {
                ; the highest byte: of a long, bits 24 to 31
                lda_reg(i.r2, size - 1)
                sta_reg(i.r1, 0)
            }
            ir.OP_MSIGW -> {
                lda_reg(i.r2, 2)
                sta_reg(i.r1, 0)
                lda_reg(i.r2, 3)
                sta_reg(i.r1, 1)
            }
            ir.OP_CONCAT -> {
                ; r1 = r2 above r3, each of the instruction's type
                for k in 0 to size - 1 {
                    lda_reg(i.r3, k)
                    sta_reg(i.r1, k)
                    lda_reg(i.r2, k)
                    sta_reg(i.r1, size + k)
                }
            }
            ir.OP_MUL, ir.OP_MULR, ir.OP_MULS, ir.OP_MULSR -> {
                if i.scale == 250 {
                    ; a word times itself (fuse_indexed): the library's square, which is much
                    ; faster than a multiplication for numbers of a byte's size
                    lda_reg(i.r1, 0)
                    ins("ldy", cell(i.r1, 1))
                    ins("jsr", "prog8_math.square")
                    sta_reg(i.r1, 0)
                    ins("sty", cell(i.r1, 1))
                    return
                }
                ; (the low part of a product is the same for signed numbers)
                second_operand(i)
                byte mshift = -1
                if okind == K_IMM
                    mshift = power_of_two(ovalue, size)
                if mshift >= 0 {
                    ; times a power of two: shifts
                    loc_mem = false
                    loc_reg = i.r1
                    shift_times(i, size, mshift, 0)
                }
                else if okind == K_IMM and small_multiply(size, ovalue) {
                    ; one of the library's routines for a small constant: A, or A and Y, in place
                    buf.clear(nb)
                    if size == 1
                        buf.add_str(nb, "prog8_math.mul_byte_")
                    else
                        buf.add_str(nb, "prog8_math.mul_word_")
                    buf.add_long(nb, ovalue as long)
                    buf.add_byte(nb, 0)
                    ^^ubyte routine = strtab.intern_cstr(nb.data)
                    if size == 2
                        ins("ldy", cell(i.r1, 1))
                    lda_reg(i.r1, 0)
                    ins("jsr", routine)
                    sta_reg(i.r1, 0)
                    if size == 2
                        ins("sty", cell(i.r1, 1))
                }
                else if okind == K_IMM and size <= 2 and shift_add_cost(ovalue, size) <= 180 {
                    ; times a constant with few bits set: shifts and additions, in place of
                    ; the general routine (which takes several hundred cycles)
                    shift_add_multiply(i.r1, ovalue, size)
                }
                else if size == 2 and okind == K_REG and oreg <= ir.regcount and reg_zext[oreg] == 1 and reg_uses[oreg] == 2 {
                    ; a word times an unsigned byte (a register that was made from one, and is
                    ; named nowhere else): eight rounds, not sixteen
                    uword bytereg = oreg
                    uword wordreg = i.r1
                    lda_reg(wordreg, 0)
                    ins("sta", "P8ZP_SCRATCH_W1")
                    lda_reg(wordreg, 1)
                    ins("sta", "P8ZP_SCRATCH_W1+1")
                    lda_reg(bytereg, 0)
                    ins("jsr", math_routine("prog8_math.multiply_ubyte_word", 2))
                    sta_reg(i.r1, 0)
                    ins("sty", cell(i.r1, 1))
                }
                else if size == 1 {
                    lda_reg(i.r1, 0)
                    operand_ins("ldy", 0)
                    ins("jsr", math_routine("prog8_math.multiply_bytes", 0))
                    sta_reg(i.r1, 0)
                }
                else if size == 2 {
                    ; (the second number where the routine wants it: the library's variable, or
                    ; the MEGA65's multiplier itself)
                    operand_ins("lda", 0)
                    if hardware_math
                        ins("sta", "$d774")
                    else
                        ins("sta", "prog8_math.multiply_words.multiplier")
                    operand_ins("lda", 1)
                    if hardware_math
                        ins("sta", "$d775")
                    else
                        ins("sta", "prog8_math.multiply_words.multiplier+1")
                    lda_reg(i.r1, 0)
                    ins("ldy", cell(i.r1, 1))
                    ins("jsr", math_routine("prog8_math.multiply_words", 1))
                    sta_reg(i.r1, 0)
                    ins("sty", cell(i.r1, 1))
                }
                else if size == 4 {
                    long_operands(i)
                    ins("jsr", "prog8_math.multiply_longs")
                    long_result(i.r1)
                }
                else
                    error("multiplication of this size not supported yet", 0)
            }
            ir.OP_DIV, ir.OP_DIVR, ir.OP_MOD, ir.OP_MODR, ir.OP_DIVS, ir.OP_DIVSR, ir.OP_DIVMODR, ir.OP_DIVMOD -> {
                second_operand(i)
                bool signed_div = i.op == ir.OP_DIVS or i.op == ir.OP_DIVSR
                bool want_mod = i.op == ir.OP_MOD or i.op == ir.OP_MODR
                bool both = i.op == ir.OP_DIVMODR or i.op == ir.OP_DIVMOD
                byte dshift = -1
                if okind == K_IMM and not signed_div and not both
                    dshift = power_of_two(ovalue, size)
                if dshift >= 0 {
                    if want_mod {
                        ; the remainder of a power of two: the low bits
                        long mask = 1
                        mask <<= dshift as ubyte
                        mask--
                        for k in 0 to size - 1 {
                            ubyte maskbyte = ((mask >> (k * 8)) & 255) as ubyte
                            if maskbyte == 0 {
                                ins("lda", "#0")
                                sta_reg(i.r1, k)
                            }
                            else if maskbyte != 255 {
                                lda_reg(i.r1, k)
                                ins_imm("and", maskbyte)
                                sta_reg(i.r1, k)
                            }
                        }
                    }
                    else {
                        loc_mem = false
                        loc_reg = i.r1
                        shift_times(i, size, dshift, 1)
                    }
                }
                else if size == 1 {
                    ; A divided by Y: the quotient in Y, the remainder in A
                    lda_reg(i.r1, 0)
                    operand_ins("ldy", 0)
                    if signed_div
                        ins("jsr", "prog8_math.divmod_b_asm")
                    else
                        ins("jsr", math_routine("prog8_math.divmod_ub_asm", 3))
                    if want_mod
                        sta_reg(i.r1, 0)
                    else {
                        ins("sty", cell(i.r1, 0))
                        if both and i.mode == ir.M_RR
                            sta_reg(i.r2, 0)
                    }
                }
                else if size == 2 {
                    ; the scratch word divided by AY: the quotient in AY, the remainder in the second scratch word
                    lda_reg(i.r1, 0)
                    ins("sta", "P8ZP_SCRATCH_W1")
                    lda_reg(i.r1, 1)
                    ins("sta", "P8ZP_SCRATCH_W1+1")
                    operand_ins("lda", 0)
                    operand_ins("ldy", 1)
                    if signed_div
                        ins("jsr", "prog8_math.divmod_w_asm")
                    else
                        ins("jsr", math_routine("prog8_math.divmod_uw_asm", 4))
                    if not want_mod {
                        sta_reg(i.r1, 0)
                        ins("sty", cell(i.r1, 1))
                    }
                    if want_mod or (both and i.mode == ir.M_RR) {
                        uword target = i.r1
                        if both
                            target = i.r2
                        ins("lda", "P8ZP_SCRATCH_W2")
                        sta_reg(target, 0)
                        ins("lda", "P8ZP_SCRATCH_W2+1")
                        sta_reg(target, 1)
                    }
                }
                else if size == 4 and not want_mod and not both {
                    ; (the library's 32 bit division is the signed one)
                    long_operands(i)
                    ins("jsr", "prog8_math.div_longs")
                    long_result(i.r1)
                }
                else
                    error("division of this size not supported yet", 0)
            }
            ir.OP_SGN -> {
                ; r1 (a byte) = -1, 0 or 1 by the sign of r2
                lda_reg(i.r2, size - 1)
                ins("bmi", "+")
                for k in 0 to size - 1 {
                    if k != size - 1
                        ins("ora", cell(i.r2, k))
                }
                ins("beq", "++")
                ins("lda", "#1")
                ins("bne", "++")
                anon_label("+")
                ins("lda", "#$ff")
                anon_label("+")
                sta_reg(i.r1, 0)
            }
            ir.OP_SQRT -> {
                if size > 2
                    error("square root of this size not supported yet", 0)
                lda_reg(i.r2, 0)
                if size == 2
                    ins("ldy", cell(i.r2, 1))
                else
                    ins("ldy", "#0")
                ins("jsr", "prog8_lib.func_sqrt16_into_A")
                sta_reg(i.r1, 0)
            }
            ir.OP_SQUARE -> {
                if size == 1 {
                    lda_reg(i.r2, 0)
                    ins("tay", 0)
                    ins("jsr", "prog8_math.multiply_bytes")
                    sta_reg(i.r1, 0)
                }
                else if size == 2 {
                    lda_reg(i.r2, 0)
                    ins("sta", "prog8_math.multiply_words.multiplier")
                    ins("ldy", cell(i.r2, 1))
                    ins("sty", "prog8_math.multiply_words.multiplier+1")
                    ins("jsr", "prog8_math.multiply_words")
                    sta_reg(i.r1, 0)
                    ins("sty", cell(i.r1, 1))
                }
                else
                    error("square of this size not supported yet", 0)
            }
            ir.OP_PUSH -> {
                for k in 0 to size - 1 {
                    lda_reg(i.r1, k)
                    ins("pha", 0)
                }
            }
            ir.OP_POP -> {
                k = size
                while k > 0 {
                    k--
                    ins("pla", 0)
                    sta_reg(i.r1, k)
                }
            }
            ir.OP_PUSHST -> ins("php", 0)
            ir.OP_POPST -> ins("plp", 0)
            ir.OP_CLC -> ins("clc", 0)
            ir.OP_SEC -> ins("sec", 0)
            ir.OP_BREAKPOINT -> {
                ; %breakpoint: a label here, which the driver lists for VICE's monitor
                breakpoints++
                buf.clear(nb)
                buf.add_str(nb, "p8_breakpoint_")
                buf.add_long(nb, breakpoints)
                buf.add_byte(nb, 0)
                label(strtab.intern_cstr(nb.data))
                if break_instruction != 0
                    ins(break_instruction, 0)       ; -breakinstr: an instruction as well
            }
            ir.OP_SEI -> ins("sei", 0)
            ir.OP_CLI -> ins("cli", 0)
            else -> {
                buf.clear(nb)
                ir.text = nb
                ir.write_instr(i)
                buf.add_byte(nb, 0)
                error("instruction not supported yet", nb.data)
            }
        }
    }

    ; A call.  The arguments go where the IR says: a named parameter variable
    ; of the subroutine, or a CPU register (hardware slot 0 A, 1 X, 2 Y, 3 AX,
    ; 4 AY, 5 XY).  Register arguments are loaded last, A last of all, as the
    ; loads of the others use A.
    ; ---- arguments in registers ----
    ;
    ; As upstream documents it for the 6502: a subroutine with one byte parameter gets
    ; it in A, with two byte parameters in A and Y, with one word or pointer parameter
    ; in A and Y; the subroutine stores them in its parameter variables itself.  Any
    ; other subroutine has its variables filled by the caller.

    const ubyte CONV_NONE = 0
    const ubyte CONV_A = 1
    const ubyte CONV_A_Y = 2
    const ubyte CONV_AY = 3

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

    ; the size of a parameter that can travel in a register, or 0
    sub register_param(^^ir.Param p) -> ubyte {
        if p.typestr == 0 or array_length(p.typestr) != 0 or starts_with(p.typestr, "float")
            return 0
        long size = element_size(p.typestr)
        if size == 1 or size == 2
            return size as ubyte
        return 0
    }

    sub convention(^^ir.Sub s) -> ubyte {
        if s == 0 or s.is_asm or s.params == 0
            return CONV_NONE
        ^^ir.Param first = s.params
        ^^ir.Param second = first.next
        ubyte size = register_param(first)
        if second == 0 {
            if size == 1
                return CONV_A
            if size == 2
                return CONV_AY
            return CONV_NONE
        }
        if second.next == 0 and size == 1 and register_param(second) == 1
            return CONV_A_Y
        return CONV_NONE
    }

    ; the subroutine's side: the registers into the parameter variables
    sub store_register_params(^^ir.Sub s) {
        ^^ir.Param first = s.params
        when convention(s) {
            CONV_A -> ins_at("sta", first.name, 0)
            CONV_A_Y -> {
                ins_at("sta", first.name, 0)
                ins_at("sty", first.next.name, 0)
            }
            CONV_AY -> {
                ins_at("sta", first.name, 0)
                ins_at("sty", first.name, 1)
            }
        }
    }

    ; the argument of a call for this parameter (the argument has the name without its scope)
    sub param_arg(^^ir.Instr i, ^^ir.Param p) -> ^^ir.Arg {
        long plen = buf.cstr_len(p.name)
        ^^ir.Arg a = i.args
        while a != 0 {
            if a.slot == 255 and a.name != 0 {
                long alen = buf.cstr_len(a.name)
                if alen == plen and strings.compare(a.name, p.name) == 0
                    return a
                if alen < plen and p.name[plen - alen - 1] == '.' and strings.compare(p.name + (plen - alen), a.name) == 0
                    return a
            }
            a = a.next
        }
        return 0
    }

    ; the caller's side; false when the call does not have the arguments the subroutine wants
    sub load_register_params(^^ir.Instr i) -> bool {
        ^^ir.Sub s = find_sub(i.sym)
        ubyte conv = convention(s)
        if conv == CONV_NONE
            return false
        ^^ir.Arg first = param_arg(i, s.params)
        if first == 0
            return false
        when conv {
            CONV_A -> load_register('a', first, 0)
            CONV_A_Y -> {
                ^^ir.Arg second = param_arg(i, s.params.next)
                if second == 0
                    return false
                load_register('y', second, 0)
                load_register('a', first, 0)
            }
            CONV_AY -> {
                load_register('y', first, 1)
                load_register('a', first, 0)
            }
        }
        return true
    }

    sub call_instr(^^ir.Instr i) {
        ^^ir.Arg a = i.args
        ; arguments in registers, or else in the parameter variables
        bool in_registers = i.op == ir.OP_CALL and convention(find_sub(i.sym)) != CONV_NONE
        while a != 0 {
            if a.slot == 255 and a.name != 0 and not in_registers and not (q_long_args and a.type == ir.T_LONG and a.reg != 0) {
                ubyte size = type_size(a.type)
                ubyte k
                for k in 0 to size - 1 {
                    if a.reg != 0
                        lda_reg(a.reg, k)
                    else
                        ins_imm("lda", ((a.value >> (k * 8)) & 255) as long)
                    if starts_with(a.name, "cx16.")
                        ins_at("sta", a.name, k)        ; (a virtual register is named in full)
                    else {
                        ; a parameter of the subroutine
                        if pb == 0
                            pb = buf.new(128)
                        buf.clear(pb)
                        buf.add_str(pb, i.sym)
                        buf.add_byte(pb, '.')
                        buf.add_str(pb, a.name)
                        buf.add_byte(pb, 0)
                        ins_at("sta", pb.data, k)
                    }
                }
            }
            a = a.next
        }
        ; a status flag argument: the carry from the value's lowest bit (the loads that follow leave it alone)
        a = i.args
        while a != 0 {
            if a.slot >= ir.SLOT_FLAGS and a.slot != 255 {
                if a.slot != ir.SLOT_FLAGS
                    error("only the carry can be a status flag argument", i.sym)
                else if a.reg != 0 {
                    lda_reg(a.reg, 0)
                    ins("lsr", "a")
                }
                else if (a.value & 1) != 0
                    ins("sec", 0)
                else
                    ins("clc", 0)
            }
            a = a.next
        }
        ; a float in FAC2 and FAC1 (loading them uses A, X and Y)
        a = i.args
        while a != 0 {
            if a.slot == 7 and a.reg != 0 {
                cell_address(a.reg, "lda")
                ins("jsr", "floats.CONUPK")
            }
            a = a.next
        }
        a = i.args
        while a != 0 {
            if a.slot == 6 and a.reg != 0
                fac1_load(a.reg)
            a = a.next
        }
        ; then X and Y, then A
        ubyte pass
        for pass in 0 to 1 {
            a = i.args
            while a != 0 {
                if a.slot <= 5
                    register_argument(a, pass)
                a = a.next
            }
        }
        if in_registers {
            if not load_register_params(i)
                error("the arguments of this call do not match the subroutine's parameters", i.sym)
        }
        when i.op {
            ir.OP_CALLFAR, ir.OP_CALLFARVB -> far_call(i)
            else -> {
                ^^ir.Sub inlined = inline_asmsub(i.sym)
                if inlined != 0
                    asm_text(inlined.asmtext, inlined.asmlen)       ; its body, in place of the call
                else {
                    if wide_enabled and wide_rest and (starts_with(i.sym, "sys.exit") or starts_with(i.sym, "sys.reset_system") or starts_with(i.sym, "sys.poweroff_system")) {
                        ; the program ends here: the machine gets its CPU back in emulation mode
                        raw("    sec")
                        raw("    xce")
                    }
                    ^^ubyte call_name = overlay_entry(i.sym)
                    if call_name == i.sym
                        call_name = overlay_out(i.sym)
                    ins("jsr", call_name)
                    ubyte used = call_uses(i, in_registers)
                    ^^ir.Sub callee = find_sub(i.sym)
                    if callee == 0 or callee.is_asm
                        used |= 8               ; (it may take the carry too)
                    peep6502.last_uses(used)
                }
            }
        }
        ; a result comes back in A, or in A and Y
        ^^ir.Arg r = i.results
        if r != 0 and r.reg != 0 and r.next == 0 {
            ubyte rsize = type_size(r.type)
            long vreg = -1
            if r.slot == 255
                vreg = result_vreg(i.sym, rsize)
            if vreg >= 0 {
                ; the result is in a virtual register (an asmsub's, or the R14R15 of a long)
                ubyte vk
                if c45 and rsize == 4 {
                    ; (the 45GS02: all four bytes into Q, where the next instruction may want them)
                    if pb == 0
                        pb = buf.new(128)
                    buf.clear(pb)
                    buf.add_str(pb, "cx16.r")
                    buf.add_long(pb, vreg)
                    buf.add_byte(pb, 0)
                    q_text("ldq", pb.data, 0)
                    q_result(r.reg)
                }
                else for vk in 0 to rsize - 1 {
                    if pb == 0
                        pb = buf.new(128)
                    buf.clear(pb)
                    buf.add_str(pb, "cx16.r")
                    buf.add_long(pb, vreg)
                    buf.add_byte(pb, 0)
                    ins_at("lda", pb.data, vk)
                    sta_reg(r.reg, vk)
                }
            }
            else if r.slot >= ir.SLOT_FLAGS and r.slot != 255 {
                ; a status flag: the instructions that follow the call make it a value
                ; (a rotate into zero for the carry, a branch for the others)
            }
            else if rsize == 1 {
                when r.slot {
                    1 -> ins("stx", cell(r.reg, 0))
                    2 -> ins("sty", cell(r.reg, 0))
                    else -> sta_reg(r.reg, 0)
                }
            }
            else if rsize == 2 {
                when r.slot {
                    3 -> {
                        sta_reg(r.reg, 0)
                        ins("stx", cell(r.reg, 1))
                    }
                    5 -> {
                        ins("stx", cell(r.reg, 0))
                        ins("sty", cell(r.reg, 1))
                    }
                    else -> {
                        sta_reg(r.reg, 0)
                        ins("sty", cell(r.reg, 1))
                    }
                }
            }
            else if rsize == 5
                fac1_store(r.reg)       ; a float comes back in FAC1
            else
                error("call result of this size not supported yet", i.sym)
        }
    }

    ; The virtual register that the single result of a call to this routine is in, or -1
    ; when it is in the CPU registers: the one an asmsub's declaration names (R0, or the
    ; first of a pair like R0R1), and R14 for the long that an ordinary subroutine returns.
    sub result_vreg(^^ubyte name, ubyte size) -> long {
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if strings.compare(s.name, name) == 0 {
                    if s.is_asm {
                        ^^ubyte r = s.asmreturns
                        if r != 0 and (r[0] & $df) == 'R' and r[1] >= '0' and r[1] <= '9' {
                            long n = r[1] - '0'
                            if r[2] >= '0' and r[2] <= '9'
                                n = n * 10 + (r[2] - '0')
                            return n
                        }
                        return -1
                    }
                    if size == 4
                        return 14
                    return -1
                }
                s = s.next
            }
            bl = bl.next
        }
        if size == 4
            return 14
        return -1
    }

    ; the inline asmsub of this name, or 0: such a routine has no code of its own
    sub inline_asmsub(^^ubyte name) -> ^^ir.Sub {
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if s.is_asm and s.is_inline and s.asmtext != 0 and not s.asm_is_ir and strings.compare(s.name, name) == 0
                    return s
                s = s.next
            }
            bl = bl.next
        }
        return 0
    }

    ; the routine that calls into another bank: the address and bank follow the jsr
    sub far_routine() -> ^^ubyte {
        if target.text("jsrfar_routine") != 0
            return target.text("jsrfar_routine")
        buf.clear(nb)
        buf.add_str(nb, prog.target)
        buf.add_str(nb, ".x16jsrfar")
        buf.add_byte(nb, 0)
        return strtab.intern_cstr(nb.data)
    }

    long patch_seq = 0

    ; callfar "#bank,address,name" and callfarvb "rN.b,address,name"
    sub far_call(^^ir.Instr i) {
        ^^ubyte t = i.sym
        long comma = 0
        while t[comma] != 0 and t[comma] != ','
            comma++
        long stop = comma + 1
        while t[stop] != 0 and t[stop] != ','
            stop++
        ^^ubyte address = strtab.intern(t + comma + 1, (stop - comma - 1) as uword)
        ^^ubyte routine = far_routine()
        if t[0] == '#' {
            ins("jsr", routine)
            put("    .word  ")
            put(address)
            nl()
            put("    .byte  ")
            buf.add_bytes(w(), t + 1, comma - 1)
            nl()
            return
        }
        ; the bank is in a register: written into the byte after the address.  A holds
        ; an argument by now, so it goes by way of the stack.
        patch_seq++
        ins("pha", 0)
        uword bankreg = 0
        long k = 1
        while t[k] >= '0' and t[k] <= '9' {
            bankreg = bankreg * 10 + (t[k] - '0')
            k++
        }
        lda_reg(bankreg, 0)
        put("    sta  p8_farcall_")
        putn(patch_seq)
        raw("+2")
        ins("pla", 0)
        ins("jsr", routine)
        put("p8_farcall_")
        putn(patch_seq)
        raw(":")
        put("    .word  ")
        put(address)
        nl()
        raw("    .byte  0")
    }

    ; the register of argument number n (from 0) of a call or syscall
    sub arg_reg(^^ir.Instr i, ubyte n) -> uword {
        ^^ir.Arg a = i.args
        while a != 0 and n > 0 {
            a = a.next
            n--
        }
        if a == 0 or a.reg == 0 {
            error("a syscall argument that is not in a register", i.sym)
            return 0
        }
        return a.reg
    }

    sub reg_to_scratch(uword r, str scratch, ubyte bytes) {
        lda_reg(r, 0)
        ins("sta", scratch)
        if bytes == 2 {
            lda_reg(r, 1)
            ins_at("sta", scratch, 1)
        }
    }

    ; The syscalls that the compiler itself emits for builtin functions and operators:
    ; library routines with their own conventions.  The result comes back in A, or A and Y.
    sub syscall(^^ir.Instr i) {
        long n = number(i.sym)
        ubyte result_size = 1
        when n {
            $1012, $1013 -> {
                ; clamp a byte: the minimum and maximum in the scratch word, the value in A
                lda_reg(arg_reg(i, 1), 0)
                ins("sta", "P8ZP_SCRATCH_W1")
                lda_reg(arg_reg(i, 2), 0)
                ins("sta", "P8ZP_SCRATCH_W1+1")
                lda_reg(arg_reg(i, 0), 0)
                if n == $1012
                    ins("jsr", "prog8_lib.func_clamp_ubyte")
                else
                    ins("jsr", "prog8_lib.func_clamp_byte")
            }
            $1014, $1015 -> {
                reg_to_scratch(arg_reg(i, 1), "P8ZP_SCRATCH_W1", 2)
                reg_to_scratch(arg_reg(i, 2), "P8ZP_SCRATCH_W2", 2)
                lda_reg(arg_reg(i, 0), 0)
                ins("ldy", cell(arg_reg(i, 0), 1))
                if n == $1014
                    ins("jsr", "prog8_lib.func_clamp_uword")
                else
                    ins("jsr", "prog8_lib.func_clamp_word")
                result_size = 2
            }
            $100d -> {
                ; compare two strings: -1, 0 or 1
                reg_to_scratch(arg_reg(i, 1), "P8ZP_SCRATCH_W2", 2)
                lda_reg(arg_reg(i, 0), 0)
                ins("ldy", cell(arg_reg(i, 0), 1))
                ins("jsr", "prog8_lib.strcmp_mem")
            }
            $100e -> {
                ; is a character in a string
                lda_reg(arg_reg(i, 0), 0)
                ins("sta", "P8ZP_SCRATCH_W2")
                reg_to_scratch(arg_reg(i, 1), "P8ZP_SCRATCH_W1", 2)
                ins("ldy", "#0")
                anon_label("-")
                ins("lda", "(P8ZP_SCRATCH_W1),y")
                ins("beq", "+")
                ins("cmp", "P8ZP_SCRATCH_W2")
                ins("beq", "++")
                ins("iny", 0)
                ins("bne", "-")
                anon_label("+")
                ins("lda", "#0")
                ins("beq", "++")
                anon_label("+")
                ins("lda", "#1")
                anon_label("+")
            }
            $100f -> {
                ; is a byte in an array: (element, array, length)
                lda_reg(arg_reg(i, 2), 0)
                ins("sta", "P8ZP_SCRATCH_W2")
                reg_to_scratch(arg_reg(i, 1), "P8ZP_SCRATCH_W1", 2)
                lda_reg(arg_reg(i, 0), 0)
                ins("ldy", "P8ZP_SCRATCH_W2")
                ins("jsr", "prog8_lib.containment_bytearray")
            }
            $1010, $101a -> {
                ; is a word in an array (of words, or split in two byte arrays)
                reg_to_scratch(arg_reg(i, 1), "P8ZP_SCRATCH_W2", 2)
                reg_to_scratch(arg_reg(i, 0), "P8ZP_SCRATCH_W1", 2)
                ins("ldy", cell(arg_reg(i, 2), 0))
                if n == $1010
                    ins("jsr", "prog8_lib.containment_linearwordarray")
                else
                    ins("jsr", "prog8_lib.containment_splitwordarray")
            }
            $1017 -> {
                ; callfar(bank, address, argument in AY)
                patch_seq++
                syscall_patch(i)
                lda_reg(arg_reg(i, 2), 0)
                ins("ldy", cell(arg_reg(i, 2), 1))
                ins("jsr", far_routine())
                syscall_patch_site()
                result_size = 2
            }
            $1018 -> {
                ; callfar2(bank, address, A, X, Y, carry)
                patch_seq++
                syscall_patch(i)
                lda_reg(arg_reg(i, 5), 0)
                ins("lsr", "a")                         ; the carry
                ins("ldx", cell(arg_reg(i, 3), 0))
                ins("ldy", cell(arg_reg(i, 4), 0))
                lda_reg(arg_reg(i, 2), 0)
                ins("jsr", far_routine())
                syscall_patch_site()
                result_size = 2
            }
            else -> {
                error("syscall not supported yet", i.sym)
                return
            }
        }
        ^^ir.Arg r = i.results
        if r != 0 and r.reg != 0 {
            sta_reg(r.reg, 0)
            if result_size == 2 and type_size(r.type) >= 2
                ins("sty", cell(r.reg, 1))
        }
    }

    ; writes the bank and address of a callfar into the three bytes after its jsr
    sub syscall_patch(^^ir.Instr i) {
        lda_reg(arg_reg(i, 0), 0)
        put("    sta  p8_farcall_")
        putn(patch_seq)
        raw("+2")
        lda_reg(arg_reg(i, 1), 0)
        put("    sta  p8_farcall_")
        putn(patch_seq)
        nl()
        lda_reg(arg_reg(i, 1), 1)
        put("    sta  p8_farcall_")
        putn(patch_seq)
        raw("+1")
    }

    sub syscall_patch_site() {
        put("p8_farcall_")
        putn(patch_seq)
        raw(":")
        raw("    .word  0")
        raw("    .byte  0")
    }

    ; pass 0 loads X and Y (and the X or Y half of a pair), pass 1 loads A
    sub register_argument(^^ir.Arg a, ubyte pass) {
        ; which register takes the low byte and which the high byte: 'a', 'x', 'y' or 0
        ubyte low = 'a'
        ubyte high = 0
        when a.slot {
            1 -> low = 'x'
            2 -> low = 'y'
            3 -> high = 'x'
            4 -> high = 'y'
            5 -> {
                low = 'x'
                high = 'y'
            }
        }
        if pass == 0 {
            if low != 'a'
                load_register(low, a, 0)
            if high != 0
                load_register(high, a, 1)
        }
        else if low == 'a'
            load_register('a', a, 0)
    }

    sub load_register(ubyte which, ^^ir.Arg a, ubyte byteoffset) {
        str mnemonic = "lda"
        mnemonic[2] = which
        if a.reg != 0
            ins(mnemonic, cell(a.reg, byteoffset))
        else
            ins_imm(mnemonic, ((a.value >> (byteoffset * 8)) & 255) as long)
    }

    ; ---- data ----

    ; the number of elements of an array type text, or 0 for a scalar
    sub array_length(^^ubyte t) -> long {
        long i = 0
        while t[i] != 0 and t[i] != '['
            i++
        if t[i] == 0
            return 0
        return number(t + i + 1)
    }

    ; the size in bytes of one element of a type text
    sub element_size(^^ubyte t) -> long {
        if starts_with(t, "ubyte") or starts_with(t, "byte") or starts_with(t, "bool")
            return 1
        if starts_with(t, "uword") or starts_with(t, "word") or starts_with(t, "pointer") or t[0] == '^'
            return 2
        if starts_with(t, "long")
            return 4
        if starts_with(t, "float")
            return 5
        ; an array of struct instances: the struct's size
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

    ; is this the type of an array of struct instances
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
                ^^ubyte iname = strtab.intern(t + p + 1, (stop - p - 1) as uword)
                ^^ir.Var v = prog.vars
                while v != 0 {
                    if v.kind == ir.V_INSTANCE and v.name == iname {
                        inst = v
                        break
                    }
                    v = v.next
                }
            }
            if inst != 0 and inst.init != 0
                instance_values(inst.init)
            else {
                put("    .fill  ")
                putn(struct_size)
                nl()
            }
            p = stop
            if t[p] == ','
                p++
        }
    }

    sub var_size(^^ir.Var v) -> long {
        long n = array_length(v.typestr)
        if n == 0
            n = 1
        return n * element_size(v.typestr)
    }

    ; One value of an initializer, from position p: a number, or @symbol, @<symbol,
    ; @>symbol for an address or half of one.  Gives the position after it.
    sub put_value(^^ubyte t, long p) -> long {
        if t[p] == '@' {
            p++
            if t[p] == '<' or t[p] == '>' {
                buf.add_byte(w(), t[p])
                p++
            }
        }
        if data_size == 5 {
            ; a float: its five bytes
            long fstop = p
            buf.clear(nb)
            while t[fstop] != 0 and t[fstop] != ',' {
                buf.add_byte(nb, t[fstop])
                fstop++
            }
            buf.add_byte(nb, 0)
            float_bytes(irparse.parse_float(nb.data))
            ubyte fk
            for fk in 0 to 4 {
                if fk != 0
                    put(",")
                putn(fbytes[fk])
            }
            return fstop
        }
        if t[p] == '-' {
            ; (the assembler wants bytes and words without a sign)
            long stop = p
            while t[stop] != 0 and t[stop] != ','
                stop++
            long v = number(t + p)
            if data_size == 1
                putn(v & 255)
            else if data_size == 2
                putn(v & $ffff)
            else
                putn(v)
            return stop
        }
        while t[p] != 0 and t[p] != ',' {
            buf.add_byte(w(), t[p])
            p++
        }
        return p
    }

    long data_size = 1          ; the size of the elements that put_value writes

    ; The library's multiplication and division routines for bytes and words, or on the
    ; MEGA65 routines of the program's own that take and give the same but leave the work
    ; to the machine's multiplier and divider.  Which of them the program uses:
    ; (their names begin with prog8_: by that the peephole passes know a routine that takes
    ; the scratch words, as the library's do)
    bool[5] hw_used

    sub hw_name(ubyte which) -> ^^ubyte {
        when which {
            0 -> return "prog8_hw_mulb"
            1 -> return "prog8_hw_mulw"
            2 -> return "prog8_hw_mulbw"
            3 -> return "prog8_hw_divb"
        }
        return "prog8_hw_divw"
    }

    sub math_routine(^^ubyte library, ubyte which) -> ^^ubyte {
        if not hardware_math
            return library
        hw_used[which] = true
        return hw_name(which)
    }

    sub hw_zero(str a, str b, str c) {
        raw("    lda  #0")
        put("    sta  ")
        raw(a)
        put("    sta  ")
        raw(b)
        if c[0] != 0 {
            put("    sta  ")
            raw(c)
        }
    }

    sub hw_wait() {
        raw("-   bit  $d70f")
        raw("    bmi  -")
    }

    sub hw_routines() {
        if hw_used[0] or hw_used[1] or hw_used[2] or hw_used[3] or hw_used[4] {
            raw("")
            raw("; multiplication and division with the MEGA65's arithmetic unit: two 32-bit numbers at")
            raw("; $d770 and $d774, their product at $d778, their quotient at $d76c when bit 7 of $d70f is off")
        }
        if hw_used[0] {
            raw("prog8_hw_mulb:             ; A times Y, in A")
            raw("    sta  $d770")
            raw("    sty  $d774")
            hw_zero("$d771", "$d772", "$d773")
            raw("    sta  $d775")
            raw("    sta  $d776")
            raw("    sta  $d777")
            raw("    lda  $d778")
            raw("    rts")
        }
        if hw_used[1] {
            raw("prog8_hw_mulw:             ; AY times the word at $d774, in AY")
            raw("    sta  $d770")
            raw("    sty  $d771")
            hw_zero("$d772", "$d773", "$d776")
            raw("    sta  $d777")
            raw("    lda  $d778")
            raw("    ldy  $d779")
            raw("    rts")
        }
        if hw_used[2] {
            raw("prog8_hw_mulbw:            ; the word in P8ZP_SCRATCH_W1 times A, in AY")
            raw("    sta  $d774")
            hw_zero("$d775", "$d776", "$d777")
            raw("    sta  $d772")
            raw("    sta  $d773")
            raw("    lda  P8ZP_SCRATCH_W1")
            raw("    sta  $d770")
            raw("    lda  P8ZP_SCRATCH_W1+1")
            raw("    sta  $d771")
            raw("    lda  $d778")
            raw("    ldy  $d779")
            raw("    rts")
        }
        if hw_used[3] {
            raw("prog8_hw_divb:             ; A divided by Y: the quotient in Y, the remainder in A")
            raw("    sta  $d770")
            raw("    sty  $d774")
            raw("    pha")
            hw_zero("$d771", "$d772", "$d773")
            raw("    sta  $d775")
            raw("    sta  $d776")
            raw("    sta  $d777")
            hw_wait()
            raw("    ldy  $d76c")
            raw("    sty  $d770          ; (quotient times divisor is at $d778 now)")
            raw("    pla")
            raw("    sec")
            raw("    sbc  $d778")
            raw("    rts")
        }
        if hw_used[4] {
            raw("prog8_hw_divw:             ; P8ZP_SCRATCH_W1 divided by AY: the quotient in AY, the remainder in P8ZP_SCRATCH_W2")
            raw("    sta  $d774")
            raw("    sty  $d775")
            raw("    lda  P8ZP_SCRATCH_W1")
            raw("    sta  $d770")
            raw("    lda  P8ZP_SCRATCH_W1+1")
            raw("    sta  $d771")
            hw_zero("$d772", "$d773", "$d776")
            raw("    sta  $d777")
            hw_wait()
            raw("    lda  $d76c")
            raw("    ldy  $d76d")
            raw("    pha")
            raw("    sta  $d770          ; (quotient times divisor is at $d778 now)")
            raw("    sty  $d771")
            raw("    sec")
            raw("    lda  P8ZP_SCRATCH_W1")
            raw("    sbc  $d778")
            raw("    sta  P8ZP_SCRATCH_W2")
            raw("    lda  P8ZP_SCRATCH_W1+1")
            raw("    sbc  $d779")
            raw("    sta  P8ZP_SCRATCH_W2+1")
            raw("    pla")
            raw("    rts")
        }
    }

    ; "    mnemonic  p8_regfile+N" for byte n of the division routine's cells
    sub qdiv_line(str mnemonic, long n) {
        put("    ")
        put(mnemonic)
        put("  p8_regfile+")
        putn(qdiv_cells + n)
        nl()
    }

    ; The division of longs with the MEGA65's divider, which is unsigned and gives no
    ; remainder: Q divided by the long in cell B, the quotient in Q.  The cells: A the
    ; dividend (0), B the divisor (4), SIGN (16).  The quotient goes towards zero.
    sub qdiv_routine() {
        raw("")
        raw("; the division of two longs (the 45GS02 on the MEGA65: its divider at $d770)")
        raw("p8_qdivs:")
        qdiv_line("stq", 0)
        qdiv_line("lda", 3)
        qdiv_line("eor", 7)
        qdiv_line("sta", 16)
        qdiv_line("bit", 3)
        raw("    bpl  +")
        qdiv_line("ldq", 0)
        raw("    .byte  $42, $42, $42    ; negq")
        qdiv_line("stq", 0)
        raw("+")
        qdiv_line("bit", 7)
        raw("    bpl  +")
        qdiv_line("ldq", 4)
        raw("    .byte  $42, $42, $42    ; negq")
        qdiv_line("stq", 4)
        raw("+")
        qdiv_line("ldq", 0)
        raw("    stq  $d770")
        qdiv_line("ldq", 4)
        raw("    stq  $d774")
        raw("-   bit  $d70f")
        raw("    bmi  -")
        raw("    ldq  $d76c")
        qdiv_line("bit", 16)
        raw("    bpl  +")
        raw("    .byte  $42, $42, $42    ; negq")
        raw("+")
        raw("    rts")
    }

    sub data() {
        if qdiv_used
            qdiv_routine()
        hw_routines()
        ubyte qk = 0
        while qk < qconst_count {
            ; (the long constants that are operands of the 45GS02's 32-bit instructions)
            put("p8_qconst_")
            putn(qk)
            put("  .byte  ")
            ubyte qb
            for qb in 0 to 3 {
                if qb != 0
                    put(", ")
                putn(((qconsts[qk] >> (qb * 8)) & 255) as long)
            }
            nl()
            qk++
        }
        ubyte fk = 0
        while fk < fconst_count {
            ; (the float constants that are operands where they are)
            float_bytes(fconsts[fk])
            put("p8_fconst_")
            putn(fk)
            put("  .byte  ")
            ubyte fb
            for fb in 0 to 4 {
                if fb != 0
                    put(", ")
                putn(fbytes[fb])
            }
            nl()
            fk++
        }
        struct_definitions()
        raw("; variables with initial values")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_VAR and v.init != 0 and v.zpaddr == 0 and not ram_initialized(v) {
                if v.align > 1 {
                    put("    .align  ")
                    putn(v.align)
                    nl()
                }
                long esize = element_size(v.typestr)
                data_size = esize
                if is_struct_array(v.typestr) {
                    ; the elements are the instances that the initializer names, laid out one after the other
                    put(v.name)
                    raw(":")
                    struct_array_values(v.init, esize)
                    v = v.next
                    continue
                }
                ^^ubyte directive = "  .byte  "
                when esize {
                    2 -> directive = "  .word  "
                    4 -> directive = "  .dint  "
                }
                put(v.name)
                long p = 0
                ubyte column = 0
                while v.init[p] != 0 {
                    if column == 0 {
                        if p != 0
                            put("     ")
                        put(directive)
                    }
                    else
                        put(",")
                    p = put_value(v.init, p)
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
            v = v.next
        }
        raw("")
    }

    ; memory() blocks, and static struct instances
    sub slabs_and_instances() {
        bool any = false
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_SLAB {
                if not any {
                    raw("    .section BSS_SLABS")
                    raw("prog8_slabs  .block")
                    any = true
                }
                if v.align > 1 {
                    put("    .align  ")
                    putn(v.align)
                    nl()
                }
                put(unscoped(v.name))
                put("  .fill  ")
                putn(v.size)
                nl()
            }
            v = v.next
        }
        if any {
            raw("    .bend")
            raw("    .send BSS_SLABS")
            raw("")
        }
        ; Struct instances, with values and without: one block, so that every one is
        ; prog8_struct_instances.name.  One without values is all zeros (in the program
        ; file: it is not cleared at startup, as a variable in the BSS section would be).
        any = false
        v = prog.vars
        while v != 0 {
            if v.kind == ir.V_INSTANCE {
                if not any {
                    raw("    .section STRUCTINSTANCES")
                    raw("prog8_struct_instances  .block")
                    any = true
                }
                put(unscoped(v.name))
                if v.init != 0 {
                    raw(":")
                    instance_values(v.init)
                }
                else {
                    put("  .fill  ")
                    putn(v.size)
                    raw(", 0")
                }
            }
            v = v.next
        }
        if any {
            raw("    .bend")
            raw("    .send STRUCTINSTANCES")
            raw("")
        }
    }

    ; "type:value,type:value": a line of data for each field
    sub instance_values(^^ubyte t) {
        long p = 0
        while t[p] != 0 {
            long colon = p
            while t[colon] != ':'
                colon++
            buf.clear(nb)
            buf.add_bytes(nb, t + p, colon - p)
            buf.add_byte(nb, 0)
            data_size = element_size(nb.data)
            when data_size {
                1 -> put("    .byte  ")
                2 -> put("    .word  ")
                4 -> put("    .dint  ")
                else -> put("    .byte  ")       ; a float
            }
            p = put_value(t, colon + 1)
            nl()
            if t[p] == ','
                p++
        }
    }

    sub bss() {
        slabs_and_instances()
        ; variables that keep what they had: not cleared at startup
        raw("    .section BSS_NOCLEAR")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_VAR and v.init == 0 and v.dirty and v.zpaddr == 0
                bss_var(v)
            v = v.next
        }
        raw("p8_regfile:")
        put("    .fill  ")
        putn(regfile_used + 1)
        nl()
        raw("    .send BSS_NOCLEAR")
        raw("")
        raw("    .section BSS")
        v = prog.vars
        while v != 0 {
            if v.kind == ir.V_VAR and ((v.init == 0 and not v.dirty) or ram_initialized(v)) and v.zpaddr == 0
                bss_var(v)
            v = v.next
        }
        raw("prog8_fp_temp  .fill  5")
        raw("    .send BSS")
        raw("")
        raw("  .dsection STRUCTINSTANCES")
        raw("")
        raw("; bss sections")
        ; Where the variables without an initial value go: after the program, or with
        ; -varsgolden, -varshigh or -varsaddress (or the target's vars_address) in memory
        ; of their own, which leaves that much more for the program.
        long vars_start = -1
        long vars_end = 0
        if vars_address < 0
            vars_address = prog.vars_address        ; (%varsaddress; the command line's goes first)
        if vars_address >= 0 {
            vars_start = vars_address
            vars_end = $ffff
            if memtop > 0
                vars_end = memtop
        }
        else if vars_golden {
            vars_start = target.number("bss_goldenram_start", 0)
            vars_end = target.number("bss_goldenram_end", 0)
            if vars_start == 0 or vars_end <= vars_start
                error("the target has no golden ram area (bss_goldenram_start, bss_goldenram_end) for -varsgolden", 0)
        }
        else if vars_high_bank >= 0 {
            vars_start = target.number("bss_highram_start", 0)
            vars_end = target.number("bss_highram_end", 0)
            if vars_start == 0 or vars_end <= vars_start
                error("the target has no high ram area (bss_highram_start, bss_highram_end) for -varshigh", 0)
        }
        else if target.text("vars_address") != 0 {
            vars_start = target.number("vars_address", 0)
            vars_end = $ffff
            if memtop > 0
                vars_end = memtop
        }
        put("PROG8_VARSHIGH_RAMBANK = ")
        if vars_high_bank >= 0
            putn(vars_high_bank)
        else
            putn(1)
        nl()
        if vars_start >= 0 {
            raw("prog8_program_end:")
            put("  * = ")
            puthex(vars_start)
            nl()
            raw("  .dsection BSS_NOCLEAR")
            raw("prog8_bss_section_start:")
            raw("  .dsection BSS")
            raw("  .dsection BSS_SLABS")
            put("  .cerror * > ")
            puthex(vars_end)
            raw(", \"too many variables/data for BSS section\"")
            raw("prog8_bss_section_size = * - prog8_bss_section_start")
        }
        else {
            raw("  .dsection BSS_NOCLEAR")
            raw("prog8_bss_section_start:")
            raw("  .dsection BSS")
            raw("prog8_bss_section_size = * - prog8_bss_section_start")
            raw("  .dsection BSS_SLABS")
            raw("prog8_program_end:")
        }
        raw("")
        if memtop > 0 {
            ; (the end of the program itself, wherever the variables are)
            put("    .cerror prog8_program_end >= ")
            puthex(memtop)
            put(", \"Program too long by \", prog8_program_end - ")
            puthex(memtop - 1)
            put(", \" bytes, memtop=")
            puthex(memtop)
            raw("\"")
        }
    }

    sub bss_var(^^ir.Var v) {
        if v.align > 1 {
            put("    .align  ")
            putn(v.align)
            nl()
        }
        put(v.name)
        put("  .fill  ")
        putn(var_size(v))
        nl()
    }
}
