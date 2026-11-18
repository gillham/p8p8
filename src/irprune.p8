; Removal of unused code and data from the IR.
;
; A subroutine is kept when something that is kept refers to it: the entry
; point main.start, a call, jump or address-of in a kept subroutine, the
; initial value of a kept variable, or a name in assembly text.  Assembly
; code can reach anything by name, so all of it counts: the inline assembly
; and inline IR of blocks, of asmsubs (which are all kept, as upstream keeps
; them) and of kept subroutines.  A name in assembly inside block B is
; tried as written, as B.name and as B.sub.name, the way the assembler's
; scopes resolve it.
;
; Variables follow the same rule.  Constants, memory-mapped variables and
; struct definitions are always kept; so are @shared variables and the
; subroutines of a block with %option force_output.
;
; The work list is a linked list through the table entries, so nothing here
; recurses.

%import ir
%import mem
%import buf
%import out
%import strings

irprune {
    %option ignore_unused

    struct Entry {
        ^^Entry next_work       ; work list link
        ^^ubyte name
        long length
        pointer item            ; the ^^ir.Sub or ^^ir.Var
        ^^ir.Block block        ; a subroutine's block
        bool is_sub
        bool live
    }

    ^^pointer table = 0         ; ^^Entry by hash of the name, open addressing
    long table_size = 0
    ^^Entry work = 0
    ^^buf.Buf scratch = 0
    long removed_subs = 0
    long removed_vars = 0
    long kept_subs = 0
    long kept_vars = 0

    ; Upstream's back end wants every asmsub in the IR.  p8p8's own code generator
    ; does not: then an asmsub is kept like a subroutine, when something refers to it,
    ; except those of the blocks that the generated code calls by name.
    bool asmsubs_kept = true

    sub runtime_block(^^ubyte name) -> bool {
        return strings.compare(name, "prog8_lib") == 0 or strings.compare(name, "prog8_math") == 0
            or strings.compare(name, "p8_sys_startup") == 0
    }

    ; (the reset routine of the startup code, and the far call routine)
    bool long_to_float = false

    sub converts_long_in(^^ir.Chunk c) {
        while c != 0 {
            if c.kind != ir.C_ASM {
                ^^ir.Instr i = c.first
                while i != 0 {
                    if i.op == ir.OP_FFROMSL
                        long_to_float = true
                    i = i.next
                }
            }
            c = c.next
        }
    }

    sub runtime_sub(^^ubyte name) -> bool {
        if strings.compare(name, "sys.reset_system") == 0
            return true
        ; (the conversions to a float that are asmsubs)
        if strings.compare(name, "floats.FREADUY") == 0 or strings.compare(name, "floats.FREADSA") == 0
                or strings.compare(name, "floats.GIVUAYFAY") == 0 or strings.compare(name, "floats.GIVAYFAY") == 0
            return true
        ; (a long made a float: only a program that does that needs the routine)
        if long_to_float and strings.compare(name, "floats.internal_long_AY_to_FAC") == 0
            return true
        long length = buf.cstr_len(name)
        return length > 10 and strings.compare(name + length - 10, ".x16jsrfar") == 0
    }

    sub run(^^ir.Program p) {
        removed_subs = 0
        removed_vars = 0
        kept_subs = 0
        kept_vars = 0
        if scratch == 0
            scratch = buf.new(256)
        long_to_float = false
        converts_long_in(p.initglobals)
        ^^ir.Block cb = p.blocks
        while cb != 0 {
            converts_long_in(cb.chunks)
            ^^ir.Sub cs = cb.subs
            while cs != 0 {
                converts_long_in(cs.chunks)
                cs = cs.next
            }
            cb = cb.next
        }
        build_table(p)
        ^^Entry entry = find_cstr("main.start")
        if entry == 0
            entry = find_cstr("p8b_main.p8s_start")
        if entry == 0
            return              ; a library, or no entry point: everything stays
        work = 0
        mark(entry)
        roots(p)
        while work != 0 {
            ^^Entry e = work
            work = e.next_work
            if e.is_sub
                visit_sub(e)
            else
                visit_var(e)
        }
        sweep(p)
    }

    sub build_table(^^ir.Program p) {
        long count = 0
        ^^ir.Block bl = p.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                count++
                s = s.next
            }
            bl = bl.next
        }
        ^^ir.Var v = p.vars
        while v != 0 {
            count++
            v = v.next
        }
        table_size = 256
        while table_size < count * 2
            table_size <<= 1
        table = mem.alloc(table_size * sizeof(pointer))
        bl = p.blocks
        while bl != 0 {
            ^^ir.Sub s2 = bl.subs
            while s2 != 0 {
                ^^Entry se = insert(s2.name)
                se.item = s2
                se.block = bl
                se.is_sub = true
                s2 = s2.next
            }
            bl = bl.next
        }
        v = p.vars
        while v != 0 {
            if removable(v) {
                ^^Entry ve = insert(v.name)
                ve.item = v
            }
            v = v.next
        }
    }

    sub removable(^^ir.Var v) -> bool {
        return v.kind == ir.V_VAR or v.kind == ir.V_INSTANCE or v.kind == ir.V_SLAB
    }

    sub slot_of(^^ubyte name, long length) -> long {
        uword h = 5381
        long i = 0
        while i < length {
            h = (h << 5) + h ^ name[i]
            i++
        }
        return ((h as long) & $ffff) & (table_size - 1)
    }

    sub insert(^^ubyte name) -> ^^Entry {
        long length = buf.cstr_len(name)
        long slot = slot_of(name, length)
        while table[slot] != 0
            slot = (slot + 1) & (table_size - 1)
        ^^Entry e = mem.alloc(sizeof(Entry))
        e.name = name
        e.length = length
        table[slot] = e
        return e
    }

    sub find(^^ubyte name, long length) -> ^^Entry {
        if length <= 0
            return 0
        long slot = slot_of(name, length)
        while table[slot] != 0 {
            ^^Entry e = table[slot]
            if e.length == length and buf.bytes_equal(e.name, name, length)
                return e
            slot = (slot + 1) & (table_size - 1)
        }
        return 0
    }

    sub find_cstr(^^ubyte name) -> ^^Entry {
        return find(name, buf.cstr_len(name))
    }

    sub mark(^^Entry e) {
        ; (a loop, not recursion: marking something marks the subroutines it is nested in,
        ; because the assembler needs their scopes for its name)
        while e != 0 and not e.live {
            e.live = true
            e.next_work = work
            work = e
            e = owner(e.name, e.length)
        }
    }

    ; the subroutine a scoped name is declared in, or 0 at block level
    sub owner(^^ubyte name, long length) -> ^^Entry {
        long k = length
        while k > 0 {
            k--
            if name[k] == '.' {
                ^^Entry e = find(name, k)
                if e != 0 and e.is_sub
                    return e
            }
        }
        return 0
    }

    sub mark_cstr(^^ubyte name) {
        if name != 0
            mark(find(name, buf.cstr_len(name)))
    }

    ; what is kept whatever refers to it
    sub roots(^^ir.Program p) {
        ^^ir.Block bl = p.blocks
        while bl != 0 {
            ^^ir.Chunk c = bl.chunks
            while c != 0 {
                if c.kind == ir.C_ASM
                    scan_text(c.text, c.textlen, bl.name, 0)
                c = c.next
            }
            ^^ir.Sub s = bl.subs
            while s != 0 {
                ; (an asmsub nested in a subroutine lives and dies with it)
                if bl.force_output or (s.is_asm and owner(s.name, buf.cstr_len(s.name)) == 0 and (asmsubs_kept or runtime_block(bl.name) or runtime_sub(s.name)))
                    mark_cstr(s.name)
                s = s.next
            }
            bl = bl.next
        }
        scan_chunk(p.initglobals, 0, 0)
        ^^ir.Var v = p.vars
        while v != 0 {
            if v.shared and removable(v) and owner(v.name, buf.cstr_len(v.name)) == 0
                mark_cstr(v.name)       ; (a subroutine's @shared variables follow the subroutine)
            v = v.next
        }
    }

    sub visit_sub(^^Entry e) {
        ^^ir.Sub s = e.item
        ^^ubyte blockname = 0
        if e.block != 0
            blockname = e.block.name
        ^^ir.Param p = s.params
        while p != 0 {
            mark_cstr(p.name)
            p = p.next
        }
        if s.asmtext != 0
            scan_text(s.asmtext, s.asmlen, blockname, s.name)
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            scan_chunk(c, blockname, s.name)
            c = c.next
        }
    }

    sub scan_chunk(^^ir.Chunk c, ^^ubyte blockname, ^^ubyte subname) {
        if c == 0
            return
        if c.kind == ir.C_ASM {
            scan_text(c.text, c.textlen, blockname, subname)
            return
        }
        ^^ir.Instr i = c.first
        while i != 0 {
            if i.sym != 0 {
                mark_cstr(i.sym)
                if i.op == ir.OP_CALLFAR or i.op == ir.OP_CALLFARVB
                    scan_text(i.sym, buf.cstr_len(i.sym), 0, 0)     ; "#bank,address,name"
            }
            i = i.next
        }
    }

    sub visit_var(^^Entry e) {
        ^^ir.Var v = e.item
        if v.init != 0
            scan_text(v.init, buf.cstr_len(v.init), 0, 0)       ; @name, @<name, @>name
        if v.split and e.length > 4 {
            ; the other half of a split word array
            buf.clear(scratch)
            buf.add_bytes(scratch, e.name, e.length - 3)
            if e.name[e.length - 3] == 'l'
                buf.add_str(scratch, "msb")
            else
                buf.add_str(scratch, "lsb")
            mark(find(scratch.data, scratch.len))
        }
    }

    sub is_name_start(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= $80
    }

    sub is_name_char(ubyte c) -> bool {
        return is_name_start(c) or (c >= '0' and c <= '9') or c == '.'
    }

    ; marks what a name in assembly text names; a.b.c may be the label c inside the
    ; assembly of a.b, so the names it starts with count too
    sub mark_name(^^ubyte name, long length) {
        mark(find(name, length))
        long k = length
        while k > 1 {
            k--
            if name[k] == '.'
                mark(find(name, k))
        }
    }

    ; marks every name in assembly or data text
    sub scan_text(^^ubyte text, long length, ^^ubyte blockname, ^^ubyte subname) {
        if text == 0
            return
        long i = 0
        while i < length {
            if not is_name_start(text[i]) {
                ; skip numbers whole, so that $ff or 12ab do not start a name
                if (text[i] >= '0' and text[i] <= '9') or text[i] == '$' {
                    i++
                    while i < length and is_name_char(text[i])
                        i++
                }
                else
                    i++
                continue
            }
            long start = i
            while i < length and is_name_char(text[i])
                i++
            long stop = i
            while stop > start and text[stop - 1] == '.'
                stop--
            mark_name(text + start, stop - start)
            if blockname != 0 {
                buf.clear(scratch)
                buf.add_str(scratch, blockname)
                buf.add_byte(scratch, '.')
                buf.add_bytes(scratch, text + start, stop - start)
                mark_name(scratch.data, scratch.len)
            }
            if subname != 0 {
                buf.clear(scratch)
                buf.add_str(scratch, subname)
                buf.add_byte(scratch, '.')
                buf.add_bytes(scratch, text + start, stop - start)
                mark_name(scratch.data, scratch.len)
            }
        }
    }

    ; unlinks what was never marked
    sub sweep(^^ir.Program p) {
        ^^ir.Block bl = p.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            ^^ir.Sub kept = 0
            bl.subs = 0
            while s != 0 {
                ^^ir.Sub following = s.next
                ^^Entry e = find_cstr(s.name)
                if e != 0 and e.live {
                    s.next = 0
                    if kept == 0
                        bl.subs = s
                    else
                        kept.next = s
                    kept = s
                    kept_subs++
                }
                else
                    removed_subs++
                s = following
            }
            bl.lastsub = kept
            bl = bl.next
        }
        ^^ir.Var v = p.vars
        ^^ir.Var keptvar = 0
        p.vars = 0
        while v != 0 {
            ^^ir.Var followingvar = v.next
            bool keep = true
            if removable(v) {
                ^^Entry ve = find_cstr(v.name)
                keep = ve != 0 and ve.live
            }
            else {
                ; a constant, memory-mapped variable or struct of a removed subroutine goes with it
                ^^Entry oe = owner(v.name, buf.cstr_len(v.name))
                keep = oe == 0 or oe.live
            }
            if keep {
                v.next = 0
                if keptvar == 0
                    p.vars = v
                else
                    keptvar.next = v
                keptvar = v
                kept_vars++
            }
            else
                removed_vars++
            v = followingvar
        }
        p.lastvar = keptvar
    }

    sub stats() {
        out.puts("unused code: ")
        out.putl(removed_subs)
        out.puts(" subroutines removed, ")
        out.putl(kept_subs)
        out.puts(" kept; ")
        out.putl(removed_vars)
        out.puts(" variables removed, ")
        out.putl(kept_vars)
        out.puts(" kept")
        out.nl()
    }
}
