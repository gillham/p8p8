; IR generation: the typed and checked AST becomes a Prog8 IR program
; (see ir.p8), following upstream's code generator: every expression value
; gets a fresh virtual register, statements append instructions to the
; current chunk, and every label starts a new chunk.  Variables live in
; memory under their scoped names; a subroutine's locals and parameters
; included, as in the upstream IR (the backends decide what goes on a
; stack).

%import crumb
%import ast
%import token
%import types
%import symtab
%import resolver
%import importer
%import source
%import strtab
%import diag
%import typer
%import encoding
%import ir
%import io_platform
%import target
%import buf
%import mem
%import out
%import strings
%import parser
%import float_platform

irgen {
    %option ignore_unused

    ^^ir.Program prog = 0
    ^^ir.Block block = 0
    ^^ir.Sub cursub = 0
    ^^ir.Chunk chunk = 0
    ^^symtab.Sym subsym = 0         ; the subroutine being generated
    ^^symtab.Scope scope = 0        ; its scope, for name lookups
    ^^importer.Module module = 0
    ^^buf.Buf nb = 0                ; name building
    ^^buf.Buf ab = 0                ; array initializer text
    long label_seq = 0
    long errors = 0

    ; loop context for break/continue
    const ubyte MAX_LOOPS = 32
    ^^ubyte[MAX_LOOPS] break_labels
    ^^ubyte[MAX_LOOPS] continue_labels
    ubyte loop_depth = 0

    ; interned string literals
    struct IString {
        ^^IString next
        ^^ubyte bytes
        ^^ubyte name
        long length
    }
    ^^IString istrings = 0
    long istring_count = 0
    ^^ir.Block istring_block = 0

    ; often used names
    ^^ubyte n_start = 0
    ^^ubyte n_ir = 0
    ^^ubyte n_main = 0

    ; the integer type that holds an address on this target
    ubyte address_irt = ir.T_LONG

    ; ---- entry ----

    sub generate(^^ubyte name) -> ^^ir.Program {
        if nb == 0 {
            nb = buf.new(256)
            ab = buf.new(1024)
            n_start = strtab.intern("start", 5)
            n_ir = strtab.intern("ir", 2)
            n_main = strtab.intern("main", 4)
        }
        prog = ir.new_program(name, importer.target)
        ; the virtual machine and LLVM take any name; everything else is assembled
        prefixing = strings.compare(importer.target, "virtual") != 0 and not buf.bytes_equal(importer.family, "llvm", 4)
        if prefixing
            mark_unprefixed_blocks()
        split_words = prefixing and types.POINTER_SIZE == 2
        if types.POINTER_SIZE == 2
            address_irt = ir.T_WORD
        else if types.POINTER_SIZE == 8
            address_irt = ir.T_QUAD
        else
            address_irt = ir.T_LONG
        ; variables, constants and structs of every scope
        ir.reuse_numbers = buf.bytes_equal(importer.family, "llvm", 4)
        zeropage_registers()
        declare_scope(symtab.global)
        defer_setup()
        scratch_variables()
        program_options()
        ; the code of every block, program modules first
        ^^importer.Module m = importer.modules
        while m != 0 {
            if not m.is_library
                gen_module(m)
            m = m.next
        }
        istring_block = ir.add_block(prog, strtab.intern("prog8_interned_strings", 22), "[~dummy~: line 0 col 0-0]", true)
        istring_block.no_prefixing = true
        m = importer.modules
        while m != 0 {
            if m.is_library
                gen_module(m)
            m = m.next
        }
        if program_defers
            gen_defer_block()
        overlay_lists()
        main_block_first()
        addressed_blocks_last()
        return prog
    }

    ; "%overlay n, name, name..." in a module: the blocks and subroutines that are in
    ; overlay n, all in one place (and the program's other sources are as they are for a
    ; build without overlays).  A program that also has the directive inside a block or
    ; a subroutine gets a warning: what is where should be in one place.
    ^^ast.Node overlay_inline = 0       ; a directive inside a block or a subroutine, if there is one

    sub overlay_lists() {
        bool listed = false
        ^^importer.Module m = importer.modules
        while m != 0 {
            ^^ast.Node d = m.tree.a
            while d != 0 {
                if d.kind == ast.N_DIRECTIVE and d.a != 0 and strings.compare(d.name, "overlay") == 0 {
                    listed = true
                    ubyte number = overlay_number(d)
                    ir.overlay_wanted[number] = true
                    ^^ast.Node name = d.a.next
                    while name != 0 {
                        if name.kind == ast.N_IDENT and number != 0
                            overlay_listed(name, number)
                        name = name.next
                    }
                }
                d = d.next
            }
            m = m.next
        }
        if listed and overlay_inline != 0
            diag.warning_at(source.get(overlay_inline.file), overlay_inline.line, overlay_inline.col, "%overlay here and in a list at the top of a module: the list is the place to see what is where (it is what counts where both name the same thing)")
    }

    ; the overlay's number in a directive: written out, or a constant's name (0, with an
    ; error, when it is neither or not from 1 to 255)
    sub overlay_number(^^ast.Node d) -> ubyte {
        bool ok
        quad v
        ok, v = typer.directive_number(d.a)
        if not ok {
            error(d.a, "%overlay: expected a number from 1 to 255, or the name of a constant that is one")
            return 0
        }
        if v < 1 or v > 255 {
            error(d.a, "%overlay: the constant is not a number from 1 to 255")
            return 0
        }
        return v as ubyte
    }

    sub overlay_listed(^^ast.Node name, ubyte number) {
        ^^symtab.Sym s = resolver.lookup_name(name.name, name)
        if s == 0 or (s.kind != symtab.K_BLOCK and s.kind != symtab.K_SUB) {
            error(name, "%overlay: this is not the name of a block or of a subroutine")
            return
        }
        ^^ubyte irname = sym_name(s)
        if s.kind == symtab.K_BLOCK {
            ^^ir.Block b = find_block(irname)
            if b != 0
                b.overlay = number
            return
        }
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub su = bl.subs
            while su != 0 {
                if su.name == irname or strings.compare(su.name, irname) == 0 {
                    su.overlay = number
                    return
                }
                su = su.next
            }
            bl = bl.next
        }
        ; (a subroutine that nothing uses has no code: nothing to place)
    }

    ; The blocks that have an address of their own come after all the others, lowest
    ; address first, as upstream orders them: what follows "* = address" in the assembly
    ; is at that address, and that must not be the rest of the program.  (The main block
    ; stays first whatever it has.)
    sub addressed_blocks_last() {
        ^^ir.Block plain_first = 0
        ^^ir.Block plain_last = 0
        ^^ir.Block placed = 0           ; the ones with an address, kept in ascending order
        ^^ir.Block b = prog.blocks
        bool first = true
        while b != 0 {
            ^^ir.Block following = b.next
            b.next = 0
            bool ok = false
            long address = 0
            if b.address != 0 and not first
                ok, address = target.parse_number(b.address)
            if ok {
                ; insert after the placed blocks whose address is not higher
                ^^ir.Block before = 0
                ^^ir.Block at = placed
                while at != 0 {
                    bool aok
                    long other
                    aok, other = target.parse_number(at.address)
                    if other > address
                        break
                    before = at
                    at = at.next
                }
                b.next = at
                if before == 0
                    placed = b
                else
                    before.next = b
            }
            else {
                if plain_first == 0
                    plain_first = b
                else
                    plain_last.next = b
                plain_last = b
            }
            first = false
            b = following
        }
        if plain_last != 0
            plain_last.next = placed
        prog.blocks = plain_first
        ^^ir.Block last = plain_first
        while last != 0 and last.next != 0
            last = last.next
        prog.lastblock = last
    }

    ; The block main leads the program, whatever the source has before it: the
    ; virtual machine only starts at main.start when it is in the first block
    ; (upstream writes it first too).
    sub main_block_first() {
        ^^ir.Block before = 0
        ^^ir.Block b = prog.blocks
        while b != 0 {
            if strings.compare(b.name, "main") == 0 or strings.compare(b.name, "p8b_main") == 0 {
                if before == 0
                    return
                before.next = b.next
                if prog.lastblock == b
                    prog.lastblock = before
                b.next = prog.blocks
                prog.blocks = b
                return
            }
            before = b
            b = b.next
        }
    }

    sub gen_module(^^importer.Module m) {
        module = m
        ^^ast.Node e = m.tree.a
        while e != 0 {
            if e.kind == ast.N_BLOCK
                gen_block(e)
            e = e.next
        }
    }

    ; ---- errors ----

    sub error(^^ast.Node at, str message) {
        diag.error_at(source.get(at.file), at.line, at.col, message)
        errors++
    }

    sub unsupported(^^ast.Node at, str what) {
        buf.clear(nb)
        buf.add_str(nb, "IR generation does not support this yet: ")
        buf.add_str(nb, what)
        buf.add_byte(nb, 0)
        diag.error_at(source.get(at.file), at.line, at.col, nb.data)
        errors++
    }

    ; ---- names ----

    sub scope_name_into(^^symtab.Scope sc, bool prefixed) {
        if sc == 0 or sc.kind == symtab.S_GLOBAL or sc.kind == symtab.S_BUILTIN
            return
        scope_name_into(sc.parent, prefixed)
        if nb.len != 0
            buf.add_byte(nb, '.')
        if prefixed {
            when sc.kind {
                symtab.S_BLOCK -> buf.add_str(nb, "p8b_")
                symtab.S_SUB -> buf.add_str(nb, "p8s_")
                symtab.S_STRUCT -> buf.add_str(nb, "p8t_")
            }
        }
        buf.add_str(nb, sc.name)
    }

    ; Symbol prefixes.  Targets that go through an assembler get p8b_ (block),
    ; p8s_ (subroutine), p8v_ (variable, parameter), p8c_ (constant), p8l_
    ; (label) and p8t_ (struct) on every name, so that no name clashes with
    ; an assembler keyword; blocks with %option no_symbol_prefixing are left
    ; alone because their assembly code uses the plain names.
    bool prefixing = false
    const ubyte NO_PREFIX = 128         ; flag on a block's symbol: %option no_symbol_prefixing in the block or its module

    sub mark_unprefixed_blocks() {
        ^^ubyte optname = strtab.intern_cstr("no_symbol_prefixing")
        ^^importer.Module m = importer.modules
        while m != 0 {
            bool whole_module = symtab.has_option(m.tree.a, optname)
            ^^ast.Node b = m.tree.a
            while b != 0 {
                if b.kind == ast.N_BLOCK and b.extra != 0 and (whole_module or symtab.has_option(b.a, optname)) {
                    ^^symtab.Sym bs = b.extra
                    bs.flags |= NO_PREFIX
                }
                b = b.next
            }
            m = m.next
        }
    }

    sub wants_prefix(^^symtab.Sym s) -> bool {
        if not prefixing
            return false
        ^^symtab.Sym bsym = 0
        if s.kind == symtab.K_BLOCK
            bsym = s
        else {
            ^^symtab.Scope sc = s.scope
            while sc != 0 and sc.kind != symtab.S_BLOCK
                sc = sc.parent
            if sc != 0 and sc.owner != 0
                bsym = sc.owner.extra
        }
        if bsym == 0 or bsym.kind != symtab.K_BLOCK
            return false
        return (bsym.flags & NO_PREFIX) == 0
    }

    sub add_kind_prefix(^^symtab.Sym s) {
        when s.kind {
            symtab.K_BLOCK -> buf.add_str(nb, "p8b_")
            symtab.K_SUB -> buf.add_str(nb, "p8s_")
            symtab.K_VAR, symtab.K_MEMVAR, symtab.K_PARAM -> buf.add_str(nb, "p8v_")
            symtab.K_CONST, symtab.K_ENUMMEMBER -> buf.add_str(nb, "p8c_")
            symtab.K_LABEL -> buf.add_str(nb, "p8l_")
            symtab.K_STRUCT -> buf.add_str(nb, "p8t_")
        }
    }

    ; a symbol's own name, with its prefix when its block has them: for the
    ; parameter names in a call
    sub plain_name(^^symtab.Sym s) -> ^^ubyte {
        if not wants_prefix(s)
            return s.name
        buf.clear(nb)
        add_kind_prefix(s)
        buf.add_str(nb, s.name)
        return intern_nb()
    }

    ; The scoped name of a symbol: block.sub.name
    sub sym_name(^^symtab.Sym s) -> ^^ubyte {
        if s.irname != 0
            return s.irname
        bool prefixed = wants_prefix(s)
        buf.clear(nb)
        scope_name_into(s.scope, prefixed)
        if nb.len != 0
            buf.add_byte(nb, '.')
        if prefixed
            add_kind_prefix(s)
        buf.add_str(nb, s.name)
        s.irname = strtab.intern(nb.data, nb.len as uword)
        return s.irname
    }

    sub intern_nb() -> ^^ubyte {
        return strtab.intern(nb.data, nb.len as uword)
    }

    sub new_label() -> ^^ubyte {
        label_seq++
        buf.clear(nb)
        buf.add_str(nb, "p8_label_gen_")
        buf.add_long(nb, label_seq)
        return intern_nb()
    }

    sub pos_text(^^ast.Node n) -> ^^ubyte {
        buf.clear(nb)
        buf.add_byte(nb, '[')
        ^^source.File f = source.get(n.file)
        buf.add_str(nb, f.name)
        buf.add_str(nb, ": line ")
        buf.add_long(nb, n.line)
        buf.add_str(nb, " col ")
        buf.add_long(nb, n.col)
        buf.add_byte(nb, '-')
        buf.add_long(nb, n.col)
        buf.add_byte(nb, ']')
        return intern_nb()
    }

    ; ---- types ----

    ; the IR type of a prog8 type
    sub irt(uword t) -> ubyte {
        if t == 0
            return ir.T_BYTE
        when types.base_of(t) {
            types.T_BOOL, types.T_UBYTE, types.T_BYTE -> return ir.T_BYTE
            types.T_UWORD, types.T_WORD -> return ir.T_WORD
            types.T_LONG -> return ir.T_LONG
            types.T_QUAD, types.T_UQUAD -> return ir.T_QUAD
            types.T_FLOAT -> return ir.T_FLOAT
            else -> return ir.T_POINTER       ; pointers, strings, arrays: the address
        }
    }

    ; the integer IR type of the same size as a pointer
    sub plain(ubyte t) -> ubyte {
        if t == ir.T_POINTER
            return address_irt
        return t
    }

    sub irt_size(ubyte t) -> ubyte {
        when plain(t) {
            ir.T_BYTE -> return 1
            ir.T_WORD -> return 2
            ir.T_LONG -> return 4
            ir.T_QUAD -> return 8
            ir.T_FLOAT -> return 8
        }
        return 0
    }

    ; the IR type string of a variable's prog8 type; strings need their length
    sub type_string(uword t, long strlength) -> ^^ubyte {
        buf.clear(nb)
        type_string_into(t, strlength)
        return intern_nb()
    }

    sub type_string_into(uword t, long strlength) {
        ^^types.Type tt = types.get(t)
        when tt.base {
            types.T_BOOL -> buf.add_str(nb, "bool")
            types.T_UBYTE -> buf.add_str(nb, "ubyte")
            types.T_BYTE -> buf.add_str(nb, "byte")
            types.T_UWORD -> buf.add_str(nb, "uword")
            types.T_WORD -> buf.add_str(nb, "word")
            types.T_LONG -> buf.add_str(nb, "long")
            types.T_QUAD -> buf.add_str(nb, "quad")
            types.T_UQUAD -> buf.add_str(nb, "uquad")
            types.T_FLOAT -> buf.add_str(nb, "float")
            types.T_STR -> {
                buf.add_str(nb, "ubyte[")
                if strlength != 0
                    buf.add_long(nb, strlength)
                buf.add_byte(nb, ']')
            }
            types.T_POINTER -> buf.add_str(nb, "pointer")
            types.T_ARRAY -> {
                ^^types.Type et = types.get(tt.elem)
                if et.base == types.T_POINTER {
                    buf.add_str(nb, "^^")
                    ^^types.Type pt = types.get(et.elem)
                    if pt.base == types.T_STRUCT {
                        ^^symtab.Sym ss = pt.strct
                        buf.add_str(nb, sym_name(ss))
                    }
                    else
                        type_string_into(et.elem, 0)
                }
                else if et.base == types.T_STRUCT {
                    ^^symtab.Sym ss2 = et.strct
                    buf.add_str(nb, sym_name(ss2))
                }
                else if et.base == types.T_STR {
                    ; an array of strings holds their addresses
                    if types.POINTER_SIZE == 8
                        buf.add_str(nb, "uquad")
                    else if types.POINTER_SIZE == 4
                        buf.add_str(nb, "long")
                    else
                        buf.add_str(nb, "uword")
                }
                else
                    type_string_into(tt.elem, 0)
                buf.add_byte(nb, '[')
                if tt.length != 0
                    buf.add_long(nb, tt.length)
                buf.add_byte(nb, ']')
            }
            types.T_STRUCT -> {
                ^^symtab.Sym ss3 = tt.strct
                buf.add_str(nb, sym_name(ss3))
            }
            else -> buf.add_str(nb, "ubyte")
        }
    }

    ; ---- variables ----

    sub declare_scope(^^symtab.Scope sc) {
        ^^symtab.Sym s = sc.syms
        while s != 0 {
            when s.kind {
                symtab.K_VAR -> declare_var(s)
                symtab.K_PARAM -> {
                    ; an asmsub's or extsub's parameters are registers, not variables
                    if sc.owner == 0 or (sc.owner.kind != ast.N_ASMSUB and sc.owner.kind != ast.N_EXTSUB)
                        declare_var(s)
                }
                symtab.K_CONST -> declare_const(s)
                symtab.K_MEMVAR -> declare_memvar(s)
                symtab.K_STRUCT -> declare_struct(s)
                symtab.K_ENUM -> declare_enum(s)
                symtab.K_BLOCK, symtab.K_SUB -> {
                    if s.inner != 0 and s.inner.owner == s.decl
                        declare_scope(s.inner)
                }
            }
            s = s.next
        }
    }

    ; the text of a number for an initializer
    sub number_text(quad v) -> ^^ubyte {
        buf.clear(nb)
        ir.text = nb
        ir.add_number(v)
        return intern_nb()
    }

    ; ---- split word arrays ----
    ; On the 6502 an array of words (or addresses) is stored as two byte
    ; arrays, name_lsb and name_msb, unless it is tagged @nosplit: indexing
    ; with the Y register then reaches both halves of an element.
    bool split_words = false

    sub is_split(^^symtab.Sym s) -> bool {
        if not split_words or s == 0 or s.kind != symtab.K_VAR or s.type == 0
            return false
        ^^types.Type t = types.get(s.type)
        if t.base != types.T_ARRAY or types.size_of(t.elem) != 2
            return false
        if types.is_struct(t.elem)
            return false            ; (struct instances lie one after the other, whatever their size)
        if s.decl != 0 and s.decl.kind == ast.N_VARDECL {
            ^^ast.Node tag = s.decl.d
            while tag != 0 {
                if tag.kind == ast.N_TAG and strings.compare(tag.name, "nosplit") == 0
                    return false
                tag = tag.next
            }
        }
        return true
    }

    sub split_name(^^symtab.Sym s, bool high) -> ^^ubyte {
        ^^ubyte base = sym_name(s)
        buf.clear(nb)
        buf.add_str(nb, base)
        if high
            buf.add_str(nb, "_msb")
        else
            buf.add_str(nb, "_lsb")
        return intern_nb()
    }

    ; One half of a word array's values: the low bytes, or the high bytes
    ; (negative for a negative value, as upstream writes them); the address
    ; of a symbol becomes @<name or @>name.
    sub split_text(^^ubyte values, bool high) -> ^^ubyte {
        if values == 0
            return 0
        ^^buf.Buf b = buf.new(buf.cstr_len(values) + 16)
        long i = 0
        while values[i] != 0 {
            if values[i] == '@' {
                buf.add_byte(b, '@')
                if high
                    buf.add_byte(b, '>')
                else
                    buf.add_byte(b, '<')
                i++
                while values[i] != 0 and values[i] != ',' {
                    buf.add_byte(b, values[i])
                    i++
                }
            }
            else {
                bool negative = false
                if values[i] == '-' {
                    negative = true
                    i++
                }
                quad v = 0
                if values[i] == '$' {
                    i++
                    while values[i] != 0 and values[i] != ',' {
                        ubyte hd = values[i]
                        if hd >= 'a'
                            hd = hd - 'a' + 10
                        else if hd >= 'A'
                            hd = hd - 'A' + 10
                        else
                            hd -= '0'
                        v = v * 16 + hd
                        i++
                    }
                }
                else {
                    while values[i] >= '0' and values[i] <= '9' {
                        v = v * 10 + (values[i] - '0')
                        i++
                    }
                }
                if negative
                    v = -v
                ir.text = b
                if high {
                    if v < 0
                        ir.add_number(-((-v + 255) >> 8))       ; the high byte of a negative word, as a signed value
                    else
                        ir.add_number(((v >> 8) & 255) as quad)
                }
                else
                    ir.add_number((v & 255) as quad)
            }
            if values[i] == ',' {
                buf.add_byte(b, ',')
                i++
            }
        }
        return strtab.intern(b.data, b.len as uword)
    }

    ; the name whose address stands for a symbol in initialized data
    sub data_name(^^symtab.Sym s) -> ^^ubyte {
        if is_split(s)
            return split_name(s, false)
        return sym_name(s)
    }

    sub apply_tags(^^ir.Var var, ^^ast.Node d) {
        ; (a parameter has its tags in the same place)
        if d.kind != ast.N_VARDECL and d.kind != ast.N_PARAM
            return
        ^^ast.Node tag = d.d
        while tag != 0 {
            if strings.compare(tag.name, "shared") == 0
                var.shared = true
            else if strings.compare(tag.name, "requirezp") == 0
                var.zp = "REQUIRE_ZEROPAGE"
            else if strings.compare(tag.name, "zp") == 0 {
                ; (a wish; @requirezp with it wins)
                if var.zp == 0 or strings.compare(var.zp, "REQUIRE_ZEROPAGE") != 0
                    var.zp = "PREFER_ZEROPAGE"
            }
            else if strings.compare(tag.name, "nozp") == 0
                var.zp = "NOT_IN_ZEROPAGE"
            else if strings.compare(tag.name, "dirty") == 0
                var.dirty = true
            else if strings.compare(tag.name, "alignword") == 0
                var.align = 2
            else if strings.compare(tag.name, "align64") == 0
                var.align = 64
            else if strings.compare(tag.name, "alignpage") == 0
                var.align = 256
            tag = tag.next
        }
    }

    ; the index of an element of a split array: a byte register
    sub byte_index(^^ast.Node index) -> uword {
        uword r
        ubyte t
        r, t = expression(index)
        return convert(r, t, ir.T_BYTE, false)
    }

    ; loads element [index] of a split array into a new word register
    sub split_load(^^symtab.Sym s, ^^ast.Node index) -> uword {
        ^^ubyte lo = split_name(s, false)
        ^^ubyte hi = split_name(s, true)
        uword mr = ir.new_reg(ir.T_BYTE)
        uword lr = ir.new_reg(ir.T_BYTE)
        bool ok
        quad ci
        ok, ci = typer.const_eval(index)
        if ok {
            void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, mr, hi, ci as long)
            void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, lr, lo, ci as long)
        }
        else {
            uword ixr = byte_index(index)
            void ir.emit_rmx(chunk, ir.OP_LOADX, ir.T_BYTE, mr, hi, 0, ixr, 1)
            void ir.emit_rmx(chunk, ir.OP_LOADX, ir.T_BYTE, lr, lo, 0, ixr, 1)
        }
        uword wr = ir.new_reg(ir.T_WORD)
        ^^ir.Instr ci2 = ir.emit_rrr(chunk, ir.OP_CONCAT, ir.T_BYTE, wr, mr, lr)
        ci2.t1 = ir.T_WORD
        return wr
    }

    ; stores word register r into element [index] of a split array
    sub split_store(^^symtab.Sym s, ^^ast.Node index, uword r) {
        ^^ubyte lo = split_name(s, false)
        ^^ubyte hi = split_name(s, true)
        uword part = ir.new_reg(ir.T_BYTE)
        bool ok
        quad ci
        ok, ci = typer.const_eval(index)
        uword ixr = 0
        if not ok
            ixr = byte_index(index)
        ^^ir.Instr li = ir.emit_rr(chunk, ir.OP_LSIGB, ir.T_WORD, part, r)
        li.t1 = ir.T_BYTE
        if ok
            void ir.emit_rm(chunk, ir.OP_STOREM, ir.T_BYTE, part, lo, ci as long)
        else
            void ir.emit_rmx(chunk, ir.OP_STOREX, ir.T_BYTE, part, lo, 0, ixr, 1)
        ^^ir.Instr mi = ir.emit_rr(chunk, ir.OP_MSIGB, ir.T_WORD, part, r)
        mi.t1 = ir.T_BYTE
        if ok
            void ir.emit_rm(chunk, ir.OP_STOREM, ir.T_BYTE, part, hi, ci as long)
        else
            void ir.emit_rmx(chunk, ir.OP_STOREX, ir.T_BYTE, part, hi, 0, ixr, 1)
    }

    sub declare_var(^^symtab.Sym s) {
        if s.type == 0
            return
        ^^ast.Node d = s.decl
        ^^ast.Node init = 0
        bool is_tuple = false
        if d.kind == ast.N_VARDECL and d.b != 0 {
            init = d.b
            if init.kind == ast.N_TUPLE
                is_tuple = true
        }
        ^^types.Type t = types.get(s.type)
        ^^ubyte inittext = 0
        long strlength = 0
        bool ok
        quad v
        if t.base == types.T_STR {
            if init != 0 and init.kind == ast.N_STR {
                typer.decode_literal(init)
                strlength = (init.value as long) + 1
                inittext = bytes_text(init.extra, init.value as long)
            }
            else if init != 0 and init.kind == ast.N_BINARY and init.type == types.T_STR {
                ; "x" * n and "a" + "b": fold through the typer's length and the literal
                ^^ubyte folded = fold_string(init)
                if folded != 0 {
                    strlength = buf.cstr_len(folded) + 1
                    inittext = bytes_text(folded, strlength - 1)
                }
            }
            if strlength == 0
                strlength = 1
        }
        else if t.base == types.T_ARRAY {
            if init != 0 and init.kind == ast.N_ARRAYLIT
                inittext = array_text(init, t.elem)
            else if init != 0 and init.kind == ast.N_STR {
                typer.decode_literal(init)
                inittext = bytes_text(init.extra, init.value as long)
            }
            else if init != 0 and init.kind == ast.N_RANGE
                inittext = range_text(init)
            else if init != 0 and init.kind == ast.N_BINARY and init.a.kind == ast.N_ARRAYLIT
                inittext = repeated_array_text(init, t.elem)
        }
        else if init != 0 and not is_tuple and s.scope.kind == symtab.S_BLOCK {
            ; a block level scalar with a constant initializer is initialized data
            if t.base == types.T_FLOAT {
                if typer.float_eval(init)
                    inittext = float_text(init)
                else
                    global_init(s, init)
            }
            else {
                ok, v = typer.const_eval(init)
                if ok
                    inittext = number_text(v)
                else
                    global_init(s, init)
            }
        }
        if split_words and inittext == 0 and init == 0 and s.scope.kind == symtab.S_BLOCK and t.base != types.T_ARRAY and t.base != types.T_STR and t.base != types.T_STRUCT and t.base != types.T_FLOAT
            inittext = "0"          ; upstream gives a block's plain variables an explicit zero on these targets
        if is_split(s) {
            ; two byte arrays instead of one word array
            ^^buf.Buf tb = buf.new(16)
            buf.add_str(tb, "ubyte[")
            buf.add_long(tb, t.length)
            buf.add_byte(tb, ']')
            ^^ubyte bytetype = strtab.intern(tb.data, tb.len as uword)
            ^^ir.Var lowvar = ir.add_var(prog, ir.V_VAR, split_name(s, false), bytetype, split_text(inittext, false))
            lowvar.split = true
            apply_tags(lowvar, d)
            ^^ir.Var highvar = ir.add_var(prog, ir.V_VAR, split_name(s, true), bytetype, split_text(inittext, true))
            highvar.split = true
            apply_tags(highvar, d)
            return
        }
        ^^ir.Var var = ir.add_var(prog, ir.V_VAR, sym_name(s), type_string(s.type, strlength), inittext)
        apply_tags(var, d)
    }

    ; a block variable initialized with a run time value: code in the program's
    ; global initialization chunk
    sub global_init(^^symtab.Sym s, ^^ast.Node init) {
        ^^ir.Chunk saved = chunk
        ^^symtab.Scope saved_scope = scope
        chunk = prog.initglobals
        scope = s.scope
        uword r
        ubyte vt
        ubyte tt = irt(s.type)
        untyped_struct_init(s.type, init)       ; (^^Thing t = [] at block level: an instance, not an array)
        r, vt = expression(init)
        r = convert(r, vt, tt, types.is_signed(init.type))
        void ir.emit_rm(chunk, ir.OP_STOREM, tt, r, sym_name(s), 0)
        chunk = saved
        scope = saved_scope
    }

    sub float_text(^^ast.Node e) -> ^^ubyte {
        if typer.float_eval(e) {
            buf.clear(nb)
            ir.text = nb
            ir.add_float(typer.float_value)
            return intern_nb()
        }
        unsupported(e, "float initializer expression")
        return "0.0"
    }

    ; "104,101,...,0": the bytes of a string plus its terminator
    sub bytes_text(^^ubyte bytes, long count) -> ^^ubyte {
        buf.clear(nb)
        long i = 0
        while i < count {
            buf.add_long(nb, bytes[i])
            buf.add_byte(nb, ',')
            i++
        }
        buf.add_byte(nb, '0')
        return intern_nb()
    }

    ; the folded text of a constant string expression, or 0
    sub fold_string(^^ast.Node e) -> ^^ubyte {
        bool ok
        quad count
        if e.kind == ast.N_STR {
            typer.decode_literal(e)
            return e.extra
        }
        if e.kind != ast.N_BINARY
            return 0
        ^^ubyte left = fold_string(e.a)
        if left == 0
            return 0
        if e.op == token.T_STAR {
            ok, count = typer.const_eval(e.b)
            if not ok
                return 0
            long ll = buf.cstr_len(left)
            ^^ubyte r = mem.alloc(ll * (count as long) + 1)
            long pos = 0
            repeat count as long {
                mem.copy(left, r + pos, ll)
                pos += ll
            }
            return r
        }
        if e.op == token.T_PLUS {
            ^^ubyte right = fold_string(e.b)
            if right == 0
                return 0
            long l1 = buf.cstr_len(left)
            long l2 = buf.cstr_len(right)
            ^^ubyte r2 = mem.alloc(l1 + l2 + 1)
            mem.copy(left, r2, l1)
            mem.copy(right, r2 + l1, l2)
            return r2
        }
        return 0
    }

    ; the values of an array literal: numbers as upstream writes them, addresses as @symbol
    sub array_text(^^ast.Node lit, uword elem) -> ^^ubyte {
        buf.clear(ab)
        ^^ast.Node e = lit.a
        bool ok
        quad v
        bool first = true
        while e != 0 {
            if not first
                buf.add_byte(ab, ',')
            first = false
            if e.kind == ast.N_STR {
                ; a string in a pointer array: its own interned variable
                buf.add_byte(ab, '@')
                buf.add_str(ab, intern_string(e))
            }
            else if (e.kind == ast.N_ARRAYLIT or e.kind == ast.N_STRUCTINIT) and element_struct(elem) != 0 {
                ; an element of an array of struct pointers or of struct instances: a static
                ; instance (which the back end copies into the array in the second case)
                ^^ubyte iname = struct_instance(e.a, element_struct(elem))
                buf.add_byte(ab, '@')
                buf.add_str(ab, iname)
            }
            else if e.kind == ast.N_ADDROF and e.a.kind == ast.N_IDENT and e.a.extra != 0 {
                buf.add_byte(ab, '@')
                ^^symtab.Sym asym = e.a.extra
                buf.add_str(ab, data_name(asym))
            }
            else if e.kind == ast.N_IDENT and e.extra != 0 and is_address_name(e) {
                ; a string, array or subroutine name in a word array: its address
                buf.add_byte(ab, '@')
                ^^symtab.Sym nsym = e.extra
                buf.add_str(ab, data_name(nsym))
            }
            else if e.kind == ast.N_FLOAT or elem == types.T_FLOAT
                buf.add_str(ab, float_text(e))
            else {
                ok, v = typer.constlike_eval(e)
                if ok {
                    ir.text = ab
                    ir.add_number(v)
                }
                else if address_symbol(e) != 0 {
                    buf.add_byte(ab, '@')
                    buf.add_str(ab, address_symbol(e))
                }
                else {
                    unsupported(e, "non-constant array element")
                    buf.add_byte(ab, '0')
                }
            }
            e = e.next
        }
        return strtab.intern(ab.data, ab.len as uword)
    }

    ; the struct a pointer type points to, or 0
    sub pointed_struct(uword t) -> ^^symtab.Sym {
        if t == 0 or not types.is_pointer(t)
            return 0
        ^^types.Type pt = types.get(types.elem_of(t))
        if pt.base != types.T_STRUCT
            return 0
        return pt.strct
    }

    ; [a, b, c] assigned to a pointer to a struct is a struct initializer without its type
    sub untyped_struct_init(uword target_type, ^^ast.Node value) {
        if value.kind == ast.N_ARRAYLIT and pointed_struct(target_type) != 0 {
            value.kind = ast.N_STRUCTINIT
            value.extra = pointed_struct(target_type)
        }
    }

    ; the struct of an array element that is a struct instance or a pointer to one, or 0
    sub element_struct(uword t) -> ^^symtab.Sym {
        if is_struct(t) {
            ^^types.Type st = types.get(t)
            return st.strct
        }
        return pointed_struct(t)
    }

    long instance_seq = 0

    ; A static struct instance with these field values (positional or named;
    ; none at all leaves it uninitialized).  Gives the instance's name.
    ; Buffers of its own: instances nest, and this is reached from expression().
    sub struct_instance(^^ast.Node vals, ^^symtab.Sym ss) -> ^^ubyte {
        instance_seq++
        ^^buf.Buf nm = buf.new(64)
        buf.add_str(nm, "prog8_struct_instances.")
        ^^ubyte sname = sym_name(ss)
        long k = 0
        while sname[k] != 0 {
            if sname[k] == '.'
                buf.add_byte(nm, '_')
            else
                buf.add_byte(nm, sname[k])
            k++
        }
        buf.add_byte(nm, '_')
        buf.add_long(nm, instance_seq)
        ^^ubyte iname = strtab.intern(nm.data, nm.len as uword)
        ^^ubyte values = 0
        if vals != 0 and ss.inner != 0 {
            ^^buf.Buf vb = buf.new(128)
            ^^symtab.Sym f = ss.inner.syms
            ^^ast.Node v = vals
            bool first = true
            while f != 0 {
                if f.type != 0 {
                    ^^ast.Node fv = v
                    if vals.kind == ast.N_NAMEDFIELD {
                        fv = vals
                        while fv != 0 and strings.compare(fv.name, f.name) != 0
                            fv = fv.next
                        if fv != 0
                            fv = fv.a
                    }
                    else if v != 0
                        v = v.next
                    if types.is_array(f.type) {
                        ; an array in the struct: its elements one by one, as upstream lists
                        ; them; those without a value are 0
                        ^^types.Type at = types.get(f.type)
                        uword et = types.elem_of(f.type)
                        ^^ast.Node ev = 0
                        ^^ubyte text = 0
                        long textlen = 0
                        if fv != 0 and fv.kind == ast.N_ARRAYLIT
                            ev = fv.a
                        else if fv != 0 and fv.kind == ast.N_STR and types.size_of(et) == 1 {
                            ; a string fills an array of bytes (its zero too, where there is room)
                            typer.decode_literal(fv)
                            text = fv.extra
                            textlen = fv.value as long
                            if textlen > at.length {
                                buf.clear(nb)
                                buf.add_str(nb, "string literal (")
                                buf.add_long(nb, textlen)
                                buf.add_str(nb, " bytes) does not fit in ubyte array field '")
                                buf.add_str(nb, f.name)
                                buf.add_str(nb, "' of size ")
                                buf.add_long(nb, at.length)
                                buf.add_byte(nb, 0)
                                error(fv, strtab.intern_cstr(nb.data))
                                textlen = at.length
                            }
                        }
                        else if fv != 0
                            unsupported(fv, "this value for an array in a struct")
                        long n
                        for n in 0 to at.length - 1 {
                            if not first
                                buf.add_byte(vb, ',')
                            first = false
                            field_type_into(vb, et)
                            buf.add_byte(vb, ':')
                            if text != 0 {
                                ir.text = vb
                                if n < textlen
                                    ir.add_number(text[n])
                                else
                                    ir.add_number(0)
                            }
                            else {
                                if ev != 0 {
                                    bool eok
                                    quad evalue
                                    eok, evalue = typer.const_eval(ev)
                                    if eok and not typer.literal_fits(evalue, et)
                                        error(ev, "invalid assignment value")
                                }
                                field_value_into(vb, ev, et)
                            }
                            if ev != 0
                                ev = ev.next
                        }
                        f = f.next
                        continue
                    }
                    if not first
                        buf.add_byte(vb, ',')
                    first = false
                    field_type_into(vb, f.type)
                    buf.add_byte(vb, ':')
                    field_value_into(vb, fv, f.type)
                }
                f = f.next
            }
            values = strtab.intern(vb.data, vb.len as uword)
        }
        ^^ir.Var iv = ir.add_var(prog, ir.V_INSTANCE, iname, sname, values)
        iv.size = types.struct_size(ss)
        return iname
    }

    sub basic_type_into(^^buf.Buf b, ubyte base) {
        when base {
            types.T_BOOL -> buf.add_str(b, "bool")
            types.T_UBYTE -> buf.add_str(b, "ubyte")
            types.T_BYTE -> buf.add_str(b, "byte")
            types.T_UWORD -> buf.add_str(b, "uword")
            types.T_WORD -> buf.add_str(b, "word")
            types.T_LONG -> buf.add_str(b, "long")
            types.T_QUAD -> buf.add_str(b, "quad")
            types.T_UQUAD -> buf.add_str(b, "uquad")
            types.T_FLOAT -> buf.add_str(b, "float")
            else -> buf.add_str(b, "pointer")
        }
    }

    ; a struct field's type as upstream prints it in an instance's value list
    sub field_type_into(^^buf.Buf b, uword t) {
        ^^types.Type tt = types.get(t)
        if tt.base == types.T_STR {
            buf.add_str(b, "^^ubyte")
            return
        }
        if tt.base == types.T_POINTER and tt.elem != 0 {
            buf.add_str(b, "^^")
            ^^types.Type pt = types.get(tt.elem)
            if pt.base == types.T_STRUCT {
                ^^symtab.Sym ps = pt.strct
                buf.add_str(b, sym_name(ps))
            }
            else
                basic_type_into(b, pt.base)
            return
        }
        basic_type_into(b, tt.base)
    }

    ; memory("name", size, align): the block's name for the assembler; it is declared when
    ; it is first named
    sub slab_of(^^ast.Node mcall) -> ^^ubyte {
        ^^ast.Node a = mcall.b
        ; (the name as written, not its bytes in the target's encoding)
        buf.clear(nb)
        buf.add_str(nb, "prog8_slabs.memory_")
        long sk = 0
        while a.name != 0 and a.name[sk] != 0 {
            ubyte sc = a.name[sk]
            if (sc >= 'a' and sc <= 'z') or (sc >= 'A' and sc <= 'Z') or (sc >= '0' and sc <= '9')
                buf.add_byte(nb, sc)
            else
                buf.add_byte(nb, '_')
            sk++
        }
        ^^ubyte slabname = intern_nb()
        bool sok
        quad ssize
        quad salign
        ssize = 0
        salign = 0
        if a.next != 0 {
            ; (memory("name") alone names a block that is declared elsewhere)
            sok, ssize = typer.const_eval(a.next)
            if not sok
                ssize = 0
            if a.next.next != 0 {
                sok, salign = typer.const_eval(a.next.next)
                if not sok
                    salign = 0
            }
        }
        ^^ir.Var known = find_var(slabname)
        if known == 0 {
            ^^ir.Var slab = ir.add_var(prog, ir.V_SLAB, slabname, "", 0)
            slab.size = ssize as long
            slab.align = salign as long
        }
        else if known.size != 0 and ssize != 0 and (known.size != (ssize as long) or known.align != (salign as long)) {
            ; one name is one block
            ^^buf.Buf mb = buf.new(128)
            buf.add_str(mb, "memory block '")
            buf.add_str(mb, a.name)
            buf.add_str(mb, "' already exists with a different size and/or alignment")
            buf.add_byte(mb, 0)
            error(mcall, mb.data)
        }
        else if known.size == 0 and ssize != 0 {
            ; (named before it was given its size)
            known.size = ssize as long
            known.align = salign as long
        }
        return slabname
    }

    ; The assembler's name for a value that is an address it works out: a call of
    ; memory(), or a constant that is one.  0 for anything else.
    sub address_symbol(^^ast.Node e) -> ^^ubyte {
        if e == 0
            return 0
        if e.kind == ast.N_CALL and e.a != 0 and e.a.kind == ast.N_IDENT and e.a.name != 0 and strings.compare(e.a.name, "memory") == 0
                and e.b != 0 and e.b.kind == ast.N_STR and e.b.next != 0 and e.b.next.next != 0
            return slab_of(e)
        if e.kind == ast.N_IDENT and e.extra != 0 {
            ^^symtab.Sym s = e.extra
            if s.kind == symtab.K_CONST and s.decl != 0 and s.decl.kind == ast.N_VARDECL and s.decl.b != 0 and s.decl.b.kind == ast.N_CALL
                return address_symbol(s.decl.b)
        }
        return 0
    }

    sub field_value_into(^^buf.Buf b, ^^ast.Node fv, uword ftype) {
        if fv == 0 {
            buf.add_byte(b, '0')
            return
        }
        if fv.kind == ast.N_STR {
            ^^ubyte sn = intern_string(fv)
            buf.add_byte(b, '@')
            buf.add_str(b, sn)
            return
        }
        if (fv.kind == ast.N_STRUCTINIT or fv.kind == ast.N_ARRAYLIT) and pointed_struct(ftype) != 0 {
            ^^ubyte inner = struct_instance(fv.a, pointed_struct(ftype))
            buf.add_byte(b, '@')
            buf.add_str(b, inner)
            return
        }
        if fv.kind == ast.N_ADDROF and fv.a.kind == ast.N_IDENT and fv.a.extra != 0 {
            ^^symtab.Sym asym = fv.a.extra
            buf.add_byte(b, '@')
            buf.add_str(b, data_name(asym))
            return
        }
        if fv.kind == ast.N_IDENT and fv.extra != 0 and is_address_name(fv) {
            ^^symtab.Sym nsym = fv.extra
            buf.add_byte(b, '@')
            buf.add_str(b, data_name(nsym))
            return
        }
        if fv.kind == ast.N_FLOAT or ftype == types.T_FLOAT {
            ^^ubyte ft = float_text(fv)
            buf.add_str(b, ft)
            return
        }
        bool ok
        quad cv
        ok, cv = typer.const_eval(fv)
        if not ok {
            ^^ubyte known = address_symbol(fv)
            if known != 0 {
                buf.add_byte(b, '@')
                buf.add_str(b, known)
                return
            }
            unsupported(fv, "non-constant struct field value")
            cv = 0
        }
        ir.text = b
        ir.add_number(cv)
    }

    sub is_address_name(^^ast.Node e) -> bool {
        ^^symtab.Sym s = e.extra
        if s.kind == symtab.K_SUB or s.kind == symtab.K_LABEL or s.kind == symtab.K_BLOCK
            return true
        if s.kind == symtab.K_VAR and s.type != 0
            return types.is_array(s.type) or s.type == types.T_STR
        return false
    }

    sub repeated_array_text(^^ast.Node init, uword elem) -> ^^ubyte {
        bool ok
        quad count
        ok, count = typer.const_eval(init.b)
        if not ok {
            unsupported(init, "array repeat count")
            return 0
        }
        ^^ubyte once = array_text(init.a, elem)
        buf.clear(nb)
        repeat count as long {
            if nb.len != 0
                buf.add_byte(nb, ',')
            buf.add_str(nb, once)
        }
        return intern_nb()
    }

    sub range_text(^^ast.Node r) -> ^^ubyte {
        bool ok
        quad from
        quad to_value
        quad stride = 1
        ok, from = typer.whole_const(r.a)
        if not ok
            return 0
        ok, to_value = typer.whole_const(r.b)
        if not ok
            return 0
        if r.c != 0 {
            ok, stride = typer.const_eval(r.c)
            if not ok
                return 0
        }
        else if r.op == token.T_KW_DOWNTO
            stride = -1
        buf.clear(nb)
        ir.text = nb
        quad v = from
        bool first = true
        while (stride > 0 and v <= to_value) or (stride < 0 and v >= to_value) {
            if not first
                buf.add_byte(nb, ',')
            first = false
            ir.add_number(v)
            v += stride
        }
        return intern_nb()
    }

    sub declare_const(^^symtab.Sym s) {
        if s.type == 0 or s.decl.kind != ast.N_VARDECL or s.decl.b == 0
            return
        bool ok
        quad v
        ^^ubyte valuetext
        if s.type == types.T_FLOAT
            valuetext = float_text(s.decl.b)
        else {
            ok, v = typer.const_eval(s.decl.b)
            if not ok
                return
            valuetext = number_text(v)
        }
        ^^ir.Var c = ir.add_var(prog, ir.V_CONST, sym_name(s), type_string(s.type, 0), valuetext)
    }

    ; An enum's members are constants for assembly code: Enum_MEMBER (p8c_Enum_MEMBER
    ; where the block's names have prefixes), next to the enum.
    sub declare_enum(^^symtab.Sym s) {
        if s.inner == 0
            return
        ^^symtab.Sym m = s.inner.syms
        while m != 0 {
            if m.kind == symtab.K_ENUMMEMBER and m.decl != 0 {
                ^^ubyte full = sym_name(m)
                long cut = buf.cstr_len(full)
                while cut > 0 and full[cut - 1] != '.'
                    cut--
                bool prefixed = buf.bytes_equal(full + cut, "p8c_", 4)
                ; the scope the enum is in: the name without its last two parts
                long upto = cut
                if upto > 0
                    upto--
                while upto > 0 and full[upto - 1] != '.'
                    upto--
                buf.clear(nb)
                long k = 0
                while k < upto {
                    buf.add_byte(nb, full[k])
                    k++
                }
                if prefixed
                    buf.add_str(nb, "p8c_")
                buf.add_str(nb, s.name)
                buf.add_byte(nb, '_')
                buf.add_str(nb, m.name)
                ^^ubyte ename = intern_nb()
                ^^ubyte etype = type_string(m.type, 0)
                void ir.add_var(prog, ir.V_CONST, ename, etype, number_text(typer.enum_value(m.decl)))
            }
            m = m.next
        }
    }

    sub declare_memvar(^^symtab.Sym s) {
        if s.type == 0 or s.decl.kind != ast.N_VARDECL or s.decl.b == 0
            return
        bool ok
        quad v
        ok, v = typer.const_eval(s.decl.b)
        if not ok
            return
        ^^types.Type t = types.get(s.type)
        long strlength = 0
        if t.base == types.T_STR
            strlength = 1
        ^^ir.Var m = ir.add_var(prog, ir.V_MEMVAR, sym_name(s), type_string(s.type, strlength), number_text(v))
    }

    sub declare_struct(^^symtab.Sym s) {
        if s.inner == 0
            return
        buf.clear(nb)
        ^^symtab.Sym f = s.inner.syms
        bool first = true
        while f != 0 {
            if f.type != 0 {
                if not first
                    buf.add_byte(nb, ';')
                first = false
                if f.type == types.T_STR
                    buf.add_str(nb, "pointer")      ; a string field holds the string's address
                else
                    type_string_into(f.type, 0)
                buf.add_byte(nb, ' ')
                buf.add_str(nb, f.name)
            }
            f = f.next
        }
        ^^ubyte fields = intern_nb()
        ^^ir.Var st = ir.add_var(prog, ir.V_STRUCT, sym_name(s), fields, 0)
        st.size = types.struct_size(s)
    }

    ; The byte offset of a field in its struct (fields are packed in order).
    sub field_offset(^^symtab.Sym f) -> long {
        ^^symtab.Scope sc = f.scope
        if sc.owner != 0 and sc.owner.kind == ast.N_UNION
            return 0
        long offset = 0
        ^^symtab.Sym s = sc.syms
        while s != 0 and s != f {
            if s.type != 0
                offset += types.size_of(s.type)
            s = s.next
        }
        return offset
    }

    ; The memory reference of a variable: its scoped name, or (0, address) for
    ; a memory-mapped variable, which the IR refers to by address.
    sub var_ref(^^symtab.Sym s) -> ^^ubyte, long {
        if s.kind == symtab.K_MEMVAR and s.decl.kind == ast.N_VARDECL and s.decl.b != 0 {
            bool ok
            quad addr
            ok, addr = typer.const_eval(s.decl.b)
            if ok
                return 0, addr as long
        }
        return sym_name(s), 0
    }

    ; ---- string literals ----

    sub intern_string(^^ast.Node e) -> ^^ubyte {
        typer.decode_literal(e)
        ^^ubyte bytes = e.extra
        long length = e.value as long
        ^^IString s = istrings
        while s != 0 {
            if s.length == length and buf.bytes_equal(s.bytes, bytes, length)
                return s.name
            s = s.next
        }
        istring_count++
        buf.clear(nb)
        buf.add_str(nb, "prog8_interned_strings.string_")
        buf.add_long(nb, istring_count)
        ^^IString ns = mem.alloc(sizeof(IString))
        ns.bytes = bytes
        ns.length = length
        ns.name = intern_nb()
        ns.next = istrings
        istrings = ns
        buf.clear(nb)
        buf.add_str(nb, "ubyte[")
        buf.add_long(nb, length + 1)
        buf.add_byte(nb, ']')
        ^^ubyte ts = intern_nb()
        ^^ir.Var v = ir.add_var(prog, ir.V_VAR, ns.name, ts, bytes_text(bytes, length))
        v.zp = "NOT_IN_ZEROPAGE"
        return ns.name
    }

    ; an array literal used as a value: an interned variable of the given element type
    long iarray_count = 0
    sub intern_array(^^ast.Node lit, uword elemtype) -> ^^ubyte {
        iarray_count++
        buf.clear(nb)
        buf.add_str(nb, "prog8_interned_strings.array_")
        buf.add_long(nb, iarray_count)
        ^^ubyte name = intern_nb()
        ^^ubyte values = array_text(lit, elemtype)
        buf.clear(nb)
        type_string_into(elemtype, 0)
        buf.add_byte(nb, '[')
        buf.add_long(nb, ast.list_length(lit.a))
        buf.add_byte(nb, ']')
        ^^ubyte ts = intern_nb()
        ^^ir.Var v = ir.add_var(prog, ir.V_VAR, name, ts, values)
        v.zp = "NOT_IN_ZEROPAGE"
        return name
    }

    ; ---- blocks and subroutines ----

    ; The zero page scratch locations library assembly code uses, which
    ; upstream declares as memory-mapped variables on the 6502 targets.
    sub scratch_variables() {
        if not target.loaded
            return
        long b1 = target.number("zp_scratch_b1", -1)
        long w1 = target.number("zp_scratch_w1", -1)
        long w2 = target.number("zp_scratch_w2", -1)
        long scratch_ptr = target.number("zp_scratch_ptr", -1)
        if b1 < 0 or w1 < 0 or w2 < 0
            return
        void ir.add_var(prog, ir.V_MEMVAR, "P8ZP_SCRATCH_B1", "ubyte", number_text(b1 as uword))
        void ir.add_var(prog, ir.V_MEMVAR, "P8ZP_SCRATCH_REG", "ubyte", number_text(target.number("zp_scratch_reg", b1 + 1) as uword))
        void ir.add_var(prog, ir.V_MEMVAR, "P8ZP_SCRATCH_W1", "uword", number_text(w1 as uword))
        void ir.add_var(prog, ir.V_MEMVAR, "P8ZP_SCRATCH_W2", "uword", number_text(w2 as uword))
        if scratch_ptr >= 0
            void ir.add_var(prog, ir.V_MEMVAR, "P8ZP_SCRATCH_PTR", "uword", number_text(scratch_ptr as uword))
    }

    ; The compilation options of a 6502 program, from the directives of its
    ; main module and the target's defaults, as upstream derives them.
    ; On machines where the library has the virtual registers R0-R15 outside the zero page
    ; (the C64: $cfe0), upstream moves them into it when the program has the zero page
    ; to itself (%zeropage kernalsafe, the default, or full), so that assembly code can
    ; use them as pointers.  The target's file says where (virtual_registers_zp).  It is
    ; done by giving cx16's memory mapped variables their new addresses.
    long vregs_moved_to = -1        ; (for the code generator: these bytes are not free)

    sub zeropage_registers() {
        vregs_moved_to = -1
        if not target.loaded
            return
        long from = target.number("virtual_registers", -1)
        long into = target.number("virtual_registers_zp", -1)
        if from < 256 or into < 0
            return
        ^^ubyte opt_floats = strtab.intern_cstr("enable_floats")
        bool kernalsafe = true
        bool given = false
        bool floats = false
        bool library = false
        if target.text("output_type") != 0 and strings.compare(upper_name(target.text("output_type")), "LIBRARY") == 0
            library = true
        ^^importer.Module m = importer.modules
        bool main_module = true
        while m != 0 {
            if symtab.has_option(m.tree.a, opt_floats)
                floats = true
            if main_module {
                ^^ast.Node d = m.tree.a
                while d != 0 {
                    if d.kind == ast.N_DIRECTIVE and d.a != 0 and d.a.name != 0 {
                        if strings.compare(d.name, "zeropage") == 0 {
                            given = true
                            kernalsafe = strings.compare(d.a.name, "kernalsafe") == 0 or strings.compare(d.a.name, "full") == 0
                        }
                        else if strings.compare(d.name, "output") == 0
                            library = strings.compare(d.a.name, "library") == 0
                    }
                    d = d.next
                }
            }
            main_module = false
            m = m.next
        }
        if library or not kernalsafe or (floats and not given)
            return
        ^^symtab.Sym block = symtab.find_in(symtab.global, strtab.intern_cstr("cx16"))
        if block == 0 or block.inner == 0
            return
        ^^symtab.Sym s = block.inner.syms
        while s != 0 {
            if s.kind == symtab.K_MEMVAR and s.decl != 0 and s.decl.kind == ast.N_VARDECL and s.decl.b != 0 {
                bool ok
                quad at
                ok, at = typer.const_eval(s.decl.b)
                if ok and at >= from and at < from + 32 {
                    s.decl.b.kind = ast.N_INT
                    s.decl.b.value = into + (at - from)
                    s.decl.b.a = 0
                    s.decl.b.b = 0
                    vregs_moved_to = into
                }
            }
            s = s.next
        }
    }

    long option_address = -1        ; -address of the command line

    sub program_options() {
        if not target.loaded
            return              ; not a machine with a configuration: the neutral defaults
        long loadaddress = target.number("load_address", $0801)
        long memtop = target.number("memtop", $ffff)
        ^^ubyte output = "PRG"
        ^^ubyte launcher = "BASIC"
        if target.text("output_type") != 0
            output = upper_name(target.text("output_type"))
        if target.text("launcher") != 0
            launcher = upper_name(target.text("launcher"))
        ^^ubyte zeropage = "KERNALSAFE"
        bool given_zeropage = false
        bool floats = false
        bool no_sysinit = false
        bool romable = false
        long allowed_first = 0
        long allowed_last = 255
        ^^buf.Buf reserved = buf.new(64)
        bool ok2
        quad v2
        ^^ubyte opt_floats = strtab.intern_cstr("enable_floats")
        ^^ubyte opt_nosysinit = strtab.intern_cstr("no_sysinit")
        ^^ubyte opt_romable = strtab.intern_cstr("romable")
        bool ok
        quad v
        ^^importer.Module m = importer.modules
        bool main_module = true
        while m != 0 {
            if symtab.has_option(m.tree.a, opt_floats)
                floats = true
            if symtab.has_option(m.tree.a, opt_nosysinit)
                no_sysinit = true
            if symtab.has_option(m.tree.a, opt_romable)
                romable = true
            if main_module {
                ^^ast.Node d = m.tree.a
                while d != 0 {
                    if d.kind == ast.N_DIRECTIVE and d.a != 0 {
                        if strings.compare(d.name, "output") == 0 and d.a.name != 0
                            output = upper_name(d.a.name)
                        else if strings.compare(d.name, "launcher") == 0 and d.a.name != 0
                            launcher = upper_name(d.a.name)
                        else if strings.compare(d.name, "zeropage") == 0 and d.a.name != 0 {
                            zeropage = upper_name(d.a.name)
                            given_zeropage = true
                        }
                        else if strings.compare(d.name, "address") == 0 {
                            ok, v = typer.const_eval(d.a)
                            if ok
                                loadaddress = v as long
                        }
                        else if strings.compare(d.name, "varsaddress") == 0 {
                            ok, v = typer.const_eval(d.a)
                            if ok
                                prog.vars_address = v as long
                        }
                        else if (strings.compare(d.name, "zpallowed") == 0 or strings.compare(d.name, "zpreserved") == 0) and d.a.next != 0 {
                            ; a range of the zero page: the only one the variables may use, or one they may not
                            ok, v = typer.const_eval(d.a)
                            ok2, v2 = typer.const_eval(d.a.next)
                            if ok and ok2 {
                                if d.name[2] == 'a' {
                                    allowed_first = v as long
                                    allowed_last = v2 as long
                                }
                                else {
                                    buf.add_str(reserved, "\nzpReserved=")
                                    buf.add_long(reserved, v as long)
                                    buf.add_byte(reserved, ',')
                                    buf.add_long(reserved, v2 as long)
                                }
                            }
                        }
                        else if strings.compare(d.name, "memtop") == 0 {
                            ok, v = typer.const_eval(d.a)
                            if ok
                                memtop = v as long
                        }
                    }
                    d = d.next
                }
            }
            main_module = false
            m = m.next
        }
        prog.floats = floats
        if floats and not given_zeropage
            zeropage = "FLOATSAFE"
        if strings.compare(output, "LIBRARY") == 0 {
            launcher = "NONE"
            zeropage = "DONTUSE"
            no_sysinit = true
        }
        if option_address >= 0
            loadaddress = option_address        ; -address, in place of %address
        if strings.compare(output, "PRG") == 0 and strings.compare(launcher, "BASIC") == 0 and target.text("custom_launcher_code") == 0
            and loadaddress != target.number("load_address", $0801) and importer.modules != 0 and importer.modules.tree != 0 {
            ; the BASIC line that starts the program is where BASIC programs are
            ^^buf.Buf lb = buf.new(64)
            buf.add_str(lb, "BASIC output must have load address $")
            long basic_at = target.number("load_address", $0801)
            ^^ubyte hexdigits = "0123456789abcdef"
            buf.add_byte(lb, hexdigits[((basic_at >> 12) & 15) as ubyte])
            buf.add_byte(lb, hexdigits[((basic_at >> 8) & 15) as ubyte])
            buf.add_byte(lb, hexdigits[((basic_at >> 4) & 15) as ubyte])
            buf.add_byte(lb, hexdigits[(basic_at & 15) as ubyte])
            buf.add_byte(lb, 0)
            error(importer.modules.tree, lb.data)
        }
        if loadaddress > memtop
            memtop = $ffff
        ^^buf.Buf ob = buf.new(256)
        buf.add_str(ob, "output=")
        buf.add_str(ob, output)
        buf.add_str(ob, "\nlauncher=")
        buf.add_str(ob, launcher)
        buf.add_str(ob, "\nzeropage=")
        buf.add_str(ob, zeropage)
        buf.add_bytes(ob, reserved.data, reserved.len)
        buf.add_str(ob, "\nzpAllowed=")
        buf.add_long(ob, allowed_first)
        buf.add_byte(ob, ',')
        buf.add_long(ob, allowed_last)
        buf.add_str(ob, "\nloadAddress=")
        buf.add_str(ob, number_text(loadaddress))
        buf.add_str(ob, "\nmemtop=")
        buf.add_str(ob, number_text(memtop))
        buf.add_str(ob, "\noptimize=true\nromable=")
        if romable
            buf.add_str(ob, "true")
        else
            buf.add_str(ob, "false")
        buf.add_str(ob, "\nnoSysInit=")
        if no_sysinit
            buf.add_str(ob, "true\n")
        else
            buf.add_str(ob, "false\n")
        prog.options = strtab.intern(ob.data, ob.len as uword)
    }

    sub upper_name(^^ubyte name) -> ^^ubyte {
        ^^buf.Buf ub = buf.new(32)
        long k = 0
        while name[k] != 0 {
            ubyte c = name[k]
            if c >= 'a' and c <= 'z'
                c -= 32
            buf.add_byte(ub, c)
            k++
        }
        return strtab.intern(ub.data, ub.len as uword)
    }

    sub gen_block(^^ast.Node b) {
        ^^symtab.Sym bs = b.extra
        if bs == 0
            return
        ^^ubyte bname = sym_name(bs)
        block = find_block(bname)
        if block == 0 {
            block = ir.add_block(prog, bname, pos_text(b), module.is_library)
            ; (these two options may also be given for the whole module)
            block.ignore_unused = symtab.has_option(b.a, strtab.intern_cstr("ignore_unused")) or symtab.has_option(module.tree.a, strtab.intern_cstr("ignore_unused"))
            block.force_output = symtab.has_option(b.a, strtab.intern_cstr("force_output"))
            block.chipram = symtab.has_option(b.a, strtab.intern_cstr("amiga_chipram"))
            block.overlay_data = symtab.has_option(b.a, strtab.intern_cstr("overlay_data"))
            block.overlay_safe = symtab.has_option(b.a, strtab.intern_cstr("overlay_safe")) or symtab.has_option(module.tree.a, strtab.intern_cstr("overlay_safe"))
            ^^ast.Node od = b.a
            while od != 0 {
                if od.kind == ast.N_DIRECTIVE and od.a != 0 and strings.compare(od.name, "overlay") == 0 {
                    block.overlay = overlay_number(od)
                    ir.overlay_wanted[block.overlay] = true
                    overlay_inline = od
                }
                od = od.next
            }
            block.no_prefixing = symtab.has_option(b.a, strtab.intern_cstr("no_symbol_prefixing")) or symtab.has_option(module.tree.a, strtab.intern_cstr("no_symbol_prefixing"))
        }
        if b.b != 0 {
            bool ok
            quad addr
            ok, addr = typer.const_eval(b.b)
            if ok
                block.address = number_text(addr)
        }
        gen_block_members(b.a, bs.inner)
    }

    sub find_var(^^ubyte name) -> ^^ir.Var {
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.name == name
                return v
            v = v.next
        }
        return 0
    }

    sub find_block(^^ubyte name) -> ^^ir.Block {
        ^^ir.Block b = prog.blocks
        while b != 0 {
            if b.name == name
                return b
            b = b.next
        }
        return 0
    }

    ; %asminclude "file": the file's text as an assembly chunk of the block.
    ; "library:name" is looked up in the library directory, anything else
    ; next to the source file that includes it.
    ; (inside a subroutine or an asmsub the text of an include is handed back, not made a
    ; part of the block)
    bool include_keep = false
    ^^ubyte included_text = 0
    long included_len = 0

    sub included(^^ast.Node d) -> bool {
        if d.kind != ast.N_DIRECTIVE or d.a == 0 or d.a.kind != ast.N_STR
            return false
        included_text = 0
        included_len = 0
        include_keep = true
        if strings.compare(d.name, "asminclude") == 0
            include_assembly(d)
        else if strings.compare(d.name, "asmbinary") == 0
            include_binary(d)
        include_keep = false
        return included_text != 0
    }

    sub include_assembly(^^ast.Node d) {
        ^^ubyte name = d.a.name
        ^^buf.Buf pb = buf.new(256)
        if buf.bytes_equal(name, "library:", 8)
            importer.library_file(name + 8, pb)
        else {
            ^^ubyte from = module.file.name
            long slash = buf.cstr_len(from)
            while slash > 0 and from[slash - 1] != '/'
                slash--
            buf.add_bytes(pb, from, slash)
            buf.add_str(pb, name)
        }
        buf.add_byte(pb, 0)
        ^^source.File f = source.load(pb.data)
        if f == 0
            f = source.load(name)       ; (not beside the source: as it is written, as upstream)
        if f == 0 {
            error(d, "cannot read the included assembly file")
            return
        }
        if include_keep {
            included_text = f.text
            included_len = f.len
            return
        }
        ^^ir.Chunk bc = ir.add_block_chunk(block, 0)
        bc.kind = ir.C_ASM
        bc.text = f.text
        bc.textlen = f.len
        bc.is_ir = false
    }

    ; %asmbinary "file" [, offset [, length]]: the bytes of the file as data in the block.
    ; (Written out as .byte lines, so that where the assembler looks for files does not matter.)
    sub include_binary(^^ast.Node d) {
        ^^ubyte name = d.a.name
        ^^buf.Buf pb = buf.new(256)
        if buf.bytes_equal(name, "library:", 8)
            importer.library_file(name + 8, pb)
        else if io_platform.file_size(name) >= 0 {
            ; (as it is written, from where the compiler runs: upstream looks there first)
            buf.add_str(pb, name)
        }
        else {
            ^^ubyte from = module.file.name
            long slash = buf.cstr_len(from)
            while slash > 0 and from[slash - 1] != '/'
                slash--
            buf.add_bytes(pb, from, slash)
            buf.add_str(pb, name)
        }
        buf.add_byte(pb, 0)
        long size = io_platform.file_size(pb.data)
        if size < 0 {
            error(d, "cannot read the included binary file")
            return
        }
        ^^ubyte data = mem.alloc(size + 1)
        size = io_platform.read_file(pb.data, data, size)
        long first = 0
        long count = size
        bool ok
        quad v
        if d.a.next != 0 {
            ok, v = typer.const_eval(d.a.next)
            if ok
                first = v as long
            count = size - first
            if d.a.next.next != 0 {
                ok, v = typer.const_eval(d.a.next.next)
                if ok and (v as long) < count
                    count = v as long
            }
        }
        if first < 0 or first > size or count < 0 {
            error(d, "the offset is past the end of the included binary file")
            return
        }
        ^^buf.Buf tb = buf.new(count * 4 + 64)
        long k = 0
        while k < count {
            if k % 16 == 0 {
                if k != 0
                    buf.add_byte(tb, '\n')
                if types.POINTER_SIZE == 4
                    buf.add_str(tb, "    dc.b  ")        ; vasm, for the 68000 machines
                else
                    buf.add_str(tb, "    .byte  ")
            }
            else
                buf.add_byte(tb, ',')
            buf.add_long(tb, data[first + k])
            k++
        }
        buf.add_byte(tb, '\n')
        if types.POINTER_SIZE == 4
            buf.add_str(tb, "    even\n")
        if include_keep {
            included_text = tb.data
            included_len = tb.len
            return
        }
        ^^ir.Chunk bc = ir.add_block_chunk(block, 0)
        bc.kind = ir.C_ASM
        bc.text = tb.data
        bc.textlen = tb.len
        bc.is_ir = false
    }

    sub gen_block_members(^^ast.Node stmts, ^^symtab.Scope sc) {
        ^^ast.Node s = stmts
        while s != 0 {
            when s.kind {
                ast.N_SUB -> gen_sub(s)
                ast.N_ASMSUB, ast.N_EXTSUB -> gen_asmsub(s)
                ast.N_ASM -> {
                    ^^ir.Chunk bc = ir.add_block_chunk(block, 0)
                    bc.kind = ir.C_ASM
                    bc.text = s.extra
                    bc.textlen = s.value as long
                    bc.is_ir = s.name == n_ir
                }
                ast.N_LABEL -> {
                    ^^symtab.Sym ls = s.extra
                    if ls != 0
                        void ir.add_block_chunk(block, sym_name(ls))
                }
                ast.N_DIRECTIVE -> {
                    if strings.compare(s.name, "jmptable") == 0 {
                        ; %jmptable (a, b, ...): a jump to each of the subroutines, where the directive
                        ; is.  As assembly text: a table is not code to be improved.
                        ^^buf.Buf jt = buf.new(128)
                        buf.add_str(jt, "    ; jumptable\n")
                        ^^ast.Node entry = s.a
                        while entry != 0 {
                            ^^symtab.Sym target_sub = entry.extra
                            if entry.kind == ast.N_IDENT and target_sub != 0 and target_sub.kind == symtab.K_SUB {
                                buf.add_str(jt, "    jmp  ")
                                buf.add_str(jt, sym_name(target_sub))
                                buf.add_byte(jt, '\n')
                            }
                            else
                                error(entry, "jmptable entry must be a subroutine name")
                            entry = entry.next
                        }
                        buf.add_str(jt, "    ; end jumptable\n")
                        ^^ir.Chunk jc = ir.add_block_chunk(block, 0)
                        jc.kind = ir.C_ASM
                        jc.text = jt.data
                        jc.textlen = jt.len
                        jc.is_ir = false
                    }
                    else if strings.compare(s.name, "asminclude") == 0 and s.a != 0 and s.a.kind == ast.N_STR
                        include_assembly(s)
                    else if strings.compare(s.name, "asmbinary") == 0 and s.a != 0 and s.a.kind == ast.N_STR
                        include_binary(s)
                    else if strings.compare(s.name, "align") == 0 and s.a != 0 and prefixing {
                        ; %align N: what follows starts at a multiple of N (for the assembler)
                        bool aok
                        quad av
                        aok, av = typer.const_eval(s.a)
                        if aok and av > 1 {
                            ^^buf.Buf alb = buf.new(32)
                            ; (64tass, or vasm for the 68000 machines)
                            if types.POINTER_SIZE == 4
                                buf.add_str(alb, "    cnop  0,")
                            else
                                buf.add_str(alb, "    .align  ")
                            buf.add_long(alb, av as long)
                            buf.add_byte(alb, '\n')
                            ^^ir.Chunk ac = ir.add_block_chunk(block, 0)
                            ac.kind = ir.C_ASM
                            ac.text = alb.data
                            ac.textlen = alb.len
                            ac.is_ir = false
                        }
                    }
                }
            }
            s = s.next
        }
    }

    ; ---- defer ----
    ;
    ; Upstream's scheme.  A subroutine with defer statements has a mask variable with a
    ; bit per defer, cleared on entry; a defer statement sets its bit; every way out of
    ; the subroutine calls its handler routine prog8_invoke_defers, which runs the bodies
    ; whose bit is set, last one first.  So that sys.exit can run the pending defers of
    ; all callers too, such a subroutine pushes its handler's number on a stack of active
    ; frames on entry and pops it on the way out, and every call of sys.exit first calls
    ; prog8_defer.defer_unwind_all, which works that stack down.  A program without defer
    ; has none of this.

    struct DeferSub {
        ^^DeferSub next
        ^^ubyte invoke          ; name of the handler routine
        ubyte id
    }

    const ubyte MAX_DEFERS = 8          ; per subroutine: the bits of the mask
    const ubyte MAX_DEFER_FRAMES = 32
    bool program_defers = false         ; the program has a defer statement somewhere
    ^^DeferSub defer_subs = 0
    ^^DeferSub last_defer_sub = 0
    ubyte defer_sub_count = 0
    ^^ast.Node[MAX_DEFERS] defer_nodes  ; of the subroutine being generated (nested ones are done before it)
    ubyte defer_count = 0
    ^^ubyte defer_mask = 0
    ^^ubyte defer_invoke = 0
    ^^ubyte defer_sp_name = 0
    ^^ubyte defer_guard_name = 0
    ^^ubyte defer_stack_name = 0
    ^^ubyte defer_unwind_name = 0
    uword[16] return_regs
    ubyte[16] return_types

    ; is there a defer statement in this statement list, nested subroutines included
    sub any_defer(^^ast.Node n) -> bool {
        while n != 0 {
            if n.kind == ast.N_DEFER
                return true
            if any_defer(n.a) or any_defer(n.b) or any_defer(n.c) or any_defer(n.d)
                return true
            n = n.next
        }
        return false
    }

    ; the defer statements of a subroutine body, in source order, into defer_nodes
    sub collect_defers(^^ast.Node n) {
        while n != 0 {
            if n.kind == ast.N_DEFER {
                if defer_count < MAX_DEFERS
                    defer_nodes[defer_count] = n
                defer_count++
            }
            else if n.kind != ast.N_SUB and n.kind != ast.N_ASMSUB and n.kind != ast.N_EXTSUB {
                collect_defers(n.a)
                collect_defers(n.b)
                collect_defers(n.c)
                collect_defers(n.d)
            }
            n = n.next
        }
    }

    ; the names and variables of the frame stack, when the program has a defer
    sub defer_setup() {
        program_defers = false
        defer_subs = 0
        last_defer_sub = 0
        defer_sub_count = 0
        defer_count = 0
        ^^importer.Module m = importer.modules
        while m != 0 and not program_defers {
            program_defers = any_defer(m.tree.a)
            m = m.next
        }
        if not program_defers
            return
        defer_sp_name = strtab.intern_cstr("prog8_defer.defer_sp")
        defer_guard_name = strtab.intern_cstr("prog8_defer.defer_guard")
        defer_stack_name = strtab.intern_cstr("prog8_defer.defer_handler_stack")
        defer_unwind_name = strtab.intern_cstr("prog8_defer.defer_unwind_all")
        ^^ubyte zero = 0
        if split_words
            zero = "0"          ; (block level scalars have an initial value on the 6502)
        ^^ir.Var v = ir.add_var(prog, ir.V_VAR, defer_sp_name, "ubyte", zero)
        v.zp = "NOT_IN_ZEROPAGE"
        v.noprefix = true
        v = ir.add_var(prog, ir.V_VAR, defer_guard_name, "ubyte", zero)
        v.zp = "NOT_IN_ZEROPAGE"
        v.noprefix = true
        v = ir.add_var(prog, ir.V_VAR, defer_stack_name, "ubyte[32]", 0)
        v.zp = "NOT_IN_ZEROPAGE"
        v.noprefix = true
    }

    ; the frame stack pointer as an index register
    sub defer_sp_index() -> uword {
        uword r = ir.new_reg(ir.T_BYTE)
        void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, r, defer_sp_name, 0)
        if split_words
            return r
        return convert(r, ir.T_BYTE, ir.T_WORD, false)
    }

    ; On entry of a subroutine with defers: clear the mask and push the handler's number.
    sub defer_entry(^^ast.Node n, ^^symtab.Sym ss) {
        if defer_count > MAX_DEFERS {
            error(n, "can have no more than 8 defers per subroutine")
            defer_count = 0
            return
        }
        if defer_sub_count == 255 {
            error(n, "too many subroutines with defer statements")
            defer_count = 0
            return
        }
        ^^buf.Buf db = buf.new(96)
        buf.add_str(db, sym_name(ss))
        buf.add_str(db, ".prog8_defers_mask")
        defer_mask = strtab.intern(db.data, db.len as uword)
        buf.clear(db)
        buf.add_str(db, sym_name(ss))
        buf.add_str(db, ".prog8_invoke_defers")
        defer_invoke = strtab.intern(db.data, db.len as uword)
        ^^ir.Var mv = ir.add_var(prog, ir.V_VAR, defer_mask, "ubyte", 0)
        mv.zp = "NOT_IN_ZEROPAGE"
        mv.noprefix = true
        defer_sub_count++
        ^^DeferSub ds = mem.alloc(sizeof(DeferSub))
        ds.invoke = defer_invoke
        ds.id = defer_sub_count
        if last_defer_sub == 0
            defer_subs = ds
        else
            last_defer_sub.next = ds
        last_defer_sub = ds
        void ir.emit_m(chunk, ir.OP_STOREZM, ir.T_BYTE, defer_mask, 0)
        ; a full frame stack is fatal: exit with status 1 (which runs the pending defers)
        ^^ubyte room = new_label()
        uword spr = ir.new_reg(ir.T_BYTE)
        void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, spr, defer_sp_name, 0)
        void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, spr, MAX_DEFER_FRAMES)
        void ir.emit_t(chunk, ir.OP_BSTNE, room)
        ^^ast.Node status = mem.alloc(sizeof(ast.Node))
        status.kind = ast.N_INT
        status.line = n.line
        status.col = n.col
        status.file = n.file
        status.value = 1
        status.type = types.T_UBYTE
        ubyte saved_count = defer_count
        defer_count = 0
        library_call("sys", "exit", "sys.exit", status, n)
        defer_count = saved_count
        label(room)
        uword idr = ir.new_reg(ir.T_BYTE)
        void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, idr, ds.id)
        uword ixr = defer_sp_index()
        void ir.emit_rmx(chunk, ir.OP_STOREX, ir.T_BYTE, idr, defer_stack_name, 0, ixr, 1)
        void ir.emit_m(chunk, ir.OP_INCM, ir.T_BYTE, defer_sp_name, 0)
    }

    ; a defer statement: its bit in the mask, the first one the highest
    sub defer_statement(^^ast.Node n) {
        ubyte k = 0
        while k < defer_count and defer_nodes[k] != n
            k++
        if k >= defer_count {
            unsupported(n, "defer outside a subroutine")
            return
        }
        uword r = ir.new_reg(ir.T_BYTE)
        void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, r, (1 as long) << (defer_count - 1 - k))
        void ir.emit_rm(chunk, ir.OP_ORM, ir.T_BYTE, r, defer_mask, 0)
    }

    ; Before leaving the subroutine being generated: pop its frame and run its defers.
    ; main.start then also runs what is left on the frame stack.
    sub defer_exit() {
        if defer_count == 0
            return
        void ir.emit_m(chunk, ir.OP_DECM, ir.T_BYTE, defer_sp_name, 0)
        void ir.emit_call(chunk, defer_invoke)
        ^^ubyte sname = sym_name(subsym)
        if strings.compare(sname, "main.start") == 0 or strings.compare(sname, "p8b_main.p8s_start") == 0
            void ir.emit_call(chunk, defer_unwind_name)
    }

    ; The handler routine of the subroutine just generated: the defer bodies, last first,
    ; each under a test of its bit.
    sub gen_invoke_defers(^^ast.Node n) {
        ubyte count = defer_count
        ^^ubyte mask = defer_mask
        ^^ir.Sub outer = cursub
        ^^ir.Chunk outer_chunk = chunk
        defer_count = 0             ; (nothing in the handler is an exit of the subroutine)
        cursub = ir.add_sub(block, defer_invoke, pos_text(n))
        cursub.returns = ""
        chunk = ir.add_chunk(cursub, cursub.name)
        ubyte k = count
        while k > 0 {
            k--
            ^^ubyte skip = new_label()
            uword r = ir.new_reg(ir.T_BYTE)
            void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, r, mask, 0)
            void ir.emit_ri(chunk, ir.OP_AND, ir.T_BYTE, r, (1 as long) << (count - 1 - k))
            void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, r, 0)
            void ir.emit_t(chunk, ir.OP_BSTEQ, skip)
            ^^ast.Node d = defer_nodes[k]
            statements(d.a)
            label(skip)
        }
        void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
        cursub = outer
        chunk = outer_chunk
    }

    ; prog8_defer.defer_unwind_all: runs the handlers of all active frames, top first.
    ; The guard keeps a sys.exit inside a defer from starting it again.
    sub gen_defer_block() {
        block = ir.add_block(prog, strtab.intern_cstr("prog8_defer"), "[~dummy~: line 0 col 0-0]", false)
        block.no_prefixing = true
        cursub = ir.add_sub(block, defer_unwind_name, "[~dummy~: line 0 col 0-0]")
        cursub.returns = ""
        chunk = ir.add_chunk(cursub, cursub.name)
        ^^ubyte go = new_label()
        ^^ubyte again = new_label()
        ^^ubyte done = new_label()
        uword gr = ir.new_reg(ir.T_BYTE)
        void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, gr, defer_guard_name, 0)
        void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, gr, 0)
        void ir.emit_t(chunk, ir.OP_BSTEQ, go)
        void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
        label(go)
        void ir.emit_im(chunk, ir.OP_STOREIM, ir.T_BYTE, 1, defer_guard_name, 0)
        label(again)
        uword sr = ir.new_reg(ir.T_BYTE)
        void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, sr, defer_sp_name, 0)
        void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, sr, 0)
        void ir.emit_t(chunk, ir.OP_BSTEQ, done)
        void ir.emit_m(chunk, ir.OP_DECM, ir.T_BYTE, defer_sp_name, 0)
        uword ixr = defer_sp_index()
        uword idr = ir.new_reg(ir.T_BYTE)
        void ir.emit_rmx(chunk, ir.OP_LOADX, ir.T_BYTE, idr, defer_stack_name, 0, ixr, 1)
        ^^DeferSub ds = defer_subs
        while ds != 0 {
            ^^ubyte other = new_label()
            void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, idr, ds.id)
            void ir.emit_t(chunk, ir.OP_BSTNE, other)
            void ir.emit_call(chunk, ds.invoke)
            jump(again)
            label(other)
            ds = ds.next
        }
        jump(again)
        label(done)
        void ir.emit_m(chunk, ir.OP_STOREZM, ir.T_BYTE, defer_guard_name, 0)
        void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
    }

    ; A call of a library subroutine that the compiler adds itself, built as a syntax
    ; tree node so it goes the way of any call to it on this target.
    sub library_call(str blockname, str subname, str fullname, ^^ast.Node args, ^^ast.Node at) {
        ^^symtab.Sym lib = symtab.find_in(symtab.global, strtab.intern_cstr(blockname))
        ^^symtab.Sym callee_sym = 0
        if lib != 0 and lib.inner != 0
            callee_sym = symtab.find_in(lib.inner, strtab.intern_cstr(subname))
        if callee_sym == 0 {
            unsupported(at, "a call the compiler needs to add (the library routine is missing)")
            return
        }
        ^^ast.Node callee = mem.alloc(sizeof(ast.Node))
        callee.kind = ast.N_IDENT
        callee.line = at.line
        callee.col = at.col
        callee.file = at.file
        callee.name = strtab.intern_cstr(fullname)
        callee.extra = callee_sym
        ^^ast.Node made = mem.alloc(sizeof(ast.Node))
        made.kind = ast.N_CALL
        made.line = at.line
        made.col = at.col
        made.file = at.file
        made.a = callee
        made.b = args
        library_result, library_type = call_expr(made)
    }
    uword library_result
    ubyte library_type

    sub gen_sub(^^ast.Node n) {
        ^^symtab.Sym ss = n.extra
        if ss == 0 or ss.decl != n
            return
        ^^ir.Sub saved_sub = cursub
        ^^ir.Chunk saved_chunk = chunk
        ^^symtab.Sym saved_sym = subsym
        ^^symtab.Scope saved_scope = scope
        ubyte saved_depth = loop_depth
        subsym = ss
        scope = ss.inner
        loop_depth = 0
        cursub = ir.add_sub(block, sym_name(ss), pos_text(n))
        crumb.name = cursub.name
        ^^ast.Node od = n.c
        while od != 0 {
            if od.kind == ast.N_DIRECTIVE and od.a != 0 and strings.compare(od.name, "overlay") == 0 {
                cursub.overlay = overlay_number(od)
                ir.overlay_wanted[cursub.overlay] = true
                overlay_inline = od
            }
            od = od.next
        }
        ; (on the llvm targets a subroutine uses the register numbers of the ones before
        ; it again: ir.new_reg)
        ^^uword numbers_before = ir.begin_numbers()
        ; parameters
        ^^ast.Node p = n.a
        while p != 0 {
            ^^symtab.Sym ps = p.extra
            if ps != 0
                void ir.add_param(cursub, sym_name(ps), type_string(ps.type, 0))
            p = p.next
        }
        cursub.returns = returns_text(n.b)
        chunk = ir.add_chunk(cursub, cursub.name)
        ; nested subroutines are generated as their own subroutines first
        gen_nested_subs(n.c)
        defer_count = 0
        if program_defers {
            collect_defers(n.c)
            if defer_count != 0
                defer_entry(n, ss)
        }
        zero_locals(n.c, n.c)
        statements(n.c)
        if not ends_with_return(chunk) {
            ^^ast.Node results = 0
            if subsym != 0
                results = typer.returns_of(subsym)
            if results != 0 and results.next != 0 {
                ; the end is reached without a return: every value is 0 (with one value,
                ; whatever is in its place is what upstream gives too)
                ^^ast.Node ret = mem.alloc(sizeof(ast.Node))
                mem.copy(n, ret, sizeof(ast.Node))
                ret.kind = ast.N_RETURN
                ret.next = 0
                ret.a = 0
                ret.b = 0
                ret.c = 0
                ret.d = 0
                ^^ast.Node tailv = 0
                while results != 0 {
                    ^^ast.Node zero = mem.alloc(sizeof(ast.Node))
                    mem.copy(ret, zero, sizeof(ast.Node))
                    zero.kind = ast.N_INT
                    zero.value = 0
                    zero.type = typer.return_type(results)
                    if zero.type == types.T_FLOAT {
                        zero.kind = ast.N_FLOAT
                        zero.name = "0.0"
                    }
                    if tailv == 0
                        ret.a = zero
                    else
                        tailv.next = zero
                    tailv = zero
                    results = results.next
                }
                returnstmt(ret)
            }
            else {
                defer_exit()
                void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
            }
        }
        if defer_count != 0
            gen_invoke_defers(n)
        defer_count = 0
        ir.end_numbers(numbers_before)
        cursub = saved_sub
        chunk = saved_chunk
        subsym = saved_sym
        scope = saved_scope
        loop_depth = saved_depth
    }

    sub returns_text(^^ast.Node r) -> ^^ubyte {
        buf.clear(nb)
        bool first = true
        while r != 0 {
            if not first
                buf.add_byte(nb, ',')
            first = false
            uword rt = typer.return_type(r)
            if rt == types.T_STR
                buf.add_str(nb, "pointer")
            else
                type_string_into(rt, 0)
            r = r.next
        }
        return intern_nb()
    }

    ; a parameter's type as an asmsub declaration spells it
    sub asm_type(uword t) -> ^^ubyte {
        ^^buf.Buf b = buf.new(16)
        field_type_into(b, t)
        return strtab.intern(b.data, b.len as uword)
    }

    ; "A:ubyte,Pc:bool" for return values in registers; 0 when there are none
    sub asm_returns_text(^^ast.Node r) -> ^^ubyte {
        ^^buf.Buf b = buf.new(32)
        bool any = false
        while r != 0 {
            if r.b != 0 and r.b.kind == ast.N_IDENT and r.op != token.T_KW_VOID {
                if any
                    buf.add_byte(b, ',')
                any = true
                buf.add_str(b, r.b.name)
                buf.add_byte(b, ':')
                uword rt = typer.return_type(r)
                ; (type_string_into uses nb, which is free here)
                buf.clear(nb)
                if types.is_pointer(rt) or rt == types.T_STR
                    buf.add_str(nb, "pointer")
                else
                    type_string_into(rt, 0)
                buf.add_bytes(b, nb.data, nb.len)
            }
            r = r.next
        }
        if not any
            return 0
        return strtab.intern(b.data, b.len as uword)
    }

    ; the clobbered CPU registers, in the order the declaration lists them
    sub clobber_text(^^ast.Node c) -> ^^ubyte {
        bool has_a = false
        bool has_x = false
        bool has_y = false
        buf.clear(nb)
        while c != 0 {
            if c.kind == ast.N_IDENT and c.name != 0 {
                ubyte reg = c.name[0] & $df         ; upper case
                bool seen = true
                when reg {
                    'A' -> {
                        seen = has_a
                        has_a = true
                    }
                    'X' -> {
                        seen = has_x
                        has_x = true
                    }
                    'Y' -> {
                        seen = has_y
                        has_y = true
                    }
                }
                if not seen {
                    if nb.len != 0
                        buf.add_byte(nb, ',')
                    buf.add_byte(nb, reg)
                }
            }
            c = c.next
        }
        return intern_nb()
    }

    sub gen_nested_subs(^^ast.Node s) {
        while s != 0 {
            if s.kind == ast.N_SUB {
                ^^ir.Sub outer = cursub
                ^^ir.Chunk outer_chunk = chunk
                gen_sub(s)
                cursub = outer
                chunk = outer_chunk
            }
            else if s.kind == ast.N_ASMSUB or s.kind == ast.N_EXTSUB
                gen_asmsub(s)
            s = s.next
        }
    }

    sub gen_asmsub(^^ast.Node n) {
        ^^symtab.Sym ss = n.extra
        if ss == 0 or ss.decl != n
            return
        if n.kind == ast.N_EXTSUB and n.c != 0 {
            ; a routine at a fixed address is called by that address; assembly
            ; code refers to it by name, which is defined as a constant
            bool aok
            quad acv
            aok, acv = typer.const_eval(n.c)
            if aok and (split_words or (prefixing and types.POINTER_SIZE == 4)) {
                ^^buf.Buf eb = buf.new(64)
                buf.add_str(eb, sym_name(ss))
                buf.add_str(eb, " = ")
                if acv < 0
                    buf.add_long(eb, acv as long)       ; an offset into a 68000 library's jump table
                else {
                    ^^ubyte atext = number_text(acv)
                    buf.add_str(eb, atext)
                }
                if not split_words and n.d != 0 {
                    ; (upstream notes a constant bank; the 68000 code generator reads it)
                    bool bok
                    quad bcv
                    bok, bcv = typer.const_eval(n.d)
                    if bok {
                        buf.add_str(eb, " ; @bank ")
                        buf.add_long(eb, bcv as long)
                    }
                }
                ^^ir.Chunk ec = ir.add_block_chunk(block, 0)
                ec.kind = ir.C_ASM
                ec.text = strtab.intern(eb.data, eb.len as uword)
                ec.textlen = eb.len
                ec.is_ir = false
            }
            return
        }
        ^^ir.Sub s = ir.add_sub(block, sym_name(ss), pos_text(n))
        s.is_asm = true
        s.is_external = n.kind == ast.N_EXTSUB
        s.is_inline = (n.flags & ast.F_INLINE) != 0
        ^^ast.Node p = n.a
        while p != 0 {
            ^^symtab.Sym ps = p.extra
            if ps != 0 {
                ^^ir.Param ip = ir.add_param(s, sym_name(ps), type_string(ps.type, 0))
                if p.b != 0 {
                    ip.reg = p.b.name
                    ip.asmtype = asm_type(ps.type)
                }
            }
            p = p.next
        }
        s.returns = returns_text(n.b)
        s.asmreturns = asm_returns_text(n.b)
        ^^ast.Node clob = n.d
        if n.kind == ast.N_EXTSUB {
            clob = 0
            if n.b != 0
                clob = n.b.d
        }
        if clob != 0 {
            s.clobbers_declared = true
            s.clobbered = clobber_text(clob)
        }
        if n.kind == ast.N_ASMSUB {
            ^^ast.Node body = n.c
            ^^buf.Buf whole = 0
            while body != 0 {
                ^^ubyte piece = 0
                long piecelen = 0
                if body.kind == ast.N_ASM {
                    piece = body.extra
                    piecelen = body.value as long
                    s.asm_is_ir = body.name == n_ir
                }
                else if included(body) {
                    piece = included_text
                    piecelen = included_len
                }
                if piece != 0 {
                    if s.asmtext == 0 {
                        s.asmtext = piece
                        s.asmlen = piecelen
                    }
                    else {
                        ; more than one piece: one after the other
                        if whole == 0 {
                            whole = buf.new(s.asmlen + piecelen + 64)
                            buf.add_bytes(whole, s.asmtext, s.asmlen)
                        }
                        buf.add_byte(whole, '\n')
                        buf.add_bytes(whole, piece, piecelen)
                        s.asmtext = whole.data
                        s.asmlen = whole.len
                    }
                }
                body = body.next
            }
        }
    }

    sub ends_with_return(^^ir.Chunk c) -> bool {
        if c.last == 0
            return false
        return c.last.op == ir.OP_RETURN or c.last.op == ir.OP_RETURNR or c.last.op == ir.OP_RETURNI or c.last.op == ir.OP_JUMP
    }

    ; starts a new chunk with a label
    sub label(^^ubyte name) {
        chunk = ir.add_chunk(cursub, name)
    }

    sub jump(^^ubyte target) {
        void ir.emit_t(chunk, ir.OP_JUMP, target)
    }

    ; ---- statements ----

    sub statements(^^ast.Node s) {
        while s != 0 {
            statement(s)
            s = s.next
        }
    }

    sub statement(^^ast.Node n) {
        when n.kind {
            ast.N_VARDECL -> vardecl(n)
            ast.N_ASSIGN -> assignment(n)
            ast.N_AUGASSIGN -> augassign(n)
            ast.N_INCDEC -> incdec(n)
            ast.N_CALLSTMT -> {
                uword r
                ubyte t
                ^^symtab.Sym callee = 0
                if n.a.kind == ast.N_CALL and n.a.a != 0
                    callee = n.a.a.extra
                if callee != 0 and callee.kind == symtab.K_SUB and uses_registers(callee.decl)
                    void asm_call(n.a, 0)       ; a statement: no result register is listed
                else
                    r, t = expression(n.a)
            }
            ast.N_IF -> ifstmt(n)
            ast.N_WHILE -> whilestmt(n)
            ast.N_UNTIL -> untilstmt(n)
            ast.N_REPEAT -> repeatstmt(n)
            ast.N_FOR -> forstmt(n)
            ast.N_WHEN -> whenstmt(n)
            ast.N_RETURN -> returnstmt(n)
            ast.N_BREAK -> {
                if loop_depth == 0
                    error(n, "break outside a loop")
                else
                    jump(break_labels[loop_depth - 1])
            }
            ast.N_CONTINUE -> {
                if loop_depth == 0
                    error(n, "continue outside a loop")
                else
                    jump(continue_labels[loop_depth - 1])
            }
            ast.N_GOTO -> gotostmt(n)
            ast.N_LABEL -> {
                ^^symtab.Sym ls = n.extra
                if ls != 0
                    label(sym_name(ls))
            }
            ast.N_ASM -> {
                ^^ir.Chunk ac = ir.add_asm_chunk(cursub, 0, n.extra, n.value as long, n.name == n_ir)
                chunk = ir.add_chunk(cursub, 0)
            }
            ast.N_DIRECTIVE -> {
                if strings.compare(n.name, "breakpoint") == 0
                    void ir.emit(chunk, ir.OP_BREAKPOINT, ir.T_NONE, ir.M_NONE)
                else if included(n) {
                    void ir.add_asm_chunk(cursub, 0, included_text, included_len, false)
                    chunk = ir.add_chunk(cursub, 0)
                }
            }
            ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB, ast.N_STRUCT, ast.N_UNION, ast.N_ENUM, ast.N_ALIAS -> {
            }
            ast.N_BRANCH -> branchstmt(n)
            ast.N_UNROLL -> unrollstmt(n)
            ast.N_SWAP -> swapstmt(n)
            ast.N_DEFER -> defer_statement(n)
            ast.N_ONGOTO -> ongoto(n)
            else -> unsupported(n, "statement")
        }
    }

    ; ---- is a variable's zero ever seen? ----
    ;
    ; A local without an initial value starts at zero on every call.  That store is
    ; not needed when, in the statements that follow the declaration, the variable is
    ; assigned before anything mentions it.  Anything that could look at it another
    ; way stops the search: a label, assembly, a subroutine nested in this one that
    ; names it, the end of the statement list.

    ; does this node, or anything below it, name the variable?  (Not its siblings.)
    sub mentions(^^ast.Node n, ^^symtab.Sym s) -> bool {
        if n == 0
            return false
        if n.kind == ast.N_IDENT and n.extra == s
            return true
        if n.kind == ast.N_ASM
            return true             ; (assembly may)
        return mentions_list(n.a, s) or mentions_list(n.b, s) or mentions_list(n.c, s) or mentions_list(n.d, s)
    }

    sub mentions_list(^^ast.Node n, ^^symtab.Sym s) -> bool {
        while n != 0 {
            if mentions(n, s)
                return true
            n = n.next
        }
        return false
    }

    sub assigned_first(^^ast.Node decl, ^^symtab.Sym s) -> bool {
        ; a subroutine nested in this one can use the variable whenever it is called
        if scope.owner != 0 and scope.owner.kind == ast.N_SUB {
            ^^ast.Node inner = scope.owner.c
            while inner != 0 {
                if (inner.kind == ast.N_SUB or inner.kind == ast.N_ASMSUB) and mentions(inner, s)
                    return false
                inner = inner.next
            }
        }
        else
            return false
        ^^ast.Node st = decl.next
        while st != 0 {
            when st.kind {
                ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB, ast.N_STRUCT, ast.N_UNION, ast.N_ENUM, ast.N_ALIAS, ast.N_REMOVED -> {
                }
                ast.N_LABEL, ast.N_ASM -> return false
                ast.N_ASSIGN -> {
                    ; one of the targets (a, b = f() assigns them all), as the name itself
                    ^^ast.Node target = st.a
                    while target != 0 {
                        if target.kind == ast.N_IDENT and target.extra == s {
                            ; (a = b = ... chains have an ASSIGN as the value: it is searched too)
                            if mentions(st.b, s)
                                return false
                            ; the other targets must not use it either (as an index, say)
                            ^^ast.Node other = st.a
                            while other != 0 {
                                if other != target and mentions(other, s)
                                    return false
                                other = other.next
                            }
                            return true
                        }
                        target = target.next
                    }
                    if mentions(st, s)
                        return false
                }
                ast.N_FOR -> {
                    ; a loop gives its variable the first value before anything else
                    if st.a != 0 and st.a.kind == ast.N_IDENT and st.a.extra == s
                        return not mentions_list(st.b, s) and not mentions_list(st.d, s)
                    if mentions(st, s)
                        return false
                }
                ast.N_RETURN -> {
                    ; the subroutine ends here: the variable is not seen on this way
                    return not mentions(st, s)
                }
                else -> {
                    if mentions(st, s)
                        return false
                }
            }
            st = st.next
        }
        return false
    }

    ; A subroutine's scalars without an initial value are zero when the subroutine is
    ; entered, unless @dirty: on every call, and only then.  (Not where they are
    ; declared: one declared in a loop keeps its value from round to round, and one
    ; whose declaration is passed by is zero all the same.  It is what upstream does.)
    sub zero_locals(^^ast.Node list, ^^ast.Node body) {
        while list != 0 {
            if list.kind != ast.N_SUB and list.kind != ast.N_ASMSUB and list.kind != ast.N_EXTSUB {
                if list.kind == ast.N_VARDECL and list.b == 0
                    zero_declared(list, body)
                else {
                    zero_locals(list.a, body)
                    zero_locals(list.b, body)
                    zero_locals(list.c, body)
                    zero_locals(list.d, body)
                }
            }
            list = list.next
        }
    }

    sub zero_declared(^^ast.Node n, ^^ast.Node body) {
        ^^ast.Node tag = n.d
        while tag != 0 {
            if tag.kind == ast.N_TAG and strings.compare(tag.name, "dirty") == 0
                return
            tag = tag.next
        }
        ^^ast.Node zid = n.c
        while zid != 0 {
            ^^symtab.Sym zs = zid.extra
            if zs != 0 and zs.type != 0 and zs.kind == symtab.K_VAR {
                ^^types.Type zt = types.get(zs.type)
                if zt.base != types.T_ARRAY and zt.base != types.T_STR and zt.base != types.T_STRUCT {
                    ; Not when nothing can see the zero: every mention of the variable comes
                    ; after its declaration, in the same list of statements, and the first
                    ; of them assigns it.
                    bool unseen = assigned_first(n, zs) and count_list(body, zs) == count_list(n.next, zs) + 1
                    if not unseen
                        void ir.emit_m(chunk, ir.OP_STOREZM, irt(zs.type), sym_name(zs), 0)
                }
            }
            zid = zid.next
        }
    }

    ; how often a list of nodes, and everything below them, names the variable
    ; (assembly counts as once: it may)
    sub count_list(^^ast.Node n, ^^symtab.Sym s) -> long {
        long total = 0
        while n != 0 {
            if n.kind == ast.N_IDENT and n.extra == s
                total++
            else if n.kind == ast.N_ASM
                total++
            total += count_list(n.a, s)
            total += count_list(n.b, s)
            total += count_list(n.c, s)
            total += count_list(n.d, s)
            n = n.next
        }
        return total
    }

    sub vardecl(^^ast.Node n) {
        if n.b == 0
            return          ; no initializer: its zero was stored when the subroutine was entered (zero_locals)
        ^^symtab.Sym s = n.c.extra
        if s == 0 or s.type == 0
            return
        if s.kind != symtab.K_VAR
            return          ; a constant or a memory-mapped variable: its value is not stored anywhere
        ^^types.Type t = types.get(s.type)
        if t.base == types.T_ARRAY or t.base == types.T_STR
            return          ; initialized data
        if n.b.kind == ast.N_TUPLE {
            ^^ast.Node id = n.c
            ^^ast.Node v = n.b.a
            while id != 0 and v != 0 {
                store_to_ident(id, v)
                id = id.next
                v = v.next
            }
            return
        }
        bool several = false
        if n.c.next != 0 and n.b.kind == ast.N_CALL and n.b.a != 0 and n.b.a.extra != 0 {
            ; (a call that gives several values has one for each name)
            ^^symtab.Sym callee = n.b.a.extra
            if callee.kind == symtab.K_BUILTIN
                several = strings.compare(callee.name, "divmod") == 0 or strings.compare(callee.name, "lmh") == 0
            else {
                ^^ast.Node crt = typer.returns_of(callee)
                several = crt != 0 and crt.next != 0
            }
        }
        if several {
            ; uword q, r = divmod(a, b): the names are the targets
            ^^ast.Node id2 = n.c
            while id2 != 0 {
                ^^symtab.Sym ids = id2.extra
                if ids != 0
                    id2.type = ids.type
                id2 = id2.next
            }
            multi_call_assign(n.c, n.b)
            return
        }
        if scope.kind != symtab.S_SUB
            return          ; block variables are initialized data
        if n.c.next != 0 {
            ; ubyte a, b, c = value: worked out once, and every name gets it
            uword vr
            ubyte vt
            vr, vt = expression(n.b)
            ^^ast.Node each = n.c
            while each != 0 {
                ^^symtab.Sym es = each.extra
                if es != 0 {
                    each.type = es.type
                    store(each, vr, vt, types.is_signed(n.b.type))
                }
                each = each.next
            }
            return
        }
        store_to_ident(n.c, n.b)
    }

    ; stores the value of an expression into the variable of an identifier node
    sub store_to_ident(^^ast.Node id, ^^ast.Node value) {
        ^^symtab.Sym s = id.extra
        if s == 0
            return
        untyped_struct_init(s.type, value)
        uword r
        ubyte vt
        ubyte tt = irt(s.type)
        bool ok
        quad cv
        ok, cv = typer.const_eval(value)
        ^^ubyte vs
        long va
        vs, va = var_ref(s)
        if tt == ir.T_FLOAT {
            if typer.float_eval(value) {
                void ir.emit_fm(chunk, ir.OP_STOREIM, typer.float_value, vs, va)
                return
            }
        }
        if ok and tt != ir.T_FLOAT {
            if cv == 0
                void ir.emit_m(chunk, ir.OP_STOREZM, tt, vs, va)
            else
                void ir.emit_im(chunk, ir.OP_STOREIM, tt, truncate(cv, tt), vs, va)
            return
        }
        r, vt = expression(value)
        r = convert(r, vt, tt, types.is_signed(value.type))
        void ir.emit_rm(chunk, ir.OP_STOREM, tt, r, vs, va)
    }

    sub truncate(quad v, ubyte t) -> quad {
        when plain(t) {
            ir.T_BYTE -> return (v & $ff) as quad
            ir.T_WORD -> return (v & $ffff) as quad
            ir.T_LONG -> return (v & $ffffffff) as quad
        }
        return v
    }

    ; ---- assignment ----

    sub assignment(^^ast.Node n) {
        ^^ast.Node value = n.b
        ^^ast.Node target = n.a
        if value.kind == ast.N_ASSIGN {
            ; a = b = value: assign the innermost first, then copy
            assignment(value)
            ^^ast.Node inner = value
            while inner.kind == ast.N_ASSIGN
                inner = inner.b
            assign_expr(target, inner)
            return
        }
        if target.next == 0 {
            if target.kind == ast.N_VOID {
                uword r0
                ubyte t0
                r0, t0 = expression(value)
                return
            }
            if spine_update(target, value)
                return
            assign_expr(target, value)
            return
        }
        ; multiple targets
        if value.kind == ast.N_TUPLE {
            ^^ast.Node v = value.a
            while target != 0 and v != 0 {
                if target.kind != ast.N_VOID
                    assign_expr(target, v)
                target = target.next
                v = v.next
            }
            return
        }
        if value.kind == ast.N_CALL {
            multi_call_assign(target, value)
            return
        }
        unsupported(n, "multi-assignment value")
    }

    ; x, y = sub(...): the call leaves its values in the hardware slots s10, s11, ...
    sub multi_call_assign(^^ast.Node target, ^^ast.Node callnode) {
        ^^symtab.Sym cs = callnode.a.extra
        if cs == 0
            return
        if cs.kind == symtab.K_BUILTIN {
            if strings.compare(cs.name, "divmod") == 0 {
                ; quotient and remainder in two registers
                ^^ast.Node da = callnode.b
                uword dr
                ubyte dt
                dr, dt = expression(da)
                uword rem
                ubyte remt
                rem, remt = expression(da.next)
                rem = convert(rem, remt, dt, false)
                void ir.emit_rr(chunk, ir.OP_DIVMODR, dt, dr, rem)
                if target.kind != ast.N_VOID
                    store(target, dr, dt, false)
                if target.next != 0 and target.next.kind != ast.N_VOID
                    store(target.next, rem, dt, false)
                return
            }
            if strings.compare(cs.name, "lmh") == 0 {
                ; the low, the middle and the high byte of a long
                uword lv
                ubyte lvt
                lv, lvt = expression(callnode.b)
                lv = convert(lv, lvt, ir.T_LONG, types.is_signed(callnode.b.type))
                ubyte part = 0
                while target != 0 and part < 3 {
                    if target.kind != ast.N_VOID {
                        uword shifted = ir.new_reg(ir.T_LONG)
                        void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_LONG, shifted, lv)
                        if part != 0
                            void ir.emit_ri(chunk, ir.OP_LSRI, ir.T_LONG, shifted, part * 8)
                        store(target, convert(shifted, ir.T_LONG, ir.T_BYTE, false), ir.T_BYTE, false)
                    }
                    target = target.next
                    part++
                }
                return
            }
            unsupported(callnode, "builtin with several results")
            return
        }
        if uses_registers(cs.decl) {
            ; the results come back in the registers the declaration names
            void asm_call(callnode, 2)
            ^^ir.Arg ares = last_asm_call.results
            ^^ast.Node art = typer.returns_of(cs)
            fetch_asm_results(ares, art)
            while target != 0 and ares != 0 {
                if target.kind != ast.N_VOID {
                    store(target, ares.reg, ares.type, false)
                }
                target = target.next
                ares = ares.next
                if art != 0
                    art = art.next
            }
            return
        }
        void call_sub(callnode, false)
        ^^ast.Node rt = typer.returns_of(cs)
        if split_words {
            ; the 6502: the values are in A or AY and the virtual registers
            void place_returns(rt)
            ubyte pi = 0
            while target != 0 and rt != 0 {
                uword ptype = typer.return_type(rt)
                if target.kind != ast.N_VOID {
                    uword pr = load_place(pi, irt(ptype))
                    store(target, pr, irt(ptype), types.is_signed(ptype))
                }
                pi++
                target = target.next
                rt = rt.next
            }
            return
        }
        void return_slots(rt)
        ubyte slot = 0
        while target != 0 and rt != 0 and slot < len(return_slot) {
            uword rtype = typer.return_type(rt)
            ubyte t = irt(rtype)
            if target.kind != ast.N_VOID {
                uword r = ir.new_reg(t)
                void ir.emit_rs(chunk, ir.OP_LOADHR, t, r, return_slot[slot])
                store(target, r, t, types.is_signed(rtype))
            }
            slot++
            target = target.next
            rt = rt.next
        }
    }

    sub assign_expr(^^ast.Node target, ^^ast.Node value) {
        uword r
        ubyte vt
        bool ok
        quad cv
        uword tt_p8 = target.type
        if is_struct(tt_p8) {
            struct_copy(target, value)
            return
        }
        untyped_struct_init(tt_p8, value)
        ubyte tt = irt(tt_p8)
        bool fok
        if target.kind == ast.N_IDENT and target.op != resolver.R_FIELDREF and tt == ir.T_FLOAT {
            fok = typer.float_eval(value)
            ^^symtab.Sym fs = target.extra
            if fok and fs != 0 and (fs.kind == symtab.K_VAR or fs.kind == symtab.K_PARAM or fs.kind == symtab.K_MEMVAR) {
                ^^ubyte fvs
                long fva
                fvs, fva = var_ref(fs)
                void ir.emit_fm(chunk, ir.OP_STOREIM, typer.float_value, fvs, fva)
                return
            }
        }
        ; a constant into a plain variable: store it directly
        if target.kind == ast.N_IDENT and target.op != resolver.R_FIELDREF and tt != ir.T_FLOAT {
            ok, cv = typer.const_eval(value)
            if ok {
                ^^symtab.Sym s = target.extra
                if s != 0 and (s.kind == symtab.K_VAR or s.kind == symtab.K_PARAM or s.kind == symtab.K_MEMVAR) {
                    ^^ubyte vs
                    long va
                    vs, va = var_ref(s)
                    if cv == 0
                        void ir.emit_m(chunk, ir.OP_STOREZM, tt, vs, va)
                    else
                        void ir.emit_im(chunk, ir.OP_STOREIM, tt, truncate(cv, tt), vs, va)
                    return
                }
            }
        }
        r, vt = expression(value)
        store(target, r, vt, types.is_signed(value.type))
    }

    ; Stores register r (of IR type vt) into the target expression.
    sub store(^^ast.Node target, uword r, ubyte vt, bool signed) {
        uword tt_p8 = target.type
        ubyte tt = irt(tt_p8)
        if tt_p8 == 0
            tt = vt
        r = convert(r, vt, tt, signed)
        when target.kind {
            ast.N_IDENT -> {
                if target.op == resolver.R_FIELDREF {
                    uword pr
                    long off
                    pr, off = field_address(target)
                    void ir.emit_rp(chunk, ir.OP_STOREI, tt, r, pr, off)
                    return
                }
                ^^symtab.Sym s = target.extra
                if s == 0
                    return
                ^^ubyte vs2
                long va2
                vs2, va2 = var_ref(s)
                void ir.emit_rm(chunk, ir.OP_STOREM, tt, r, vs2, va2)
            }
            ast.N_INDEX -> store_indexed(target, r, tt)
            ast.N_DEREF -> {
                uword pr2
                ubyte pt2
                pr2, pt2 = expression(target.a)
                void ir.emit_rp(chunk, ir.OP_STOREI, tt, r, pr2, 0)
            }
            ast.N_FIELD -> {
                uword pr3
                ubyte pt3
                pr3, pt3 = expression(target.a)
                ^^symtab.Sym f = target.extra
                if f == 0
                    return
                void ir.emit_rp(chunk, ir.OP_STOREI, tt, r, pr3, field_offset(f))
            }
            ast.N_MEMREAD -> {
                bool ok
                quad addr
                ok, addr = typer.const_eval(target.a)
                if ok {
                    void ir.emit_rm(chunk, ir.OP_STOREM, ir.T_BYTE, r, 0, addr as long)
                    return
                }
                if target == once_node {
                    void ir.emit_rp(chunk, ir.OP_STOREI, ir.T_BYTE, r, once_reg, 0)
                    return
                }
                uword ar
                ubyte at
                ar, at = expression(target.a)
                ar = convert(ar, at, address_type(target.a), false)
                void ir.emit_rp(chunk, ir.OP_STOREI, ir.T_BYTE, r, ar, 0)
            }
            else -> unsupported(target, "assignment target")
        }
    }

    ; array[index] = r
    sub store_indexed(^^ast.Node target, uword r, ubyte tt) {
        ^^ast.Node base = target.a
        ^^ast.Node index = target.b
        if index == 0 or index.next != 0 {
            unsupported(target, "2D array indexing")
            return
        }
        long elemsize = types.size_of(target.type)
        if elemsize == 0
            elemsize = 1
        ^^symtab.Sym s = 0
        if base.kind == ast.N_IDENT and base.op != resolver.R_FIELDREF
            s = base.extra
        bool ok
        quad ci
        if is_split(s) {
            split_store(s, index, convert(r, tt, ir.T_WORD, false))
            return
        }
        if s != 0 and (s.kind == symtab.K_VAR or s.kind == symtab.K_MEMVAR or s.kind == symtab.K_PARAM) and (types.is_array(s.type) or s.type == types.T_STR) {
            ; a real array: indexed addressing
            ^^ubyte vs
            long va
            vs, va = var_ref(s)
            ok, ci = typer.const_eval(index)
            if ok {
                void ir.emit_rm(chunk, ir.OP_STOREM, tt, r, vs, va + (ci as long) * elemsize)
                return
            }
            uword ixr = index_register(index)
            void ir.emit_rmx(chunk, ir.OP_STOREX, tt, r, vs, va, ixr, elemsize as ubyte)
            return
        }
        ; a pointer (or address) with an index: compute the address
        uword pr
        long off
        pr, off = indexed_address(base, index, elemsize)
        void ir.emit_rp(chunk, ir.OP_STOREI, tt, r, pr, off)
    }

    ; the index of an array element as a word register
    sub index_register(^^ast.Node index) -> uword {
        uword r
        ubyte t
        r, t = expression(index)
        if split_words and t == ir.T_BYTE
            return r            ; the 6502 indexes with a byte register
        return convert(r, t, ir.T_WORD, false)
    }

    ; is the value of this expression an address in far memory: a long, on a machine that
    ; has such memory?  (Then the register that holds it stays a long, and the code
    ; generator goes through it with its far pointer.)
    sub far_address(^^ast.Node e) -> bool {
        return types.far_bits != 0 and e != 0 and e.type == types.T_LONG
    }

    sub address_type(^^ast.Node e) -> ubyte {
        if far_address(e)
            return ir.T_LONG
        return ir.T_POINTER
    }

    ; The address register and displacement for base[index] where base is a
    ; pointer or address value (not an array variable).
    sub indexed_address(^^ast.Node base, ^^ast.Node index, long elemsize) -> uword, long {
        uword pr
        ubyte pt
        long first = 0
        if base.kind == ast.N_IDENT and base.op == resolver.R_FIELDREF and types.is_array(base.type) {
            ; a field that is an array: its elements are in the struct, from the field's place on
            pr, first = field_address(base)
        }
        else {
            pr, pt = expression(base)
            pr = convert(pr, pt, address_type(base), false)
        }
        bool ok
        quad ci
        ok, ci = typer.const_eval(index)
        if ok
            return pr, first + (ci as long) * elemsize
        uword ixr
        ubyte ixt
        ixr, ixt = expression(index)
        if far_address(base) {
            ; a long that is an address in far memory: the sum is a long too
            ixr = convert(ixr, ixt, ir.T_LONG, types.is_signed(index.type))
            if elemsize != 1
                void ir.emit_ri(chunk, ir.OP_MUL, ir.T_LONG, ixr, elemsize)
            uword farsum = ir.new_reg(ir.T_LONG)
            void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_LONG, farsum, pr)
            void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_LONG, farsum, ixr)
            return farsum, first
        }
        ixr = convert(ixr, ixt, ir.T_POINTER, types.is_signed(index.type))
        if elemsize != 1
            void ir.emit_ri(chunk, scale_op(), address_irt, ixr, elemsize)
        uword sum = ir.new_reg(ir.T_POINTER)
        void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_POINTER, sum, pr)
        void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, sum, ixr)
        return sum, first
    }

    ; The pointer register and field displacement of a dotted field reference
    ; like p.next.value: the variable's pointer value, then each intermediate
    ; field loaded through it.
    sub field_address(^^ast.Node node) -> uword, long {
        ; split the dotted name
        ^^ubyte name = node.name
        long i = 0
        long start = 0
        uword pr = 0
        ^^symtab.Sym cur = 0            ; the variable, then the field reached so far
        uword curtype = 0
        long off = 0
        bool have_var = false
        while true {
            ubyte c = name[i]
            if c == '.' or c == 0 {
                ^^ubyte part = strtab.intern(name + start, (i - start) as uword)
                if not have_var {
                    ; the longest prefix that names a variable
                    ^^symtab.Sym s = lookup_part(cur, part)
                    if s == 0 {
                        error(node, "cannot resolve field reference")
                        return 0, 0
                    }
                    cur = s
                    if s.kind == symtab.K_VAR or s.kind == symtab.K_PARAM or s.kind == symtab.K_MEMVAR {
                        have_var = true
                        curtype = s.type
                        pr = ir.new_reg(ir.T_POINTER)
                        ^^ubyte vs
                        long va
                        vs, va = var_ref(s)
                        void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_POINTER, pr, vs, va)
                    }
                }
                else {
                    ; a field of the struct the pointer points to
                    ^^symtab.Sym st = pointee(curtype)
                    if st == 0 {
                        error(node, "field access through a non-struct pointer")
                        return 0, 0
                    }
                    ^^symtab.Sym f = symtab.find_in(st.inner, part)
                    if f == 0 {
                        error(node, "unknown field")
                        return 0, 0
                    }
                    if c == 0
                        return pr, field_offset(f)
                    ; an intermediate field: a pointer to the next struct
                    uword nr = ir.new_reg(ir.T_POINTER)
                    void ir.emit_rp(chunk, ir.OP_LOADI, ir.T_POINTER, nr, pr, field_offset(f))
                    pr = nr
                    curtype = f.type
                }
                start = i + 1
            }
            if c == 0
                break
            i++
        }
        error(node, "cannot resolve field reference")
        return 0, 0
    }

    ; the struct symbol a pointer type points at, or 0
    sub pointee(uword t) -> ^^symtab.Sym {
        if t == 0
            return 0
        ^^types.Type tt = types.get(t)
        if tt.base == types.T_POINTER {
            ^^types.Type et = types.get(tt.elem)
            if et.base == types.T_STRUCT
                return et.strct
        }
        return 0
    }

    ; a name part: unqualified in the current scopes when cur is 0, else inside cur
    sub lookup_part(^^symtab.Sym cur, ^^ubyte part) -> ^^symtab.Sym {
        if cur != 0 {
            if cur.inner == 0
                return 0
            return symtab.find_in(cur.inner, part)
        }
        ^^symtab.Scope sc = scope
        while sc != 0 {
            ^^symtab.Sym s = symtab.find_in(sc, part)
            if s != 0
                return s
            sc = sc.parent
        }
        return 0
    }

    ; x += value (and -=, &=, |=, ^=) on a plain byte or word variable: one instruction
    ; that works on the variable in memory.  False when the statement is not of this kind.
    ; v = ((v op a) op b) ...: the variable updated where it is, one operation after the
    ; other, as v op= a; v op= b would be.  Only when every operation has an in-memory
    ; form and no operand names the variable.
    sub spine_update(^^ast.Node target, ^^ast.Node value) -> bool {
        if target.kind != ast.N_IDENT or target.op == resolver.R_FIELDREF or target.extra == 0
            return false
        ^^symtab.Sym s = target.extra
        if (s.kind != symtab.K_VAR and s.kind != symtab.K_PARAM) or is_split(s) or types.is_pointer(s.type)
            return false
        ubyte t = irt(s.type)
        if t != ir.T_BYTE and t != ir.T_WORD
            return false
        ^^ast.Node[8] spine
        ubyte depth = 0
        ^^ast.Node e = value
        bool ok
        quad cv
        while e.kind == ast.N_BINARY {
            if depth == 8 or e.type != s.type
                return false
            when e.op {
                token.T_PLUS, token.T_MINUS, token.T_AMP, token.T_PIPE, token.T_CARET -> {
                }
                token.T_SHL, token.T_SHR -> {
                    ok, cv = typer.const_eval(e.b)
                    if not ok or cv != 1
                        return false
                }
                else -> return false
            }
            if mentions(e.b, s)
                return false
            spine[depth] = e
            depth++
            e = e.a
        }
        if depth == 0 or e.kind != ast.N_IDENT or e.extra != s or e.op == resolver.R_FIELDREF
            return false
        while depth > 0 {
            depth--
            ^^ast.Node step = mem.alloc(sizeof(ast.Node))
            mem.copy(spine[depth], step, sizeof(ast.Node))
            step.next = 0
            step.a = target
            if not memory_update(step) {
                unsupported(value, "an update in place")
                return true
            }
        }
        return true
    }

    sub memory_update(^^ast.Node n) -> bool {
        ^^ast.Node target = n.a
        if target.kind != ast.N_IDENT or target.op == resolver.R_FIELDREF or target.extra == 0
            return false
        ^^symtab.Sym s = target.extra
        if (s.kind != symtab.K_VAR and s.kind != symtab.K_PARAM) or is_split(s) or types.is_pointer(s.type)
            return false
        ubyte t = irt(s.type)
        if t != ir.T_BYTE and t != ir.T_WORD
            return false
        ubyte op = augop(n.op)
        ubyte mop
        if op == token.T_SHL or op == token.T_SHR {
            ; a single shift where the variable is
            bool sok
            quad sv
            sok, sv = typer.const_eval(n.b)
            if not sok or sv != 1
                return false
            if op == token.T_SHL
                void ir.emit_m(chunk, ir.OP_LSLM, t, sym_name(s), 0)
            else if types.is_signed(s.type)
                void ir.emit_m(chunk, ir.OP_ASRM, t, sym_name(s), 0)
            else
                void ir.emit_m(chunk, ir.OP_LSRM, t, sym_name(s), 0)
            return true
        }
        when op {
            token.T_PLUS -> mop = ir.OP_ADDM
            token.T_MINUS -> mop = ir.OP_SUBM
            token.T_AMP -> mop = ir.OP_ANDM
            token.T_PIPE -> mop = ir.OP_ORM
            token.T_CARET -> mop = ir.OP_XORM
            else -> return false
        }
        ^^ubyte name = sym_name(s)
        bool ok
        quad cv
        ok, cv = typer.const_eval(n.b)
        if ok and (op == token.T_PLUS or op == token.T_MINUS) {
            cv = truncate(cv, t)
            if cv == 1 {
                if op == token.T_PLUS
                    void ir.emit_m(chunk, ir.OP_INCM, t, name, 0)
                else
                    void ir.emit_m(chunk, ir.OP_DECM, t, name, 0)
            }
            else if cv != 0 {
                if op == token.T_PLUS
                    void ir.emit_im(chunk, ir.OP_ADDIM, t, cv, name, 0)
                else
                    void ir.emit_im(chunk, ir.OP_SUBIM, t, cv, name, 0)
            }
            return true
        }
        uword r
        ubyte rt
        r, rt = expression(n.b)
        r = convert(r, rt, t, types.is_signed(n.b.type))
        void ir.emit_rm(chunk, mop, t, r, name, 0)
        return true
    }

    ; The address of @(address) in an in-place operation is worked out once when it has
    ; a call in it: the target is read and written through the same register.
    ^^ast.Node once_node = 0
    uword once_reg = 0

    sub has_call(^^ast.Node e) -> bool {
        if e == 0
            return false
        if e.kind == ast.N_CALL
            return true
        return has_call(e.a) or has_call(e.b) or has_call(e.c) or has_call(e.d)
    }

    sub address_once(^^ast.Node target) {
        once_node = 0
        if target.kind != ast.N_MEMREAD or not has_call(target.a)
            return
        uword ar
        ubyte at
        ar, at = expression(target.a)
        once_reg = convert(ar, at, ir.T_POINTER, false)
        once_node = target
    }

    sub augassign(^^ast.Node n) {
        address_once(n.a)
        augassign_once(n)
        once_node = 0
    }

    sub augassign_once(^^ast.Node n) {
        if memory_update(n)
            return
        ^^ast.Node target = n.a
        uword cur
        ubyte ct
        cur, ct = expression(target)
        ubyte op = augop(n.op)
        bool signed = types.is_signed(target.type)
        bool cok
        quad ccv
        cok, ccv = typer.const_eval(n.b)
        if (op == token.T_PLUS or op == token.T_MINUS) and types.is_pointer(target.type) {
            ; a pointer moves by whole elements
            long step = types.size_of(types.elem_of(target.type))
            if step > 1 {
                if cok
                    ccv *= step
                else {
                    uword pr
                    ubyte pt
                    pr, pt = expression(n.b)
                    pr = convert(pr, pt, ir.T_POINTER, types.is_signed(n.b.type))
                    void ir.emit_ri(chunk, scale_op(), address_irt, pr, step)
                    if op == token.T_PLUS
                        void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, cur, pr)
                    else
                        void ir.emit_rr(chunk, ir.OP_SUBR, ir.T_POINTER, cur, pr)
                    store(target, cur, ct, signed)
                    return
                }
            }
        }
        if cok and ct != ir.T_FLOAT and immediate_apply(op, cur, ct, ccv, signed) {
            store(target, cur, ct, signed)
            return
        }
        uword r
        ubyte rt
        r, rt = expression(n.b)
        if op == token.T_SHL or op == token.T_SHR
            r = convert(r, rt, ir.T_BYTE, false)
        else
            r = convert(r, rt, ct, types.is_signed(n.b.type))
        uword result = binary_op(op, cur, ct, r, rt, ct, signed, n)
        store(target, result, ct, signed)
    }

    sub augop(ubyte op) -> ubyte {
        when op {
            token.T_PLUSEQ -> return token.T_PLUS
            token.T_MINUSEQ -> return token.T_MINUS
            token.T_STAREQ -> return token.T_STAR
            token.T_SLASHEQ -> return token.T_SLASH
            token.T_PERCENTEQ -> return token.T_PERCENT
            token.T_AMPEQ -> return token.T_AMP
            token.T_PIPEEQ -> return token.T_PIPE
            token.T_CARETEQ -> return token.T_CARET
            token.T_SHLEQ -> return token.T_SHL
            token.T_SHREQ -> return token.T_SHR
        }
        return op
    }

    sub incdec(^^ast.Node n) {
        ^^ast.Node target = n.a
        ubyte tt = irt(target.type)
        if target.kind == ast.N_IDENT and target.op != resolver.R_FIELDREF {
            ^^symtab.Sym s = target.extra
            if s != 0 and types.is_pointer(s.type) {
                long esize = types.size_of(types.elem_of(s.type))
                if esize > 1 {
                    uword pr = ir.new_reg(ir.T_POINTER)
                    void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_POINTER, pr, sym_name(s), 0)
                    if n.op == token.T_PLUSPLUS
                        void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, pr, esize)
                    else
                        void ir.emit_ri(chunk, ir.OP_SUB, ir.T_POINTER, pr, esize)
                    void ir.emit_rm(chunk, ir.OP_STOREM, ir.T_POINTER, pr, sym_name(s), 0)
                    return
                }
            }
            if s != 0 {
                ^^ubyte vs
                long va
                vs, va = var_ref(s)
                if n.op == token.T_PLUSPLUS
                    void ir.emit_m(chunk, ir.OP_INCM, tt, vs, va)
                else
                    void ir.emit_m(chunk, ir.OP_DECM, tt, vs, va)
                return
            }
        }
        address_once(target)
        uword r
        ubyte t
        r, t = expression(target)
        if n.op == token.T_PLUSPLUS
            void ir.emit_r(chunk, ir.OP_INC, t, r)
        else
            void ir.emit_r(chunk, ir.OP_DEC, t, r)
        store(target, r, t, false)
        once_node = 0
    }

    sub swapstmt(^^ast.Node n) {
        uword r1
        ubyte t1
        uword r2
        ubyte t2
        r1, t1 = expression(n.a)
        r2, t2 = expression(n.b)
        store(n.a, r2, t2, false)
        store(n.b, r1, t1, false)
    }

    ; ---- control flow ----

    ; Branches on a condition: to the true label, the false label, or both
    ; (0 means fall through).
    sub condition(^^ast.Node e, ^^ubyte on_true, ^^ubyte on_false) {
        range_test(e)
        ; a constant (a feature switch): no test, and in and/or only the other operand
        bool known
        quad truth
        known, truth = typer.const_eval(e)
        if known {
            if truth != 0 {
                if on_true != 0
                    jump(on_true)
            }
            else if on_false != 0
                jump(on_false)
            return
        }
        if e.kind == ast.N_BINARY and (e.op == token.T_KW_OR or e.op == token.T_KW_AND) {
            known, truth = typer.const_eval(e.a)
            if known {
                ; (it does not decide, or the whole would be a constant)
                condition(e.b, on_true, on_false)
                return
            }
        }
        if e.kind == ast.N_BINARY {
            if e.op == token.T_KW_OR {
                ^^ubyte body = on_true
                if body == 0
                    body = new_label()
                condition(e.a, body, 0)
                condition(e.b, on_true, on_false)
                if on_true == 0
                    label(body)
                return
            }
            if e.op == token.T_KW_AND {
                ^^ubyte skip = on_false
                if skip == 0
                    skip = new_label()
                condition(e.a, 0, skip)
                condition(e.b, on_true, on_false)
                if on_false == 0
                    label(skip)
                return
            }
            if is_comparison(e.op) {
                compare_branch(e, on_true, on_false)
                return
            }
        }
        if e.kind == ast.N_UNARY and e.op == token.T_KW_NOT {
            condition(e.a, on_false, on_true)
            return
        }
        uword r
        ubyte t
        r, t = expression(e)
        void ir.emit_ri(chunk, ir.OP_CMPI, t, r, 0)
        if on_true != 0 and on_false != 0 {
            void ir.emit_t(chunk, ir.OP_BSTNE, on_true)
            jump(on_false)
        }
        else if on_true != 0
            void ir.emit_t(chunk, ir.OP_BSTNE, on_true)
        else if on_false != 0
            void ir.emit_t(chunk, ir.OP_BSTEQ, on_false)
    }

    sub is_comparison(ubyte op) -> bool {
        return op == token.T_EQ or op == token.T_NE or op == token.T_LT or op == token.T_GT or op == token.T_LE or op == token.T_GE
    }

    sub invert_op(ubyte op) -> ubyte {
        when op {
            token.T_EQ -> return token.T_NE
            token.T_NE -> return token.T_EQ
            token.T_LT -> return token.T_GE
            token.T_GT -> return token.T_LE
            token.T_LE -> return token.T_GT
            token.T_GE -> return token.T_LT
        }
        return op
    }

    ; the common type of a comparison's operands
    sub compare_type(^^ast.Node e) -> ubyte, bool {
        uword lt = e.a.type
        uword rt = e.b.type
        if lt == types.T_FLOAT or rt == types.T_FLOAT
            return ir.T_FLOAT, true
        if lt == types.T_STR and rt == types.T_STR
            return ir.T_POINTER, false
        bool signed = types.is_signed(lt) or types.is_signed(rt)
        if e.b.kind == ast.N_INT
            return irt(lt), types.is_signed(lt)
        if e.a.kind == ast.N_INT
            return irt(rt), types.is_signed(rt)
        ubyte a = irt(lt)
        ubyte b = irt(rt)
        if irt_size(a) >= irt_size(b)
            return a, signed
        return b, signed
    }

    ; Is the operand a string: a str variable or literal, or a parameter that was
    ; declared str (which is kept as a pointer to its bytes)?
    sub is_string(^^ast.Node e) -> bool {
        if e.type == types.T_STR
            return true
        if e.kind == ast.N_IDENT and e.op != resolver.R_FIELDREF and e.extra != 0 {
            ^^symtab.Sym s = e.extra
            if s.kind == symtab.K_PARAM and s.decl != 0 and s.decl.a != 0 and s.decl.a.kind == ast.N_TYPE
                return typer.from_type(s.decl.a) == types.T_STR
        }
        return false
    }

    ; emits the branch(es) for a comparison
    sub compare_branch(^^ast.Node e, ^^ubyte on_true, ^^ubyte on_false) {
        ubyte ct
        bool signed
        ct, signed = compare_type(e)
        uword lr
        ubyte lt
        lr, lt = expression(e.a)
        lr = convert(lr, lt, ct, types.is_signed(e.a.type))
        bool ok
        quad cv
        ok, cv = typer.const_eval(e.b)
        ubyte op = e.op
        ^^ubyte target = on_true
        if on_true == 0 {
            op = invert_op(op)
            target = on_false
        }
        if is_string(e.a) and is_string(e.b) {
            ; strings compare by content: the virtual machine's compare syscall gives -1, 0 or 1
            uword sr
            ubyte srt
            sr, srt = expression(e.b)
            uword cmps = ir.new_reg(ir.T_BYTE)
            ^^ir.Instr sc = ir.emit_syscall(chunk, "$100d")
            ir.add_arg(sc, ir.new_arg(0, lr, address_irt))
            ir.add_arg(sc, ir.new_arg(0, sr, address_irt))
            ir.add_result(sc, ir.new_arg(0, cmps, ir.T_BYTE))
            if op == token.T_EQ or op == token.T_NE {
                void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, cmps, 0)
                if op == token.T_EQ
                    void ir.emit_t(chunk, ir.OP_BSTEQ, target)
                else
                    void ir.emit_t(chunk, ir.OP_BSTNE, target)
            }
            else
                void ir.emit_rit(chunk, branch_imm_op(op, true), ir.T_BYTE, cmps, 0, target)
            if on_true != 0 and on_false != 0
                jump(on_false)
            return
        }
        if ct == ir.T_FLOAT {
            ; fcomp gives -1, 0 or 1 as a byte; compare that with zero
            uword rr0
            ubyte rt0
            rr0, rt0 = expression(e.b)
            rr0 = convert(rr0, rt0, ir.T_FLOAT, true)
            uword cmpr = ir.new_reg(ir.T_BYTE)
            ^^ir.Instr fc = ir.emit_rrr(chunk, ir.OP_FCOMP, ir.T_FLOAT, cmpr, lr, rr0)
            fc.t1 = ir.T_BYTE
            if op == token.T_EQ or op == token.T_NE {
                void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, cmpr, 0)
                if op == token.T_EQ
                    void ir.emit_t(chunk, ir.OP_BSTEQ, target)
                else
                    void ir.emit_t(chunk, ir.OP_BSTNE, target)
            }
            else
                void ir.emit_rit(chunk, branch_imm_op(op, true), ir.T_BYTE, cmpr, 0, target)
            if on_true != 0 and on_false != 0
                jump(on_false)
            return
        }
        if ok {
            quad iv = truncate(cv, ct)
            if signed
                iv = cv         ; the virtual machine compares signed immediates as written
            if op == token.T_EQ or op == token.T_NE {
                void ir.emit_ri(chunk, ir.OP_CMPI, ct, lr, iv)
                if op == token.T_EQ
                    void ir.emit_t(chunk, ir.OP_BSTEQ, target)
                else
                    void ir.emit_t(chunk, ir.OP_BSTNE, target)
            }
            else
                void ir.emit_rit(chunk, branch_imm_op(op, signed), ct, lr, iv, target)
        }
        else {
            uword rr
            ubyte rt
            rr, rt = expression(e.b)
            rr = convert(rr, rt, ct, types.is_signed(e.b.type))
            if op == token.T_EQ or op == token.T_NE {
                void ir.emit_rr(chunk, ir.OP_CMP, ct, lr, rr)
                if op == token.T_EQ
                    void ir.emit_t(chunk, ir.OP_BSTEQ, target)
                else
                    void ir.emit_t(chunk, ir.OP_BSTNE, target)
            }
            else if op == token.T_LT or op == token.T_LE {
                ; a < b is b > a; a <= b is b >= a
                if op == token.T_LT
                    void ir.emit_rrt(chunk, reg_branch_op(token.T_GT, signed), ct, rr, lr, target)
                else
                    void ir.emit_rrt(chunk, reg_branch_op(token.T_GE, signed), ct, rr, lr, target)
            }
            else
                void ir.emit_rrt(chunk, reg_branch_op(op, signed), ct, lr, rr, target)
        }
        if on_true != 0 and on_false != 0
            jump(on_false)
    }

    sub branch_imm_op(ubyte op, bool signed) -> ubyte {
        when op {
            token.T_LT -> {
                if signed
                    return ir.OP_BLTS
                return ir.OP_BLT
            }
            token.T_GT -> {
                if signed
                    return ir.OP_BGTS
                return ir.OP_BGT
            }
            token.T_LE -> {
                if signed
                    return ir.OP_BLES
                return ir.OP_BLE
            }
            token.T_GE -> {
                if signed
                    return ir.OP_BGES
                return ir.OP_BGE
            }
        }
        return ir.OP_NOP
    }

    sub reg_branch_op(ubyte op, bool signed) -> ubyte {
        if op == token.T_GT {
            if signed
                return ir.OP_BGTSR
            return ir.OP_BGTR
        }
        if signed
            return ir.OP_BGESR
        return ir.OP_BGER
    }

    sub ifstmt(^^ast.Node n) {
        ; a condition that is a constant (a feature switch, say): only the part that runs
        bool known
        quad truth
        known, truth = typer.const_eval(n.a)
        if known {
            if truth != 0
                statements(n.b)
            else if n.c != 0
                statements(n.c)
            return
        }
        ^^ubyte after = new_label()
        if n.c != 0 {
            ^^ubyte elselabel = new_label()
            condition(n.a, 0, elselabel)
            statements(n.b)
            jump(after)
            label(elselabel)
            statements(n.c)
        }
        else {
            condition(n.a, 0, after)
            statements(n.b)
        }
        label(after)
    }

    sub branchstmt(^^ast.Node n) {
        ^^ubyte after = new_label()
        ^^ubyte elselabel = after
        if n.c != 0
            elselabel = new_label()
        ; branch to the else part when the status condition does not hold
        void ir.emit_t(chunk, status_branch(n.op, true), elselabel)
        statements(n.b)
        if n.c != 0 {
            jump(after)
            label(elselabel)
            statements(n.c)
        }
        label(after)
    }

    ; the status flag branch for an if_xx condition, or its inverse
    sub status_branch(ubyte kw, bool inverted) -> ubyte {
        ubyte op = ir.OP_NOP
        when kw {
            token.T_KW_IF_CS -> op = ir.OP_BSTCS
            token.T_KW_IF_CC -> op = ir.OP_BSTCC
            token.T_KW_IF_EQ, token.T_KW_IF_Z -> op = ir.OP_BSTEQ
            token.T_KW_IF_NE, token.T_KW_IF_NZ -> op = ir.OP_BSTNE
            token.T_KW_IF_NEG, token.T_KW_IF_MI -> op = ir.OP_BSTNEG
            token.T_KW_IF_POS, token.T_KW_IF_PL -> op = ir.OP_BSTPOS
            token.T_KW_IF_VS -> op = ir.OP_BSTVS
            token.T_KW_IF_VC -> op = ir.OP_BSTVC
        }
        if not inverted
            return op
        when op {
            ir.OP_BSTCS -> return ir.OP_BSTCC
            ir.OP_BSTCC -> return ir.OP_BSTCS
            ir.OP_BSTEQ -> return ir.OP_BSTNE
            ir.OP_BSTNE -> return ir.OP_BSTEQ
            ir.OP_BSTNEG -> return ir.OP_BSTPOS
            ir.OP_BSTPOS -> return ir.OP_BSTNEG
            ir.OP_BSTVS -> return ir.OP_BSTVC
            ir.OP_BSTVC -> return ir.OP_BSTVS
        }
        return op
    }

    sub push_loop(^^ubyte brk, ^^ubyte cont) {
        if loop_depth < MAX_LOOPS {
            break_labels[loop_depth] = brk
            continue_labels[loop_depth] = cont
        }
        loop_depth++
    }

    sub pop_loop() {
        loop_depth--
    }

    sub whilestmt(^^ast.Node n) {
        ; the test at the end, so that going round is one branch (and not a branch and a jump)
        ^^ubyte body = new_label()
        ^^ubyte done = new_label()
        ^^ubyte test = new_label()
        jump(test)
        label(body)
        push_loop(done, test)
        statements(n.b)
        pop_loop()
        label(test)
        condition(n.a, body, 0)
        label(done)
    }

    sub untilstmt(^^ast.Node n) {
        ^^ubyte top = new_label()
        ^^ubyte done = new_label()
        ^^ubyte test = new_label()
        label(top)
        push_loop(done, test)
        statements(n.a)
        pop_loop()
        label(test)
        condition(n.b, 0, top)
        label(done)
    }

    sub repeatstmt(^^ast.Node n) {
        ^^ubyte top = new_label()
        ^^ubyte done = new_label()
        ^^ubyte next = new_label()
        if n.a == 0 {
            ; forever
            label(top)
            push_loop(done, top)
            statements(n.b)
            pop_loop()
            jump(top)
            label(done)
            return
        }
        bool ok
        quad count
        ok, count = typer.const_eval(n.a)
        if ok and count == 0
            return
        if ok and count == 1 {
            push_loop(done, done)
            statements(n.b)
            pop_loop()
            label(done)
            return
        }
        uword cr
        ubyte ct
        cr, ct = expression(n.a)
        if ct == ir.T_FLOAT {
            ; "repeat 2.5" is twice
            cr = convert(cr, ct, ir.T_WORD, false)
            ct = ir.T_WORD
        }
        if not ok {
            void ir.emit_ri(chunk, ir.OP_CMPI, ct, cr, 0)
            void ir.emit_t(chunk, ir.OP_BSTEQ, done)
        }
        label(top)
        push_loop(done, next)
        statements(n.b)
        pop_loop()
        label(next)
        void ir.emit_r(chunk, ir.OP_DEC, ct, cr)
        void ir.emit_ri(chunk, ir.OP_CMPI, ct, cr, 0)
        void ir.emit_t(chunk, ir.OP_BSTNE, top)
        label(done)
    }

    sub unrollstmt(^^ast.Node n) {
        bool ok
        quad count
        ok, count = typer.const_eval(n.a)
        if not ok
            return
        repeat count as long
            statements(n.b)
    }

    ; for p in start via .field: a linked list walk, as a while loop on the pointer
    sub via_loop(^^ast.Node n, ^^ast.Node opt, ^^symtab.Sym lv) {
        ^^ubyte vname = sym_name(lv)
        ^^symtab.Sym st = pointed_struct(lv.type)
        ^^symtab.Sym fld = 0
        if st != 0 and st.inner != 0 {
            fld = st.inner.syms
            while fld != 0 and strings.compare(fld.name, opt.a.name) != 0
                fld = fld.next
        }
        if fld == 0 {
            unsupported(opt, "via field")
            return
        }
        ^^ubyte vtop = new_label()
        ^^ubyte vnext = new_label()
        ^^ubyte vdone = new_label()
        uword sr
        ubyte srt
        sr, srt = expression(n.b)
        sr = convert(sr, srt, ir.T_POINTER, false)
        void ir.emit_rm(chunk, ir.OP_STOREM, ir.T_POINTER, sr, vname, 0)
        label(vtop)
        uword cr = ir.new_reg(ir.T_POINTER)
        void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_POINTER, cr, vname, 0)
        void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_POINTER, cr, 0)
        void ir.emit_t(chunk, ir.OP_BSTEQ, vdone)
        ^^ast.Node uopt = n.d
        while uopt != 0 {
            if uopt.kind == ast.N_FOROPT and uopt.op == token.T_KW_UNTIL {
                ; "until node": the walk ends before that one
                uword ur
                ubyte ut
                ur, ut = expression(uopt.a)
                void ir.emit_rr(chunk, ir.OP_CMP, ir.T_POINTER, cr, convert(ur, ut, ir.T_POINTER, false))
                void ir.emit_t(chunk, ir.OP_BSTEQ, vdone)
            }
            uopt = uopt.next
        }
        push_loop(vdone, vnext)
        statements(n.c)
        pop_loop()
        label(vnext)
        uword pr = ir.new_reg(ir.T_POINTER)
        void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_POINTER, pr, vname, 0)
        uword nr = ir.new_reg(ir.T_POINTER)
        void ir.emit_rp(chunk, ir.OP_LOADI, ir.T_POINTER, nr, pr, field_offset(fld))
        void ir.emit_rm(chunk, ir.OP_STOREM, ir.T_POINTER, nr, vname, 0)
        jump(vtop)
        label(vdone)
    }

    ; A for loop over a range whose start, end and step are all constants, with a byte
    ; or word variable: the number of iterations is known, so the loop runs until the
    ; variable equals the value one step past the end, as upstream writes it.  That
    ; value is reached exactly, also when the count wraps around (0 to 255).  An empty
    ; range has no code at all.  False when the loop is not of this kind.
    sub constant_range_loop(^^ast.Node n, ^^symtab.Sym lv, ubyte lvt, bool signed) -> bool {
        ^^ast.Node iter = n.b
        if lvt != ir.T_BYTE and lvt != ir.T_WORD
            return false
        if is_split(lv) or (lv.kind != symtab.K_VAR and lv.kind != symtab.K_PARAM and lv.kind != symtab.K_MEMVAR)
            return false
        bool ok
        quad first
        quad last
        quad stride = 1
        ok, first = typer.const_eval(iter.a)
        if not ok
            return false
        ok, last = typer.const_eval(iter.b)
        if not ok
            return false
        if iter.c != 0 {
            ok, stride = typer.const_eval(iter.c)
            if not ok or stride == 0
                return false
        }
        else if iter.op == token.T_KW_DOWNTO
            stride = -1
        ; the values as the variable's type sees them
        quad span = 256
        if lvt == ir.T_WORD
            span = 65536
        if signed {
            if first >= span / 2
                first -= span
            if last >= span / 2
                last -= span
        }
        quad count
        if stride > 0 {
            if first > last
                return true         ; nothing to run
            count = (last - first) / stride + 1
        }
        else {
            if first < last
                return true
            count = (first - last) / (-stride) + 1
        }
        if count > span
            return false
        quad beyond = first + count * stride
        ^^ubyte lvname
        long lvoff
        lvname, lvoff = var_ref(lv)     ; (a memory-mapped loop variable is its address)
        ^^ubyte top = new_label()
        ^^ubyte done = new_label()
        ^^ubyte next = new_label()
        if truncate(first, lvt) == 0
            void ir.emit_m(chunk, ir.OP_STOREZM, lvt, lvname, lvoff)
        else
            void ir.emit_im(chunk, ir.OP_STOREIM, lvt, truncate(first, lvt), lvname, lvoff)
        label(top)
        push_loop(done, next)
        statements(n.c)
        pop_loop()
        label(next)
        if stride == 1
            void ir.emit_m(chunk, ir.OP_INCM, lvt, lvname, lvoff)
        else if stride == -1
            void ir.emit_m(chunk, ir.OP_DECM, lvt, lvname, lvoff)
        else if stride > 0
            void ir.emit_im(chunk, ir.OP_ADDIM, lvt, stride, lvname, lvoff)
        else
            void ir.emit_im(chunk, ir.OP_SUBIM, lvt, -stride, lvname, lvoff)
        uword cur = ir.new_reg(lvt)
        void ir.emit_rm(chunk, ir.OP_LOADM, lvt, cur, lvname, lvoff)
        void ir.emit_ri(chunk, ir.OP_CMPI, lvt, cur, truncate(beyond, lvt))
        void ir.emit_t(chunk, ir.OP_BSTNE, top)
        label(done)
        return true
    }

    sub forstmt(^^ast.Node n) {
        ^^symtab.Sym lv = n.a.extra
        if lv == 0
            return
        ^^ast.Node iter = n.b
        uword lvt_p8 = lv.type
        ubyte lvt = irt(lvt_p8)
        bool signed = types.is_signed(lvt_p8)
        ^^ubyte lvname
        long lvoff
        lvname, lvoff = var_ref(lv)     ; (a memory-mapped loop variable is its address)
        ^^ubyte top = new_label()
        ^^ubyte done = new_label()
        ^^ubyte next = new_label()
        bool ok
        quad v
        ^^ast.Node opt = n.d
        while opt != 0 {
            if opt.kind == ast.N_FOROPT and opt.op == token.T_KW_VIA {
                via_loop(n, opt, lv)
                return
            }
            opt = opt.next
        }
        if iter.kind == ast.N_RANGE and constant_range_loop(n, lv, lvt, signed)
            return
        if iter.kind == ast.N_RANGE {
            ; from, to and step
            quad stride = 1
            bool const_stride = true
            if iter.c != 0 {
                ok, stride = typer.const_eval(iter.c)
                if not ok or (stride != 1 and stride != -1) {
                    variable_step_loop(n, lv, lvt, signed)
                    return
                }
            }
            else if iter.op == token.T_KW_DOWNTO
                stride = -1
            uword fr
            ubyte ft
            fr, ft = expression(iter.a)
            fr = convert(fr, ft, lvt, types.is_signed(iter.a.type))
            uword tr
            ubyte tt
            tr, tt = expression(iter.b)
            tr = convert(tr, tt, lvt, types.is_signed(iter.b.type))
            void ir.emit_rm(chunk, ir.OP_STOREM, lvt, fr, lvname, lvoff)
            ; an empty range runs no iteration: from > to when counting up
            if stride > 0
                void ir.emit_rrt(chunk, reg_branch_op(token.T_GT, signed), lvt, fr, tr, done)
            else
                void ir.emit_rrt(chunk, reg_branch_op(token.T_GT, signed), lvt, tr, fr, done)
            label(top)
            push_loop(done, next)
            statements(n.c)
            pop_loop()
            label(next)
            ; the last value was done when the variable equals the end
            uword cur = ir.new_reg(lvt)
            void ir.emit_rm(chunk, ir.OP_LOADM, lvt, cur, lvname, lvoff)
            void ir.emit_rr(chunk, ir.OP_CMP, lvt, cur, tr)
            void ir.emit_t(chunk, ir.OP_BSTEQ, done)
            if stride == 1
                void ir.emit_m(chunk, ir.OP_INCM, lvt, lvname, lvoff)
            else if stride == -1
                void ir.emit_m(chunk, ir.OP_DECM, lvt, lvname, lvoff)
            else if stride > 0
                void ir.emit_im(chunk, ir.OP_ADDIM, lvt, stride, lvname, lvoff)
            else
                void ir.emit_im(chunk, ir.OP_SUBIM, lvt, -stride, lvname, lvoff)
            jump(top)
            label(done)
            return
        }
        ; over an array, string or pointer: an index register
        uword it = iter.type
        uword elem = types.index_elem(it)
        ubyte et = irt(elem)
        long elemsize = types.size_of(elem)
        if elemsize == 0
            elemsize = 1
        bool is_str = it == types.T_STR or types.is_pointer(it)
        ^^symtab.Sym arr = 0
        ^^ubyte arrname = 0
        long length = 0
        if iter.kind == ast.N_IDENT and iter.op != resolver.R_FIELDREF
            arr = iter.extra
        if arr != 0 and (types.is_array(arr.type) or arr.type == types.T_STR) {
            arrname = sym_name(arr)
            length = typer.known_length(iter)
        }
        else if iter.kind == ast.N_STR {
            arrname = intern_string(iter)
            is_str = true
            et = ir.T_BYTE
            elemsize = 1
            length = typer.known_length(iter)
        }
        else if iter.kind == ast.N_ARRAYLIT {
            arrname = intern_array(iter, lvt_p8)
            length = ast.list_length(iter.a)
            is_str = false
            et = lvt
            elemsize = irt_size(lvt)
        }
        else if (it == types.T_STR or (types.is_pointer(it) and elemsize == 1)) and iter.kind == ast.N_IDENT {
            ; a string by its address (a str parameter, a pointer to bytes): from where it
            ; points up to the zero
            uword pr
            ubyte pt
            pr, pt = expression(iter)
            uword walker = ir.new_reg(ir.T_POINTER)
            void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_POINTER, walker, convert(pr, pt, ir.T_POINTER, false))
            label(top)
            uword ch = ir.new_reg(ir.T_BYTE)
            void ir.emit_rp(chunk, ir.OP_LOADI, ir.T_BYTE, ch, walker, 0)
            void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, ch, 0)
            void ir.emit_t(chunk, ir.OP_BSTEQ, done)
            void ir.emit_rm(chunk, ir.OP_STOREM, lvt, convert(ch, ir.T_BYTE, lvt, false), lvname, lvoff)
            push_loop(done, next)
            statements(n.c)
            pop_loop()
            label(next)
            void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, walker, 1)
            jump(top)
            label(done)
            return
        }
        else {
            unsupported(iter, "for loop over this iterable")
            return
        }
        ; "step -1": from the last element to the first (the length has to be known)
        bool backwards = false
        ^^ast.Node fopt = n.d
        while fopt != 0 {
            if fopt.kind == ast.N_FOROPT and fopt.op == token.T_KW_STEP {
                bool sok
                quad sv
                sok, sv = typer.const_eval(fopt.a)
                if sok and sv == -1 and length != 0
                    backwards = true
                else if not sok or sv != 1
                    unsupported(fopt, "this step over an array or string")
            }
            fopt = fopt.next
        }
        if is_split(arr) {
            ; both halves of each element, by a byte index
            uword six = ir.new_reg(ir.T_BYTE)
            if backwards
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, six, (length - 1) & 255)
            else
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, six, 0)
            label(top)
            uword smr = ir.new_reg(ir.T_BYTE)
            uword slr = ir.new_reg(ir.T_BYTE)
            void ir.emit_rmx(chunk, ir.OP_LOADX, ir.T_BYTE, smr, split_name(arr, true), 0, six, 1)
            void ir.emit_rmx(chunk, ir.OP_LOADX, ir.T_BYTE, slr, split_name(arr, false), 0, six, 1)
            uword swr = ir.new_reg(ir.T_WORD)
            ^^ir.Instr sci = ir.emit_rrr(chunk, ir.OP_CONCAT, ir.T_BYTE, swr, smr, slr)
            sci.t1 = ir.T_WORD
            uword ssr = convert(swr, ir.T_WORD, lvt, types.is_signed(elem))
            void ir.emit_rm(chunk, ir.OP_STOREM, lvt, ssr, lvname, lvoff)
            push_loop(done, next)
            statements(n.c)
            pop_loop()
            label(next)
            if backwards {
                void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, six, 0)
                void ir.emit_t(chunk, ir.OP_BSTEQ, done)
                void ir.emit_r(chunk, ir.OP_DEC, ir.T_BYTE, six)
                jump(top)
            }
            else {
                void ir.emit_r(chunk, ir.OP_INC, ir.T_BYTE, six)
                void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, six, length & 255)
                void ir.emit_t(chunk, ir.OP_BSTNE, top)
            }
            label(done)
            return
        }
        ubyte ixt = ir.T_WORD
        if split_words and length < 256
            ixt = ir.T_BYTE         ; the 6502 indexes with a byte register
        uword ix = ir.new_reg(ixt)
        if backwards
            void ir.emit_ri(chunk, ir.OP_LOAD, ixt, ix, length - 1)
        else
            void ir.emit_ri(chunk, ir.OP_LOAD, ixt, ix, 0)
        label(top)
        uword er = ir.new_reg(et)
        void ir.emit_rmx(chunk, ir.OP_LOADX, et, er, arrname, 0, ix, elemsize as ubyte)
        if is_str and not backwards {
            void ir.emit_ri(chunk, ir.OP_CMPI, et, er, 0)
            void ir.emit_t(chunk, ir.OP_BSTEQ, done)
        }
        uword sr = convert(er, et, lvt, types.is_signed(elem))
        void ir.emit_rm(chunk, ir.OP_STOREM, lvt, sr, lvname, lvoff)
        push_loop(done, next)
        statements(n.c)
        pop_loop()
        label(next)
        if backwards {
            void ir.emit_ri(chunk, ir.OP_CMPI, ixt, ix, 0)
            void ir.emit_t(chunk, ir.OP_BSTEQ, done)
            void ir.emit_r(chunk, ir.OP_DEC, ixt, ix)
            jump(top)
            label(done)
            return
        }
        void ir.emit_r(chunk, ir.OP_INC, ixt, ix)
        if not is_str {
            void ir.emit_ri(chunk, ir.OP_CMPI, ixt, ix, length)
            void ir.emit_t(chunk, ir.OP_BSTNE, top)
        }
        else
            jump(top)
        label(done)
    }

    ; for v in from to to_value step s, with a step only known at run time
    sub variable_step_loop(^^ast.Node n, ^^symtab.Sym lv, ubyte lvt, bool signed) {
        ^^ast.Node iter = n.b
        ^^ubyte lvname
        long lvoff
        lvname, lvoff = var_ref(lv)     ; (a memory-mapped loop variable is its address)
        ^^ubyte after = new_label()
        ^^ubyte top = new_label()
        ^^ubyte storenext = new_label()
        ^^ubyte descending = new_label()
        ^^ubyte desctail = new_label()
        bool signed_step = types.is_signed(iter.c.type)
        uword fr
        ubyte ft
        fr, ft = expression(iter.a)
        fr = convert(fr, ft, lvt, types.is_signed(iter.a.type))
        uword tr
        ubyte tt
        tr, tt = expression(iter.b)
        tr = convert(tr, tt, lvt, types.is_signed(iter.b.type))
        uword sr
        ubyte st
        sr, st = expression(iter.c)
        sr = convert(sr, st, lvt, signed_step)
        ; a zero step runs nothing
        void ir.emit_ri(chunk, ir.OP_CMPI, lvt, sr, 0)
        void ir.emit_t(chunk, ir.OP_BSTEQ, after)
        if signed_step
            void ir.emit_t(chunk, ir.OP_BSTNEG, descending)
        ubyte gt = reg_branch_op(token.T_GT, signed)
        uword direction = ir.new_reg(ir.T_BYTE)
        uword cur = ir.new_reg(lvt)
        uword nxt = ir.new_reg(lvt)
        if signed_step
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, direction, 0)
        void ir.emit_rrt(chunk, gt, lvt, fr, tr, after)
        void ir.emit_rm(chunk, ir.OP_STOREM, lvt, fr, lvname, lvoff)
        jump(top)
        if signed_step {
            label(descending)
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, direction, 1)
            void ir.emit_rrt(chunk, gt, lvt, tr, fr, after)
            void ir.emit_rm(chunk, ir.OP_STOREM, lvt, fr, lvname, lvoff)
        }
        label(top)
        push_loop(after, storenext)
        statements(n.c)
        pop_loop()
        void ir.emit_rm(chunk, ir.OP_LOADM, lvt, cur, lvname, lvoff)
        void ir.emit_rr(chunk, ir.OP_LOADR, lvt, nxt, cur)
        void ir.emit_rr(chunk, ir.OP_ADDR, lvt, nxt, sr)
        if signed_step {
            void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, direction, 0)
            void ir.emit_t(chunk, ir.OP_BSTNE, desctail)
        }
        ; ascending: a wrap makes next smaller; next must not pass the end
        void ir.emit_rrt(chunk, gt, lvt, cur, nxt, after)
        void ir.emit_rrt(chunk, gt, lvt, nxt, tr, after)
        jump(storenext)
        if signed_step {
            label(desctail)
            void ir.emit_rrt(chunk, gt, lvt, nxt, cur, after)
            void ir.emit_rrt(chunk, gt, lvt, tr, nxt, after)
            jump(storenext)
        }
        label(storenext)
        void ir.emit_rm(chunk, ir.OP_STOREM, lvt, nxt, lvname, lvoff)
        jump(top)
        label(after)
    }

    sub whenstmt(^^ast.Node n) {
        uword vr
        ubyte vt
        vr, vt = expression(n.a)
        ^^ubyte done = new_label()
        ^^ubyte elselabel = 0
        ; first the comparisons, then the bodies
        ^^ast.Node c = n.b
        uword nchoices = 0
        while c != 0 {
            if c.a != 0
                nchoices++
            c = c.next
        }
        ; the label of each choice is remembered in its node (extra is free there)
        bool ok
        quad cv
        c = n.b
        while c != 0 {
            if c.a == 0
                elselabel = new_label()
            else {
                ^^ubyte cl = new_label()
                c.extra = cl
                ^^ast.Node value = c.a
                while value != 0 {
                    if value.kind == ast.N_RANGE
                        when_range(value, vr, vt, types.is_signed(n.a.type), cl)
                    else {
                        ok, cv = typer.constlike_eval(value)
                        if ok {
                            void ir.emit_ri(chunk, ir.OP_CMPI, vt, vr, truncate(cv, vt))
                            void ir.emit_t(chunk, ir.OP_BSTEQ, cl)
                        }
                    }
                    value = value.next
                }
            }
            c = c.next
        }
        if elselabel != 0
            jump(elselabel)
        else
            jump(done)
        c = n.b
        while c != 0 {
            if c.a == 0
                label(elselabel)
            else
                label(c.extra)
            statements(c.b)
            jump(done)
            c = c.next
        }
        label(done)
    }

    ; A choice of a when that is a range ("10 to 20", "9 downto 1 step -2"): with a step
    ; of one, two comparisons with its ends; else each of its values.
    sub when_range(^^ast.Node range, uword vr, ubyte vt, bool signed, ^^ubyte target) {
        bool ok
        quad first
        quad last
        quad step = 1
        ok, first = typer.constlike_eval(range.a)
        if not ok
            return
        ok, last = typer.constlike_eval(range.b)
        if not ok
            return
        if range.op == token.T_KW_DOWNTO
            step = -1
        if range.c != 0 {
            ok, step = typer.constlike_eval(range.c)
            if not ok or step == 0
                return
        }
        if step == 1 or step == -1 {
            quad low = first
            quad high = last
            if step < 0 {
                low = last
                high = first
            }
            if low > high
                return              ; (an empty range: no value)
            ^^ubyte below = new_label()
            if signed {
                void ir.emit_rit(chunk, ir.OP_BLTS, vt, vr, truncate(low, vt), below)
                void ir.emit_rit(chunk, ir.OP_BLES, vt, vr, truncate(high, vt), target)
            }
            else {
                void ir.emit_rit(chunk, ir.OP_BLT, vt, vr, truncate(low, vt), below)
                void ir.emit_rit(chunk, ir.OP_BLE, vt, vr, truncate(high, vt), target)
            }
            label(below)
            return
        }
        uword most = 0
        quad v = first
        while most < 1024 and ((step > 0 and v <= last) or (step < 0 and v >= last)) {
            void ir.emit_ri(chunk, ir.OP_CMPI, vt, vr, truncate(v, vt))
            void ir.emit_t(chunk, ir.OP_BSTEQ, target)
            v += step
            most++
        }
    }

    ; on index goto (a, b, c) / on index call (a, b, c) [else ...]: a chain of
    ; comparisons, as upstream generates for the targets without jump tables.
    ; An index past the list runs the else part, or just continues.
    sub ongoto(^^ast.Node n) {
        uword r
        ubyte rt
        r, rt = expression(n.a)
        ^^ubyte done = new_label()
        ^^ast.Node target = n.b
        quad k = 0
        while target != 0 {
            ^^symtab.Sym ts = target.extra
            if ts == 0 {
                unsupported(target, "on ... goto target")
                return
            }
            void ir.emit_ri(chunk, ir.OP_CMPI, rt, r, k)
            if n.op == token.T_KW_GOTO
                void ir.emit_t(chunk, ir.OP_BSTEQ, sym_name(ts))
            else {
                ^^ubyte skip = new_label()
                void ir.emit_t(chunk, ir.OP_BSTNE, skip)
                void ir.emit_call(chunk, sym_name(ts))
                jump(done)
                label(skip)
            }
            k++
            target = target.next
        }
        if n.c != 0
            statements(n.c)
        label(done)
    }

    sub gotostmt(^^ast.Node n) {
        ^^ast.Node t = n.a
        if t.kind == ast.N_IDENT and t.extra != 0 {
            ^^symtab.Sym s = t.extra
            if s.kind == symtab.K_LABEL or s.kind == symtab.K_SUB {
                if s.kind == symtab.K_SUB or s.scope != scope
                    defer_exit()        ; a jump out of this subroutine
                jump(sym_name(s))
                return
            }
        }
        uword r
        ubyte rt
        r, rt = expression(t)
        r = convert(r, rt, ir.T_POINTER, false)
        void ir.emit_r(chunk, ir.OP_JUMPI, ir.T_POINTER, r)
    }

    ; ---- several return values on the 6502 ----
    ;
    ; A subroutine (not an asmsub) returns its first value in A, AY or FAC1, or a long in
    ; the virtual register pair R14R15, as it would a single value; the other values are
    ; in the virtual registers, counting down from R15.  A long takes the highest pair
    ; (R12R13, R10R11, ...) of which neither half is in use.  A call has no result list:
    ; the caller reads the values from those places.  This follows upstream to the letter,
    ; including that a long first value does not reserve R14 and R15 for the others.

    ubyte[16] place_slot            ; the hardware slot of each return value, or 255: in memory
    long[16] place_address          ; then the address of its virtual register
    bool[16] vreg_taken
    bool[8] vpair_taken

    sub vreg_address(ubyte number) -> long {
        ^^symtab.Sym cxblock = symtab.find_in(symtab.global, strtab.intern_cstr("cx16"))
        if cxblock == 0 or cxblock.inner == 0
            return 0
        ^^buf.Buf vb = buf.new(8)
        buf.add_byte(vb, 'r')
        buf.add_long(vb, number)
        ^^symtab.Sym vs = symtab.find_in(cxblock.inner, strtab.intern(vb.data, vb.len as uword))
        if vs == 0
            return 0
        ^^ubyte vname
        long vaddr
        vname, vaddr = var_ref(vs)
        return vaddr
    }

    ; fills place_slot and place_address for a list of return types; gives their number
    sub place_returns(^^ast.Node rt) -> ubyte {
        ubyte i
        for i in 0 to 15
            vreg_taken[i] = false
        for i in 0 to 7
            vpair_taken[i] = false
        ubyte count = 0
        while rt != 0 and count < 16 {
            ubyte t = plain(irt(typer.return_type(rt)))
            place_slot[count] = 255
            place_address[count] = 0
            if count == 0 {
                when t {
                    ir.T_BYTE -> place_slot[0] = 0
                    ir.T_FLOAT -> place_slot[0] = 6
                    ir.T_LONG -> {
                        vpair_taken[7] = true
                        place_address[0] = vreg_address(14)
                    }
                    else -> place_slot[0] = 4
                }
            }
            else if t == ir.T_FLOAT
                place_slot[count] = 6
            else if t == ir.T_LONG {
                ubyte pair = 8
                while pair > 0 {
                    pair--
                    if not vpair_taken[pair] {
                        vpair_taken[pair] = true
                        vreg_taken[pair * 2] = true
                        vreg_taken[pair * 2 + 1] = true
                        place_address[count] = vreg_address(pair * 2)
                        break
                    }
                }
            }
            else {
                ubyte vr = 16
                while vr > 0 {
                    vr--
                    if not vreg_taken[vr] {
                        vreg_taken[vr] = true
                        vpair_taken[vr / 2] = true
                        place_address[count] = vreg_address(vr)
                        break
                    }
                }
            }
            count++
            rt = rt.next
        }
        return count
    }

    ; a register with the return value in place number i
    sub load_place(ubyte i, ubyte t) -> uword {
        uword r = ir.new_reg(t)
        if place_slot[i] != 255
            void ir.emit_rs(chunk, ir.OP_LOADHR, t, r, place_slot[i])
        else
            void ir.emit_rm(chunk, ir.OP_LOADM, t, r, 0, place_address[i])
        return r
    }

    sub store_place(ubyte i, ubyte t, uword r) {
        if place_slot[i] != 255
            void ir.emit_rs(chunk, ir.OP_STOREHR, t, r, place_slot[i])
        else
            void ir.emit_rm(chunk, ir.OP_STOREM, t, r, 0, place_address[i])
    }

    ; One of several results of an asmsub call on the 6502.  The call only lists the
    ; result registers; the caller fetches each value: from its CPU register, or from
    ; the virtual register's memory (upstream does the same).  Status flag results are
    ; left as the call gives them.
    sub fetch_asm_result(^^ir.Arg result, ^^ast.Node rt) {
        if not split_words
            return
        if result.slot != 255 {
            if result.slot < ir.SLOT_FLAGS
                void ir.emit_rs(chunk, ir.OP_LOADHR, result.type, result.reg, result.slot)
            return
        }
        if rt == 0 or rt.b == 0 or rt.b.name == 0
            return
        ^^ubyte r = rt.b.name
        if (r[0] & $df) != 'R' or r[1] < '0' or r[1] > '9'
            return
        ubyte number = r[1] - '0'
        if r[2] >= '0' and r[2] <= '9'
            number = number * 10 + (r[2] - '0')
        void ir.emit_rm(chunk, ir.OP_LOADM, result.type, result.reg, 0, vreg_address(number))
    }

    ; All the results of an asmsub call, in an order in which taking one does not lose
    ; another: the CPU registers first (a store changes no flag), then the flags Z, V
    ; and N by a branch (the loads of 0 and 1 leave the carry alone), then the carry
    ; (rotated into a zero, which uses A and changes Z and N), then the virtual
    ; registers, which are memory.
    sub fetch_asm_results(^^ir.Arg results, ^^ast.Node returns) {
        if not split_words
            return
        ^^ir.Arg r = results
        ^^ast.Node rt = returns
        while r != 0 {
            if r.slot != 255 and r.slot < ir.SLOT_FLAGS
                void ir.emit_rs(chunk, ir.OP_LOADHR, r.type, r.reg, r.slot)
            r = r.next
        }
        r = results
        while r != 0 {
            if r.slot != 255 and r.slot > ir.SLOT_FLAGS {
                ^^ubyte isset = new_label()
                ^^ubyte fdone = new_label()
                when r.slot - ir.SLOT_FLAGS {
                    1 -> void ir.emit_t(chunk, ir.OP_BSTEQ, isset)
                    2 -> void ir.emit_t(chunk, ir.OP_BSTVS, isset)
                    else -> void ir.emit_t(chunk, ir.OP_BSTNEG, isset)
                }
                void ir.emit_ri(chunk, ir.OP_LOAD, r.type, r.reg, 0)
                jump(fdone)
                label(isset)
                void ir.emit_ri(chunk, ir.OP_LOAD, r.type, r.reg, 1)
                label(fdone)
            }
            r = r.next
        }
        r = results
        while r != 0 {
            if r.slot == ir.SLOT_FLAGS {
                void ir.emit_ri(chunk, ir.OP_LOAD, r.type, r.reg, 0)
                void ir.emit_r(chunk, ir.OP_ROXL, r.type, r.reg)
            }
            r = r.next
        }
        r = results
        while r != 0 {
            if r.slot == 255
                fetch_asm_result(r, rt)
            if rt != 0
                rt = rt.next
            r = r.next
        }
    }

    ; return a, b, c on the 6502
    sub return_several(^^ast.Node n, ^^ast.Node rt) {
        ^^ast.Node v = n.a
        ubyte count = 0
        ubyte t
        if v.next == 0 and v.kind == ast.N_CALL {
            ; "return f()": the values of f are where this subroutine's go already,
            ; unless f is an asmsub with registers of its own or defers run in between
            ^^symtab.Sym callee = v.a.extra
            if callee != 0 and callee.kind == symtab.K_SUB and uses_registers(callee.decl) {
                void asm_call(v, 2)
                ^^ir.Arg ares = last_asm_call.results
                ^^ast.Node art = typer.returns_of(callee)
                fetch_asm_results(ares, art)
                while ares != 0 and count < len(return_regs) {
                    if art != 0
                        art = art.next
                    return_regs[count] = ares.reg
                    return_types[count] = ares.type
                    count++
                    ares = ares.next
                }
            }
            else {
                void call_sub(v, false)
                if defer_count == 0 {
                    void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
                    return
                }
                void place_returns(rt)
                ^^ast.Node rt2 = rt
                while rt2 != 0 and count < len(return_regs) {
                    t = irt(typer.return_type(rt2))
                    return_regs[count] = load_place(count, t)
                    return_types[count] = t
                    count++
                    rt2 = rt2.next
                }
            }
        }
        else {
            ^^ast.Node rt3 = rt
            while v != 0 and rt3 != 0 and count < len(return_regs) {
                t = irt(typer.return_type(rt3))
                uword r
                ubyte vt
                r, vt = expression(v)
                return_regs[count] = convert(r, vt, t, types.is_signed(v.type))
                return_types[count] = t
                count++
                v = v.next
                rt3 = rt3.next
            }
        }
        defer_exit()
        ubyte placed = place_returns(rt)
        if placed < count
            count = placed
        ; the first value last: storing the others uses A
        ubyte i = count
        while i > 1 {
            i--
            store_place(i, return_types[i], return_regs[i])
        }
        if count > 0
            store_place(0, return_types[0], return_regs[0])
        void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
    }

    sub returnstmt(^^ast.Node n) {
        ^^ast.Node rt = 0
        if subsym != 0
            rt = typer.returns_of(subsym)
        ^^ast.Node v = n.a
        if v == 0 or rt == 0 {
            if v != 0 {
                uword r0
                ubyte t0
                r0, t0 = expression(v)
            }
            defer_exit()
            void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
            return
        }
        uword rtype = typer.return_type(rt)
        ubyte t = irt(rtype)
        if rt.next == 0 and v.next == 0 {
            ; a single value
            bool ok
            quad cv
            ok, cv = typer.const_eval(v)
            if ok and t != ir.T_FLOAT {
                defer_exit()
                void ir.emit_i(chunk, ir.OP_RETURNI, t, truncate(cv, t))
                return
            }
            ; (the value is evaluated before the defers run, and waits in its register)
            uword r
            ubyte vt
            r, vt = expression(v)
            r = convert(r, vt, t, types.is_signed(v.type))
            defer_exit()
            void ir.emit_r(chunk, ir.OP_RETURNR, t, r)
            return
        }
        if split_words {
            return_several(n, rt)
            return
        }
        ; several values: through the hardware slots, s10 on for integers and
        ; s25 on for floats (the 68000's D0.. and FP0.., as upstream numbers them)
        ubyte count = return_slots(rt)
        ubyte k
        if v.next == 0 and v.kind == ast.N_CALL {
            ; "return f()" passing on the values of a multi-value call: the
            ; callee left them in the slots; copy them through registers as
            ; upstream does, so the slot types are declared.  All are loaded
            ; before any is stored: a register may share a slot's place.
            void call_sub(v, false)
            k = 0
            while rt != 0 and k < count {
                t = irt(typer.return_type(rt))
                return_regs[k] = ir.new_reg(t)
                return_types[k] = t
                void ir.emit_rs(chunk, ir.OP_LOADHR, t, return_regs[k], return_slot[k])
                k++
                rt = rt.next
            }
            store_returns(count)
            return
        }
        ; All values are computed, in the order they are written, before any is
        ; stored: a call or a division in one could use the place of another.
        k = 0
        while v != 0 and rt != 0 and k < count {
            t = irt(typer.return_type(rt))
            uword r2
            ubyte vt2
            r2, vt2 = expression(v)
            return_regs[k] = convert(r2, vt2, t, types.is_signed(v.type))
            return_types[k] = t
            k++
            v = v.next
            rt = rt.next
        }
        store_returns(count)
    }

    ubyte[16] return_slot           ; the hardware slot of each value of a multi-value return

    ; Numbers the slots of a list of return types; returns how many there are.
    sub return_slots(^^ast.Node rt) -> ubyte {
        ubyte count = 0
        ubyte data = 10
        ubyte fslot = 25
        while rt != 0 and count < len(return_slot) {
            if irt(typer.return_type(rt)) == ir.T_FLOAT {
                return_slot[count] = fslot
                fslot++
            }
            else {
                return_slot[count] = data
                data++
            }
            count++
            rt = rt.next
        }
        return count
    }

    ; The end of a multi-value return: the values are in return_regs.  The defers
    ; run, then the values go to their slots: the first one last, and a float for
    ; s25 after all others (on the 68000 the other float stores pass through it).
    sub store_returns(ubyte count) {
        defer_exit()
        ubyte pass
        for pass in 0 to 1 {
            ubyte i = 1
            while i <= count {
                ubyte j = i
                if i == count
                    j = 0
                if (return_slot[j] == 25) == (pass == 1)
                    void ir.emit_rs(chunk, ir.OP_STOREHR, return_types[j], return_regs[j], return_slot[j])
                i++
            }
        }
        void ir.emit(chunk, ir.OP_RETURN, ir.T_NONE, ir.M_NONE)
    }

    ; ---- expressions ----

    ; Converts a value register to another IR type.
    sub convert(uword r, ubyte from, ubyte to_t, bool signed) -> uword {
        if from == to_t or r == 0
            return r
        ubyte f = plain(from)
        ubyte t = plain(to_t)
        if f == t {
            if to_t == ir.T_POINTER
                ir.retype(r, ir.T_POINTER)
            return r
        }
        if f == ir.T_FLOAT or t == ir.T_FLOAT
            return float_convert(r, f, t, signed)
        uword nr = ir.new_reg(to_t)
        ubyte op
        if irt_size(f) < irt_size(t) {
            ; widening
            if t == ir.T_QUAD {
                op = ir.OP_EXTQ
                if signed
                    op = ir.OP_EXTQS
            }
            else if f == ir.T_BYTE and t == ir.T_LONG {
                op = ir.OP_EXTL
                if signed
                    op = ir.OP_EXTLS
            }
            else {
                op = ir.OP_EXT
                if signed
                    op = ir.OP_EXTS
            }
            if op == ir.OP_EXT and chunk.last != 0 and chunk.last.r1 == r {
                ; the value was loaded just now, for this: load it at the wider size
                ^^ir.Instr prev = chunk.last
                if prev.op == ir.OP_LOAD and prev.mode == ir.M_RI and prev.type == f and prev.sym == 0 {
                    prev.type = t
                    prev.r1 = nr
                    return nr
                }
                if prev.op == ir.OP_LOADM and prev.mode == ir.M_RM and prev.type == ir.T_BYTE and t == ir.T_WORD {
                    prev.op = ir.OP_LOADMZ
                    prev.t1 = ir.T_WORD
                    prev.r1 = nr
                    return nr
                }
            }
            ^^ir.Instr i = ir.emit_rr(chunk, op, f, nr, r)
            i.t1 = t
            return nr
        }
        ; narrowing: the least significant part
        if t == ir.T_BYTE
            op = ir.OP_LSIGB
        else if t == ir.T_WORD
            op = ir.OP_LSIGW
        else
            op = ir.OP_LSIGL
        ^^ir.Instr i2 = ir.emit_rr(chunk, op, f, nr, r)
        i2.t1 = t
        return nr
    }

    sub float_convert(uword r, ubyte f, ubyte t, bool signed) -> uword {
        uword nr = ir.new_reg(t)
        ubyte op
        if t == ir.T_FLOAT {
            when f {
                ir.T_BYTE -> {
                    op = ir.OP_FFROMUB
                    if signed
                        op = ir.OP_FFROMSB
                }
                ir.T_WORD -> {
                    op = ir.OP_FFROMUW
                    if signed
                        op = ir.OP_FFROMSW
                }
                else -> op = ir.OP_FFROMSL
            }
            ^^ir.Instr i = ir.emit_rr(chunk, op, ir.T_FLOAT, nr, r)
            i.t2 = f
            return nr
        }
        when t {
            ir.T_BYTE -> {
                op = ir.OP_FTOUB
                if signed
                    op = ir.OP_FTOSB
            }
            ir.T_WORD -> {
                op = ir.OP_FTOUW
                if signed
                    op = ir.OP_FTOSW
            }
            else -> op = ir.OP_FTOSL
        }
        ^^ir.Instr i2 = ir.emit_rr(chunk, op, ir.T_FLOAT, nr, r)
        i2.t1 = t
        return nr
    }

    sub load_immediate(quad v, ubyte t) -> uword {
        uword r = ir.new_reg(t)
        if t == ir.T_FLOAT
            void ir.emit_rf(chunk, ir.OP_LOAD, r, v as float)
        else
            void ir.emit_ri(chunk, ir.OP_LOAD, t, r, truncate(v, t))
        return r
    }

    ; Evaluates an expression; returns its register and IR type.
    sub expression(^^ast.Node e) -> uword, ubyte {
        bool ok
        quad cv
        uword rr
        ubyte rt
        ubyte t = irt(e.type)
        if t == ir.T_FLOAT and e.kind != ast.N_CALL {
            if typer.float_eval(e) {
                uword flr = ir.new_reg(ir.T_FLOAT)
                void ir.emit_rf(chunk, ir.OP_LOAD, flr, typer.float_value)
                return flr, ir.T_FLOAT
            }
        }
        if e.kind != ast.N_INT and e.kind != ast.N_BOOL and e.kind != ast.N_CHAR and t != ir.T_FLOAT {
            ; any constant expression is just its value
            ok, cv = typer.const_eval(e)
            if ok and e.kind != ast.N_CALL and e.kind != ast.N_ADDROF
                return load_immediate(cv, t), t
        }
        when e.kind {
            ast.N_INT, ast.N_BOOL -> return load_immediate(e.value, t), t
            ast.N_CHAR -> {
                typer.decode_literal(e)
                return load_immediate(e.value, t), t
            }
            ast.N_STR -> {
                uword sr = ir.new_reg(ir.T_POINTER)
                void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, sr, intern_string(e), 0)
                return sr, ir.T_POINTER
            }
            ast.N_IDENT -> {
                rr, rt = identifier(e)
                return rr, rt
            }
            ast.N_BINARY -> {
                rr, rt = binary(e)
                return rr, rt
            }
            ast.N_UNARY -> {
                rr, rt = unary(e)
                return rr, rt
            }
            ast.N_CAST -> {
                if e.type == types.T_BOOL and e.a.type != types.T_BOOL and e.a.type != 0
                        and (types.size_of(e.a.type) > 1 or e.a.type == types.T_FLOAT) {
                    ; anything that is not zero is true: all of the value counts, not its low byte
                    ^^ast.Node zero = mem.alloc(sizeof(ast.Node))
                    mem.copy(e, zero, sizeof(ast.Node))
                    zero.next = 0
                    zero.a = 0
                    zero.b = 0
                    zero.extra = 0
                    zero.type = e.a.type
                    if e.a.type == types.T_FLOAT {
                        zero.kind = ast.N_FLOAT
                        zero.name = "0.0"
                    }
                    else {
                        zero.kind = ast.N_INT
                        zero.value = 0
                    }
                    ^^ast.Node differs = mem.alloc(sizeof(ast.Node))
                    mem.copy(e, differs, sizeof(ast.Node))
                    differs.next = 0
                    differs.kind = ast.N_BINARY
                    differs.op = token.T_NE
                    differs.b = zero
                    differs.type = types.T_BOOL
                    rr, rt = binary(differs)
                    return rr, rt
                }
                uword cr
                ubyte ct
                cr, ct = expression(e.a)
                ; from a float, it is the type asked for that says signed or not
                bool cast_signed = types.is_signed(e.a.type)
                if plain(ct) == ir.T_FLOAT
                    cast_signed = types.is_signed(e.type)
                return convert(cr, ct, t, cast_signed), t
            }
            ast.N_INDEX -> {
                rr, rt = indexed(e)
                return rr, rt
            }
            ast.N_CALL -> {
                rr, rt = call_expr(e)
                return rr, rt
            }
            ast.N_ADDROF -> {
                rr, rt = addressof(e)
                return rr, rt
            }
            ast.N_DEREF -> {
                uword pr
                ubyte pt
                pr, pt = expression(e.a)
                uword dr = ir.new_reg(t)
                void ir.emit_rp(chunk, ir.OP_LOADI, t, dr, pr, 0)
                return dr, t
            }
            ast.N_FIELD -> {
                uword pr2
                ubyte pt2
                pr2, pt2 = expression(e.a)
                ^^symtab.Sym f = e.extra
                if f == 0
                    return 0, t
                uword fr = ir.new_reg(t)
                void ir.emit_rp(chunk, ir.OP_LOADI, t, fr, pr2, field_offset(f))
                return fr, t
            }
            ast.N_MEMREAD -> {
                uword mr = ir.new_reg(ir.T_BYTE)
                ok, cv = typer.const_eval(e.a)
                if ok {
                    void ir.emit_rm(chunk, ir.OP_LOADM, ir.T_BYTE, mr, 0, cv as long)
                    return mr, ir.T_BYTE
                }
                if e == once_node {
                    void ir.emit_rp(chunk, ir.OP_LOADI, ir.T_BYTE, mr, once_reg, 0)
                    return mr, ir.T_BYTE
                }
                uword ar
                ubyte at
                ar, at = expression(e.a)
                ar = convert(ar, at, address_type(e.a), false)
                void ir.emit_rp(chunk, ir.OP_LOADI, ir.T_BYTE, mr, ar, 0)
                return mr, ir.T_BYTE
            }
            ast.N_IFEXPR -> {
                rr, rt = ifexpr(e)
                return rr, rt
            }
            ast.N_BRANCHEXPR -> {
                ; if_cs a else b: one of two values by a flag of the CPU's status
                ubyte bt = irt(e.type)
                uword br = ir.new_reg(bt)
                ^^ubyte belse = new_label()
                ^^ubyte bdone = new_label()
                void ir.emit_t(chunk, status_branch(e.op, true), belse)
                rr, rt = expression(e.b)
                void ir.emit_rr(chunk, ir.OP_LOADR, bt, br, convert(rr, rt, bt, types.is_signed(e.b.type)))
                jump(bdone)
                label(belse)
                rr, rt = expression(e.c)
                void ir.emit_rr(chunk, ir.OP_LOADR, bt, br, convert(rr, rt, bt, types.is_signed(e.c.type)))
                label(bdone)
                return br, bt
            }
            ast.N_FLOAT -> {
                unsupported(e, "float literal value")
                return ir.new_reg(ir.T_FLOAT), ir.T_FLOAT
            }
            ast.N_ARRAYLIT -> {
                ; an array literal as a value: static data; the expression is its address
                uword alr = ir.new_reg(ir.T_POINTER)
                ubyte alt = ir.T_POINTER
                uword ale = types.T_UBYTE
                if e.type != 0 and types.is_array(e.type)
                    ale = types.elem_of(e.type)
                ^^ubyte alname = intern_array(e, ale)
                void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, alr, alname, 0)
                return alr, alt
            }
            ast.N_STRUCTINIT -> {
                ; a static instance; the expression is its address
                ^^symtab.Sym sis = e.extra
                uword sir = ir.new_reg(ir.T_POINTER)
                ubyte sit = ir.T_POINTER
                if sis == 0 {
                    unsupported(e, "struct initializer of an unknown struct")
                    return sir, sit
                }
                ^^ubyte siname = struct_instance(e.a, sis)
                void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, sir, siname, 0)
                return sir, sit
            }
            else -> {
                unsupported(e, "expression")
                return ir.new_reg(t), t
            }
        }
    }

    sub identifier(^^ast.Node e) -> uword, ubyte {
        ubyte t = irt(e.type)
        if e.op == resolver.R_FIELDREF {
            uword pr
            long off
            pr, off = field_address(e)
            uword fr = ir.new_reg(t)
            void ir.emit_rp(chunk, ir.OP_LOADI, t, fr, pr, off)
            return fr, t
        }
        ^^symtab.Sym s = e.extra
        if s == 0
            return 0, t
        when s.kind {
            symtab.K_VAR, symtab.K_PARAM, symtab.K_MEMVAR -> {
                uword r = ir.new_reg(t)
                ^^ubyte vs
                long va
                vs, va = var_ref(s)
                if types.is_array(s.type) or s.type == types.T_STR {
                    ; arrays and strings are used by their address
                    if is_split(s)
                        vs = split_name(s, false)       ; a split array's address is that of its low bytes
                    if vs == 0
                        void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_POINTER, r, va)
                    else
                        void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, r, vs, 0)
                    return r, ir.T_POINTER
                }
                void ir.emit_rm(chunk, ir.OP_LOADM, t, r, vs, va)
                return r, t
            }
            symtab.K_SUB, symtab.K_LABEL, symtab.K_BLOCK -> {
                uword ar = ir.new_reg(ir.T_POINTER)
                void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, ar, sym_name(s), 0)
                return ar, ir.T_POINTER
            }
            symtab.K_CONST -> {
                ; a constant that is an address the assembler works out (memory(), a string,
                ; &something): its initializer, wherever the name is used
                if s.decl != 0 and s.decl.kind == ast.N_VARDECL and s.decl.b != 0 {
                    uword cr
                    ubyte ct2
                    cr, ct2 = expression(s.decl.b)
                    return convert(cr, ct2, t, false), t
                }
                unsupported(e, "identifier kind")
                return ir.new_reg(t), t
            }
            else -> {
                unsupported(e, "identifier kind")
                return ir.new_reg(t), t
            }
        }
    }

    sub addressof(^^ast.Node e) -> uword, ubyte {
        uword r = ir.new_reg(ir.T_POINTER)
        ^^ast.Node target = e.a
        if target.kind == ast.N_IDENT and target.op != resolver.R_FIELDREF and target.extra != 0 {
            ^^symtab.Sym s = target.extra
            if s.kind == symtab.K_CONST and e.b != 0 {
                ; &constant[i]: the constant is an address (a number, or a pointer with a type)
                bool cok
                quad cbase
                cok, cbase = typer.const_eval(target)
                if cok {
                    long csize = 1
                    if types.is_pointer(s.type) {
                        csize = types.size_of(types.index_elem(s.type))
                        if csize == 0
                            csize = 1
                    }
                    void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_POINTER, r, cbase)
                    bool iok
                    quad ci0
                    iok, ci0 = typer.const_eval(e.b)
                    if iok {
                        if ci0 != 0
                            void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, r, ci0 * csize)
                    }
                    else {
                        uword cxr
                        ubyte cxt
                        cxr, cxt = expression(e.b)
                        cxr = convert(cxr, cxt, ir.T_POINTER, types.is_signed(e.b.type))
                        if csize > 1
                            void ir.emit_ri(chunk, scale_op(), address_irt, cxr, csize)
                        void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, r, cxr)
                    }
                    return r, ir.T_POINTER
                }
            }
            if s.kind == symtab.K_MEMVAR {
                bool ok
                quad addr
                ok, addr = typer.const_eval(s.decl.b)
                if ok {
                    void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_POINTER, r, addr)
                    if e.b != 0 {
                        ; an element of a memory mapped array
                        long msize = types.size_of(types.index_elem(s.type))
                        if msize == 0
                            msize = 1
                        bool mok
                        quad mci
                        mok, mci = typer.const_eval(e.b)
                        if mok {
                            if mci != 0
                                void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, r, mci * msize)
                        }
                        else {
                            uword mxr
                            ubyte mxt
                            mxr, mxt = expression(e.b)
                            mxr = convert(mxr, mxt, ir.T_POINTER, types.is_signed(e.b.type))
                            if msize > 1
                                void ir.emit_ri(chunk, scale_op(), address_irt, mxr, msize)
                            void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, r, mxr)
                        }
                    }
                    return r, ir.T_POINTER
                }
            }
            if e.b != 0 and (types.is_pointer(s.type) or (s.kind == symtab.K_PARAM and s.type == types.T_STR)
                    or (not types.is_array(s.type) and s.type != types.T_STR)) {
                ; &pointer[i]: where the pointer points, plus the scaled index (not the
                ; address of the pointer variable itself, which is what an array's name is)
                uword pvr
                ubyte pvt
                pvr, pvt = identifier(target)
                pvr = convert(pvr, pvt, ir.T_POINTER, false)
                void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_POINTER, r, pvr)
                long psize = types.size_of(types.index_elem(s.type))
                if psize == 0
                    psize = 1
                bool pok
                quad pci
                pok, pci = typer.const_eval(e.b)
                if pok {
                    if pci != 0
                        void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, r, pci * psize)
                }
                else {
                    uword pxr
                    ubyte pxt
                    pxr, pxt = expression(e.b)
                    pxr = convert(pxr, pxt, ir.T_POINTER, types.is_signed(e.b.type))
                    if psize > 1
                        void ir.emit_ri(chunk, scale_op(), address_irt, pxr, psize)
                    void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, r, pxr)
                }
                return r, ir.T_POINTER
            }
            long off = 0
            if e.b != 0 {
                bool ok2
                quad ci
                ok2, ci = typer.const_eval(e.b)
                if ok2 {
                    long esize = types.size_of(types.index_elem(s.type))
                    if esize == 0
                        esize = 1
                    off = (ci as long) * esize
                }
                else {
                    ; &array[i]: the address plus the scaled index
                    void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, r, sym_name(s), 0)
                    uword ixr
                    ubyte ixt
                    ixr, ixt = expression(e.b)
                    ixr = convert(ixr, ixt, ir.T_POINTER, false)
                    long esize2 = types.size_of(types.index_elem(s.type))
                    if esize2 > 1
                        void ir.emit_ri(chunk, scale_op(), address_irt, ixr, esize2)
                    void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, r, ixr)
                    return r, ir.T_POINTER
                }
            }
            if is_split(s) {
                if e.b != 0
                    unsupported(e, "address of a split array element")
                void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, r, split_name(s, false), 0)
                return r, ir.T_POINTER
            }
            void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, r, sym_name(s), off)
            return r, ir.T_POINTER
        }
        if target.kind == ast.N_IDENT and target.op == resolver.R_FIELDREF {
            uword pr
            long foff
            pr, foff = field_address(target)
            if e.b != 0 {
                ; &p.field[i]: an element of the field.  A field that is a pointer is
                ; followed first; one that is an array is where the elements are.
                uword er = ir.new_reg(ir.T_POINTER)
                if types.is_pointer(target.type) or (not types.is_array(target.type) and target.type != types.T_STR)
                    void ir.emit_rp(chunk, ir.OP_LOADI, ir.T_POINTER, er, pr, foff)
                else {
                    void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_POINTER, er, pr)
                    if foff != 0
                        void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, er, foff)
                }
                long fsize = types.size_of(types.index_elem(target.type))
                if fsize == 0
                    fsize = 1
                bool fok
                quad fci
                fok, fci = typer.const_eval(e.b)
                if fok {
                    if fci != 0
                        void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, er, fci * fsize)
                }
                else {
                    uword fxr
                    ubyte fxt
                    fxr, fxt = expression(e.b)
                    fxr = convert(fxr, fxt, ir.T_POINTER, types.is_signed(e.b.type))
                    if fsize > 1
                        void ir.emit_ri(chunk, scale_op(), address_irt, fxr, fsize)
                    void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, er, fxr)
                }
                return er, ir.T_POINTER
            }
            if foff != 0
                void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, pr, foff)
            return pr, ir.T_POINTER
        }
        if e.b != 0 {
            ; &number[i] (a constant that the front end has put its value for)
            bool nok
            quad nbase
            nok, nbase = typer.const_eval(target)
            if nok {
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_POINTER, r, nbase)
                uword nxr
                ubyte nxt
                nxr, nxt = expression(e.b)
                nxr = convert(nxr, nxt, ir.T_POINTER, types.is_signed(e.b.type))
                void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, r, nxr)
                return r, ir.T_POINTER
            }
        }
        unsupported(e, "address-of operand")
        return r, ir.T_POINTER
    }

    ; the multiplication that scales an index to an address offset: the virtual machine
    ; only multiplies longs as signed numbers, and upstream writes muls.l too
    sub scale_op() -> ubyte {
        if address_irt == ir.T_LONG
            return ir.OP_MULS
        return ir.OP_MUL
    }

    sub is_struct(uword t) -> bool {
        if t == 0
            return false
        ^^types.Type tt = types.get(t)
        return tt.base == types.T_STRUCT
    }

    ; target = value for whole struct instances: a memory copy, as a call of sys.memcopy
    ; like upstream makes of it.  A struct valued expression is its address here.
    sub struct_copy(^^ast.Node target, ^^ast.Node value) {
        ^^symtab.Sym sysblock = symtab.find_in(symtab.global, strtab.intern_cstr("sys"))
        ^^symtab.Sym copier = 0
        if sysblock != 0 and sysblock.inner != 0
            copier = symtab.find_in(sysblock.inner, strtab.intern_cstr("memcopy"))
        if copier == 0 or not is_struct(value.type) {
            unsupported(target, "struct assignment")
            return
        }
        ^^ast.Node callee = mem.alloc(sizeof(ast.Node))
        callee.kind = ast.N_IDENT
        callee.line = target.line
        callee.col = target.col
        callee.file = target.file
        callee.name = strtab.intern_cstr("sys.memcopy")
        callee.extra = copier
        ^^ast.Node src = struct_operand(value)
        ^^ast.Node dst = struct_operand(target)
        ^^ast.Node count = mem.alloc(sizeof(ast.Node))
        count.kind = ast.N_INT
        count.line = target.line
        count.col = target.col
        count.file = target.file
        count.value = types.size_of(target.type)
        count.type = types.T_UWORD
        src.next = dst
        dst.next = count
        ^^ast.Node copycall = mem.alloc(sizeof(ast.Node))
        copycall.kind = ast.N_CALL
        copycall.line = target.line
        copycall.col = target.col
        copycall.file = target.file
        copycall.a = callee
        copycall.b = src
        uword unused_r
        ubyte unused_t
        unused_r, unused_t = call_expr(copycall)
    }

    ; a copy of a struct valued node whose expression is the struct's address: p^^ is p
    sub struct_operand(^^ast.Node n) -> ^^ast.Node {
        ^^ast.Node from = n
        if n.kind == ast.N_DEREF
            from = n.a
        ^^ast.Node copy = mem.alloc(sizeof(ast.Node))
        mem.copy(from, copy, sizeof(ast.Node))
        copy.next = 0
        return copy
    }

    sub indexed(^^ast.Node e) -> uword, ubyte {
        ubyte t = irt(e.type)
        ^^ast.Node base = e.a
        ^^ast.Node index = e.b
        if index == 0 or index.next != 0 {
            unsupported(e, "2D array indexing")
            return ir.new_reg(t), t
        }
        long elemsize = types.size_of(e.type)
        if elemsize == 0
            elemsize = 1
        if is_struct(e.type) {
            ; an element of an array of struct instances (or of what a struct pointer points at)
            ; is not a value that fits a register: this is its address, for the field access,
            ; address-of or copy that it is part of
            uword er
            long eoff
            er, eoff = indexed_address(base, index, elemsize)
            if eoff != 0 {
                uword er2 = ir.new_reg(ir.T_POINTER)
                void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_POINTER, er2, er)
                void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, er2, eoff)
                er = er2
            }
            return er, ir.T_POINTER
        }
        ^^symtab.Sym s = 0
        if base.kind == ast.N_IDENT and base.op != resolver.R_FIELDREF
            s = base.extra
        bool ok
        quad ci
        if is_split(s) {
            uword sw = split_load(s, index)
            ubyte swt = ir.T_WORD
            return sw, swt
        }
        uword r = ir.new_reg(t)
        if s != 0 and (s.kind == symtab.K_VAR or s.kind == symtab.K_MEMVAR or s.kind == symtab.K_PARAM) and (types.is_array(s.type) or s.type == types.T_STR) {
            ^^ubyte vs
            long va
            vs, va = var_ref(s)
            ok, ci = typer.const_eval(index)
            if ok {
                void ir.emit_rm(chunk, ir.OP_LOADM, t, r, vs, va + (ci as long) * elemsize)
                return r, t
            }
            uword ixr = index_register(index)
            void ir.emit_rmx(chunk, ir.OP_LOADX, t, r, vs, va, ixr, elemsize as ubyte)
            return r, t
        }
        uword pr
        long off
        pr, off = indexed_address(base, index, elemsize)
        void ir.emit_rp(chunk, ir.OP_LOADI, t, r, pr, off)
        return r, t
    }

    sub unary(^^ast.Node e) -> uword, ubyte {
        ubyte t = irt(e.type)
        uword r
        ubyte rt
        r, rt = expression(e.a)
        when e.op {
            token.T_MINUS -> void ir.emit_r(chunk, ir.OP_NEG, t, r)
            token.T_TILDE -> void ir.emit_r(chunk, ir.OP_INV, t, r)
            token.T_KW_NOT -> void ir.emit_ri(chunk, ir.OP_XOR, ir.T_BYTE, r, 1)
        }
        return r, t
    }

    ; "x in a to b" becomes "x >= a and x <= b" ("not in": "x < a or x > b"),
    ; rewritten in place, as upstream desugars it; x is evaluated twice
    sub range_test(^^ast.Node e) {
        if e.kind != ast.N_BINARY or e.b == 0 or e.b.kind != ast.N_RANGE or e.b.c != 0
            return
        if e.op != token.T_KW_IN and e.op != parser.OP_NOT_IN
            return
        bool negate = e.op == parser.OP_NOT_IN
        ^^ast.Node low = e.b.a
        ^^ast.Node high = e.b.b
        if e.b.op == token.T_KW_DOWNTO {
            low = e.b.b
            high = e.b.a
        }
        ^^ast.Node left = mem.alloc(sizeof(ast.Node))
        ^^ast.Node right = mem.alloc(sizeof(ast.Node))
        mem.copy(e, left, sizeof(ast.Node))
        mem.copy(e, right, sizeof(ast.Node))
        left.next = 0
        right.next = 0
        left.b = low
        right.b = high
        left.type = types.T_BOOL
        right.type = types.T_BOOL
        if negate {
            left.op = token.T_LT
            right.op = token.T_GT
            e.op = token.T_KW_OR
        }
        else {
            left.op = token.T_GE
            right.op = token.T_LE
            e.op = token.T_KW_AND
        }
        e.a = left
        e.b = right
        e.type = types.T_BOOL
    }

    sub binary(^^ast.Node e) -> uword, ubyte {
        range_test(e)
        ubyte op = e.op
        if op == token.T_KW_AND or op == token.T_KW_OR {
            uword lgr
            ubyte lgt
            lgr, lgt = logical(e)
            return lgr, lgt
        }
        if is_comparison(op) {
            ; a comparison as a value: 1 or 0 through branches
            ^^ubyte yes = new_label()
            ^^ubyte done = new_label()
            uword br = ir.new_reg(ir.T_BYTE)
            compare_branch(e, yes, 0)
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, br, 0)
            jump(done)
            label(yes)
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, br, 1)
            label(done)
            return br, ir.T_BYTE
        }
        if op == token.T_KW_IN or op == parser.OP_NOT_IN {
            if op == token.T_KW_IN
                return containment(e), ir.T_BYTE
            uword cr = containment(e)
            void ir.emit_ri(chunk, ir.OP_XOR, ir.T_BYTE, cr, 1)
            return cr, ir.T_BYTE
        }
        ubyte t = irt(e.type)
        if types.is_pointer(e.a.type) and (op == token.T_PLUS or op == token.T_MINUS) and not types.is_pointer(e.b.type)
            return pointer_arith(e), ir.T_POINTER
        if types.is_pointer(e.b.type) and op == token.T_PLUS and not types.is_pointer(e.a.type)
            return pointer_arith(e), ir.T_POINTER
        bool signed = types.is_signed(e.type)
        uword lr
        ubyte lt
        lr, lt = expression(e.a)
        lr = convert(lr, lt, t, types.is_signed(e.a.type))
        ; a constant right operand is an immediate
        bool ok
        quad cv
        ok, cv = typer.const_eval(e.b)
        if ok and t != ir.T_FLOAT and immediate_apply(op, lr, t, cv, signed)
            return lr, t
        uword rr
        ubyte rt
        rr, rt = expression(e.b)
        ; the shift count stays a byte
        if op == token.T_SHL or op == token.T_SHR
            rr = convert(rr, rt, ir.T_BYTE, false)
        else
            rr = convert(rr, rt, t, types.is_signed(e.b.type))
        uword bres = binary_op(op, lr, t, rr, rt, t, signed, e)
        ubyte bt = t
        if op == token.T_MINUS and types.is_pointer(e.a.type) and types.is_pointer(e.b.type) {
            ; the difference of two pointers counts elements, not bytes
            long psize = types.size_of(types.elem_of(e.a.type))
            if psize > 1 {
                ubyte shift = 0
                long power = 1
                while power < psize {
                    power *= 2
                    shift++
                }
                if power == psize
                    void ir.emit_ri(chunk, ir.OP_ASRI, t, bres, shift)
                else
                    void ir.emit_ri(chunk, ir.OP_DIVS, t, bres, psize)
            }
        }
        return bres, bt
    }

    ; The word that a subroutine called through a pointer returned: it is where a
    ; word result is by the target's convention (A and Y on the 6502: slot 4).
    sub called_value() -> uword {
        uword r = ir.new_reg(ir.T_WORD)
        ubyte slot = 10
        if split_words
            slot = 4
        void ir.emit_rs(chunk, ir.OP_LOADHR, ir.T_WORD, r, slot)
        return r
    }

    ; p + n and p - n: the offset scaled by the element size
    sub pointer_arith(^^ast.Node e) -> uword {
        ^^ast.Node pe = e.a
        ^^ast.Node oe = e.b
        if not types.is_pointer(pe.type) {
            pe = e.b
            oe = e.a
        }
        long esize = types.size_of(types.elem_of(pe.type))
        if esize == 0
            esize = 1
        uword pr
        ubyte pt
        pr, pt = expression(pe)
        pr = convert(pr, pt, ir.T_POINTER, false)
        bool ok
        quad cv
        ok, cv = typer.const_eval(oe)
        if ok and plain(ir.T_POINTER) == ir.T_WORD {
            ; the address of a name and a constant: one address
            ^^ir.Instr src = chunk.last
            if src != 0 and src.op == ir.OP_LOAD and src.sym != 0 and src.r1 == pr and cv >= 0 and cv * esize <= 65535 {
                long moved = src.offset
                if e.op == token.T_PLUS
                    moved += (cv * esize) as long
                else
                    moved -= (cv * esize) as long
                if moved >= 0 and moved <= 65535 {
                    src.offset = moved
                    return pr
                }
            }
        }
        uword res = ir.new_reg(ir.T_POINTER)
        void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_POINTER, res, pr)
        if ok {
            if e.op == token.T_PLUS
                void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, res, cv * esize)
            else
                void ir.emit_ri(chunk, ir.OP_SUB, ir.T_POINTER, res, cv * esize)
            return res
        }
        uword orr
        ubyte ot
        orr, ot = expression(oe)
        orr = convert(orr, ot, ir.T_POINTER, types.is_signed(oe.type))
        if esize != 1
            void ir.emit_ri(chunk, scale_op(), address_irt, orr, esize)
        if e.op == token.T_PLUS
            void ir.emit_rr(chunk, ir.OP_ADDR, ir.T_POINTER, res, orr)
        else
            void ir.emit_rr(chunk, ir.OP_SUBR, ir.T_POINTER, res, orr)
        return res
    }

    ; lr = lr op constant, when the operator has an immediate form
    sub immediate_apply(ubyte op, uword lr, ubyte t, quad cv, bool signed) -> bool {
        ubyte iop = immediate_op(op, signed)
        if iop == ir.OP_NOP
            return false
        if (op == token.T_SHL or op == token.T_SHR) and cv == 1 {
            ; a single shift sets the carry, which if_cs may test
            if op == token.T_SHL
                void ir.emit_r(chunk, ir.OP_LSL, t, lr)
            else if signed
                void ir.emit_r(chunk, ir.OP_ASR, t, lr)
            else
                void ir.emit_r(chunk, ir.OP_LSR, t, lr)
        }
        else if op == token.T_SHL or op == token.T_SHR
            void ir.emit_ri(chunk, iop, t, lr, cv)
        else if t != ir.T_FLOAT and (op == token.T_PLUS or op == token.T_MINUS) and truncate(cv, t) == 0 {
            ; nothing to add
        }
        else if t != ir.T_FLOAT and (op == token.T_PLUS or op == token.T_MINUS) and add_to_previous(op, lr, t, cv) {
            ; (x + 6 - 1: one addition)
        }
        else if t != ir.T_FLOAT and op == token.T_PLUS and cv == 1
            void ir.emit_r(chunk, ir.OP_INC, t, lr)
        else if t != ir.T_FLOAT and op == token.T_MINUS and cv == 1
            void ir.emit_r(chunk, ir.OP_DEC, t, lr)
        else if t != ir.T_FLOAT and op == token.T_STAR and cv == 2
            void ir.emit_r(chunk, ir.OP_LSL, t, lr)         ; (times two is one shift)
        else if t != ir.T_FLOAT and op == token.T_STAR and cv == 1 {
        }
        else
            void ir.emit_ri(chunk, iop, t, lr, truncate(cv, t))
        return true
    }

    ; A constant added to (or taken from) the register that the instruction just written
    ; added a constant to, or loaded an address into: the two become one.
    sub add_to_previous(ubyte op, uword lr, ubyte t, quad cv) -> bool {
        ^^ir.Instr last = chunk.last
        if last == 0 or last.r1 != lr
            return false
        ubyte pt = plain(t)
        if (pt != ir.T_BYTE and pt != ir.T_WORD) or plain(last.type) != pt
            return false
        quad delta = cv
        if op == token.T_MINUS
            delta = -cv
        if last.op == ir.OP_LOAD and last.sym != 0 {
            ; the address of a name: the constant goes into it
            long moved = last.offset + (delta as long)
            if moved < 0 or moved > 65535 or delta < -65535 or delta > 65535
                return false
            last.offset = moved
            return true
        }
        if last.sym != 0
            return false
        when last.op {
            ir.OP_ADD -> delta += last.value
            ir.OP_SUB -> delta -= last.value
            ir.OP_INC -> delta += 1
            ir.OP_DEC -> delta -= 1
            else -> return false
        }
        quad up = truncate(delta, t)
        quad down = truncate(-delta, t)
        if up == 0
            return false            ; (nothing is left: rare, and written as it stands)
        last.value = 0
        last.mode = ir.M_R
        if up == 1
            last.op = ir.OP_INC
        else if down == 1
            last.op = ir.OP_DEC
        else {
            last.mode = ir.M_RI
            if up <= down {
                last.op = ir.OP_ADD
                last.value = up
            }
            else {
                last.op = ir.OP_SUB
                last.value = down
            }
        }
        return true
    }

    sub immediate_op(ubyte op, bool signed) -> ubyte {
        when op {
            token.T_PLUS -> return ir.OP_ADD
            token.T_MINUS -> return ir.OP_SUB
            token.T_STAR -> {
                if signed
                    return ir.OP_MULS
                return ir.OP_MUL
            }
            token.T_SLASH -> {
                if signed
                    return ir.OP_DIVS
                return ir.OP_DIV
            }
            token.T_PERCENT -> {
                if signed
                    return ir.OP_MODS
                return ir.OP_MOD
            }
            token.T_AMP -> return ir.OP_AND
            token.T_PIPE -> return ir.OP_OR
            token.T_CARET -> return ir.OP_XOR
            token.T_SHL -> return ir.OP_LSLI
            token.T_SHR -> {
                if signed
                    return ir.OP_ASRI
                return ir.OP_LSRI
            }
        }
        return ir.OP_NOP
    }

    ; lr = lr op rr, both already of type t
    sub binary_op(ubyte op, uword lr, ubyte lt, uword rr, ubyte rt, ubyte t, bool signed, ^^ast.Node at) -> uword {
        ubyte iop = ir.OP_NOP
        when op {
            token.T_PLUS -> iop = ir.OP_ADDR
            token.T_MINUS -> iop = ir.OP_SUBR
            token.T_STAR -> {
                iop = ir.OP_MULR
                if signed
                    iop = ir.OP_MULSR
            }
            token.T_SLASH -> {
                iop = ir.OP_DIVR
                if signed
                    iop = ir.OP_DIVSR
            }
            token.T_PERCENT -> {
                iop = ir.OP_MODR
                if signed
                    iop = ir.OP_MODSR
            }
            token.T_AMP -> iop = ir.OP_ANDR
            token.T_PIPE -> iop = ir.OP_ORR
            token.T_CARET -> iop = ir.OP_XORR
            token.T_SHL -> iop = ir.OP_LSLN
            token.T_SHR -> {
                iop = ir.OP_LSRN
                if signed
                    iop = ir.OP_ASRN
            }
            token.T_KW_AND -> iop = ir.OP_ANDR
            token.T_KW_OR -> iop = ir.OP_ORR
            token.T_KW_XOR -> iop = ir.OP_XORR
            else -> {
                unsupported(at, "binary operator")
                return lr
            }
        }
        ^^ir.Instr i = ir.emit_rr(chunk, iop, t, lr, rr)
        if op == token.T_SHL or op == token.T_SHR
            i.t2 = ir.T_BYTE
        return lr
    }

    ; x in "abc" / x in [1,2,3]: compared with each value; x in array: a syscall
    sub containment(^^ast.Node e) -> uword {
        ^^ast.Node needle = e.a
        ^^ast.Node hay = e.b
        uword nr
        ubyte nt
        nr, nt = expression(needle)
        uword res = ir.new_reg(ir.T_BYTE)
        if hay.kind == ast.N_STR or hay.kind == ast.N_ARRAYLIT {
            ^^ubyte found = new_label()
            ^^ubyte done = new_label()
            if hay.kind == ast.N_STR {
                typer.decode_literal(hay)
                ^^ubyte bytes = hay.extra
                long i = 0
                while i < hay.value {
                    void ir.emit_ri(chunk, ir.OP_CMPI, nt, nr, bytes[i])
                    void ir.emit_t(chunk, ir.OP_BSTEQ, found)
                    i++
                }
            }
            else {
                ^^ast.Node v = hay.a
                bool ok
                quad cv
                while v != 0 {
                    if nt == ir.T_FLOAT {
                        ; floats compare as floats
                        uword fvr
                        ubyte fvt
                        fvr, fvt = expression(v)
                        fvr = convert(fvr, fvt, ir.T_FLOAT, true)
                        uword fcr = ir.new_reg(ir.T_BYTE)
                        ^^ir.Instr ffc = ir.emit_rrr(chunk, ir.OP_FCOMP, ir.T_FLOAT, fcr, nr, fvr)
                        ffc.t1 = ir.T_BYTE
                        void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, fcr, 0)
                        void ir.emit_t(chunk, ir.OP_BSTEQ, found)
                        v = v.next
                        continue
                    }
                    ok, cv = typer.const_eval(v)
                    if ok {
                        void ir.emit_ri(chunk, ir.OP_CMPI, nt, nr, truncate(cv, nt))
                        void ir.emit_t(chunk, ir.OP_BSTEQ, found)
                    }
                    v = v.next
                }
            }
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, res, 0)
            jump(done)
            label(found)
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, res, 1)
            label(done)
            return res
        }
        ; an array or string variable: the virtual machine's search syscalls
        uword hr
        ubyte ht
        hr, ht = expression(hay)
        hr = convert(hr, ht, ir.T_POINTER, false)
        ^^ubyte number = "$100e"
        ^^ir.Instr sc
        if hay.type == types.T_STR {
            sc = ir.emit_syscall(chunk, number)
            ir.add_arg(sc, ir.new_arg(0, nr, ir.T_BYTE))
            ir.add_arg(sc, ir.new_arg(0, hr, address_irt))
        }
        else {
            ubyte et = irt(types.elem_of(hay.type))
            when et {
                ir.T_BYTE -> number = "$100f"
                ir.T_WORD -> number = "$1010"
                ir.T_LONG -> number = "$101b"
                ir.T_QUAD -> number = "$101c"
                else -> number = "$1011"
            }
            if hay.kind == ast.N_IDENT and hay.op != resolver.R_FIELDREF and is_split(hay.extra)
                number = "$101a"            ; the search through a split word array
            else if split_words and (et == ir.T_LONG or et == ir.T_FLOAT) {
                ; the 6502's library has no search for these: a loop over the elements
                long count = typer.known_length(hay)
                ^^ubyte sfound = new_label()
                ^^ubyte sdone = new_label()
                ^^ubyte stop = new_label()
                uword want = convert(nr, nt, et, types.is_signed(needle.type))
                if count > 0 {
                    uword left = ir.new_reg(ir.T_WORD)
                    void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_WORD, left, count)
                    label(stop)
                    uword elem = ir.new_reg(et)
                    void ir.emit_rp(chunk, ir.OP_LOADI, et, elem, hr, 0)
                    if et == ir.T_FLOAT {
                        uword scr = ir.new_reg(ir.T_BYTE)
                        ^^ir.Instr sfc = ir.emit_rrr(chunk, ir.OP_FCOMP, ir.T_FLOAT, scr, want, elem)
                        sfc.t1 = ir.T_BYTE
                        void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, scr, 0)
                    }
                    else
                        void ir.emit_rr(chunk, ir.OP_CMP, et, want, elem)
                    void ir.emit_t(chunk, ir.OP_BSTEQ, sfound)
                    void ir.emit_ri(chunk, ir.OP_ADD, ir.T_POINTER, hr, types.size_of(types.elem_of(hay.type)))
                    void ir.emit_r(chunk, ir.OP_DEC, ir.T_WORD, left)
                    void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_WORD, left, 0)
                    void ir.emit_t(chunk, ir.OP_BSTNE, stop)
                }
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, res, 0)
                jump(sdone)
                label(sfound)
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, res, 1)
                label(sdone)
                return res
            }
            uword lr = ir.new_reg(ir.T_WORD)
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_WORD, lr, typer.known_length(hay))
            sc = ir.emit_syscall(chunk, number)
            ir.add_arg(sc, ir.new_arg(0, convert(nr, nt, et, types.is_signed(needle.type)), et))
            ir.add_arg(sc, ir.new_arg(0, hr, address_irt))
            ir.add_arg(sc, ir.new_arg(0, lr, ir.T_WORD))
        }
        ir.add_result(sc, ir.new_arg(0, res, ir.T_BYTE))
        return res
    }

    ; and/or as values, with short circuit evaluation
    ; does a boolean expression branch anyway (a comparison somewhere in it)?
    sub has_comparison(^^ast.Node e) -> bool {
        if e.kind == ast.N_BINARY {
            if is_comparison(e.op)
                return true
            if e.op == token.T_KW_AND or e.op == token.T_KW_OR
                return has_comparison(e.a) or has_comparison(e.b)
            return false
        }
        if e.kind == ast.N_UNARY and e.op == token.T_KW_NOT
            return has_comparison(e.a)
        return false
    }

    sub logical(^^ast.Node e) -> uword, ubyte {
        ^^ubyte done = new_label()
        uword r = ir.new_reg(ir.T_BYTE)
        if has_comparison(e) {
            ; the whole expression as branches, and one value at the end (not a 0 or 1
            ; for every comparison in it)
            ^^ubyte no = new_label()
            condition(e, 0, no)
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, r, 1)
            jump(done)
            label(no)
            void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, r, 0)
            label(done)
            return r, ir.T_BYTE
        }
        uword lr
        ubyte lt
        lr, lt = expression(e.a)
        void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_BYTE, r, lr)
        void ir.emit_ri(chunk, ir.OP_CMPI, ir.T_BYTE, r, 0)
        if e.op == token.T_KW_AND
            void ir.emit_t(chunk, ir.OP_BSTEQ, done)
        else
            void ir.emit_t(chunk, ir.OP_BSTNE, done)
        uword rr
        ubyte rt
        rr, rt = expression(e.b)
        void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_BYTE, r, rr)
        label(done)
        return r, ir.T_BYTE
    }

    sub ifexpr(^^ast.Node e) -> uword, ubyte {
        ubyte t = irt(e.type)
        uword r = ir.new_reg(t)
        ^^ubyte elselabel = new_label()
        ^^ubyte done = new_label()
        condition(e.a, 0, elselabel)
        uword tr
        ubyte tt
        tr, tt = expression(e.b)
        void ir.emit_rr(chunk, ir.OP_LOADR, t, r, convert(tr, tt, t, types.is_signed(e.b.type)))
        jump(done)
        label(elselabel)
        uword fr
        ubyte ft
        fr, ft = expression(e.c)
        void ir.emit_rr(chunk, ir.OP_LOADR, t, r, convert(fr, ft, t, types.is_signed(e.c.type)))
        label(done)
        return r, t
    }

    ; ---- calls ----

    ; ---- calls of asmsubs and extsubs that pass values in CPU registers ----

    sub uses_registers(^^ast.Node d) -> bool {
        if d.kind != ast.N_ASMSUB and d.kind != ast.N_EXTSUB
            return false
        if d.kind == ast.N_EXTSUB and d.c != 0
            return true             ; called by its address
        ^^ast.Node p = d.a
        while p != 0 {
            if p.b != 0
                return true
            p = p.next
        }
        ^^ast.Node r = d.b
        while r != 0 {
            if r.b != 0 and r.op != token.T_KW_VOID
                return true
            r = r.next
        }
        return false
    }

    ; Where a register name puts a value: a calling convention slot (A=0,
    ; X, Y, AX, AY, XY, FAC1, FAC2; from 10 the 68000's), a status flag (ir.SLOT_FLAGS + Pc, Pz,
    ; Pv, Pn), or 255 for the virtual registers R0..R15 and their pairs.
    sub register_slot(^^ubyte r) -> ubyte {
        if r == 0
            return 255
        if strings.compare(r, "A") == 0
            return 0
        if strings.compare(r, "X") == 0
            return 1
        if strings.compare(r, "Y") == 0
            return 2
        if strings.compare(r, "AX") == 0
            return 3
        if strings.compare(r, "AY") == 0
            return 4
        if strings.compare(r, "XY") == 0
            return 5
        if strings.compare(r, "FAC1") == 0
            return 6
        if strings.compare(r, "FAC2") == 0
            return 7
        ; the 68000: D0-D7 are 10-17, A0-A6 are 18-24, FP0-FP7 are 25-32
        if r[1] >= '0' and r[1] <= '7' and r[2] == 0 {
            if r[0] == 'D'
                return 10 + (r[1] - '0')
            if r[0] == 'A' and r[1] != '7'
                return 18 + (r[1] - '0')
        }
        if r[0] == 'F' and r[1] == 'P' and r[2] >= '0' and r[2] <= '7' and r[3] == 0
            return 25 + (r[2] - '0')
        if strings.compare(r, "Pc") == 0
            return ir.SLOT_FLAGS
        if strings.compare(r, "Pz") == 0
            return ir.SLOT_FLAGS + 1
        if strings.compare(r, "Pv") == 0
            return ir.SLOT_FLAGS + 2
        if strings.compare(r, "Pn") == 0
            return ir.SLOT_FLAGS + 3
        return 255
    }

    ; "cx16.r5" for the virtual register R5; 0 for anything else
    sub virtual_register(^^ubyte r) -> ^^ubyte {
        if r == 0 or (r[0] != 'R' and r[0] != 'r') or r[1] == 0
            return 0
        long k = 1
        while r[k] >= '0' and r[k] <= '9'
            k++
        if k == 1 or k > 3
            return 0
        if r[k] != 0 {
            ; a pair for a long, "R0R1": it begins in the first of the two
            if r[k] != 'R' and r[k] != 'r'
                return 0
            long second = k + 1
            while r[second] >= '0' and r[second] <= '9'
                second++
            if second == k + 1 or r[second] != 0
                return 0
        }
        buf.clear(nb)
        buf.add_str(nb, "cx16.r")
        buf.add_bytes(nb, r + 1, k - 1)
        return intern_nb()
    }

    ^^ir.Instr last_asm_call = 0        ; the call asm_call() emitted last, for its result list

    ; Calls an asmsub or extsub.  Arguments go where the declaration says:
    ; a constant for A, X or Y is passed as an immediate, as upstream does.
    ; mode 0: no result wanted, 1: the single result's register is returned
    ; (a status flag is turned into 0 or 1), 2: all results are listed.
    ; before a call of sys.exit (or exit2, exit3): the pending defers of all callers run first
    sub exit_unwinds(^^symtab.Sym s) {
        if program_defers and buf.bytes_equal(sym_name(s), "sys.exit", 8)
            void ir.emit_call(chunk, defer_unwind_name)
    }

    sub asm_call(^^ast.Node e, ubyte mode) -> uword {
        ^^symtab.Sym s = e.a.extra
        ^^ast.Node d = s.decl
        exit_unwinds(s)
        ^^ir.Arg first = 0
        ^^ir.Arg last = 0
        ^^ast.Node a = e.b
        ^^ast.Node p = d.a
        bool ok
        quad cv
        while a != 0 and p != 0 {
            ^^symtab.Sym ps = p.extra
            uword ptype = 0
            if ps != 0
                ptype = ps.type
            ubyte pt = irt(ptype)
            ^^ubyte regname = 0
            if p.b != 0
                regname = p.b.name
            ubyte slot = register_slot(regname)
            ^^ir.Arg arg = 0
            if slot <= 2 and pt != ir.T_FLOAT {
                ok, cv = typer.const_eval(a)
                if ok and a.kind != ast.N_ADDROF and a.kind != ast.N_CALL {
                    arg = ir.new_arg(0, 0, pt)
                    arg.value = truncate(cv, pt)
                }
            }
            if arg == 0 {
                uword r
                ubyte at
                r, at = expression(a)
                r = convert(r, at, pt, types.is_signed(a.type))
                arg = ir.new_arg(0, r, pt)
            }
            if slot != 255
                arg.slot = slot
            else {
                arg.name = virtual_register(regname)
                if arg.name == 0 and ps != 0
                    arg.name = plain_name(ps)
            }
            if first == 0
                first = arg
            else
                last.next = arg
            last = arg
            a = a.next
            p = p.next
        }
        ; the target: a name, an address, or a bank and an address
        ^^ir.Instr callins
        if d.kind == ast.N_EXTSUB and d.c != 0 {
            ok, cv = typer.const_eval(d.c)
            if not ok {
                unsupported(e, "extsub at a non-constant address")
                return 0
            }
            ^^ubyte address
            if cv < 0 {
                ; an offset into a 68000 library's jump table: in decimal, as upstream writes it
                buf.clear(nb)
                buf.add_long(nb, cv as long)
                address = intern_nb()
            }
            else
                address = number_text(cv)
            if d.d != 0 {
                quad bank
                ok, bank = typer.const_eval(d.d)
                ^^buf.Buf tb = buf.new(48)
                ubyte farop = ir.OP_CALLFAR
                if ok {
                    buf.add_byte(tb, '#')
                    ir.text = tb
                    ir.add_number(bank)
                }
                else {
                    ; the bank is in a variable: its value in a byte register
                    if d.d.kind != ast.N_IDENT or d.d.extra == 0 {
                        unsupported(e, "extsub bank expression")
                        return 0
                    }
                    ^^symtab.Sym banksym = d.d.extra
                    uword bankreg
                    ubyte bankt
                    if banksym.kind == symtab.K_SUB {
                        ; a bank selector subroutine: called with this extsub's call-site ID,
                        ; it returns the bank.  The call is made up as a syntax tree node.
                        ^^ast.Node idnode = mem.alloc(sizeof(ast.Node))
                        idnode.kind = ast.N_INT
                        idnode.line = e.line
                        idnode.col = e.col
                        idnode.file = e.file
                        idnode.value = call_site_id(d)
                        idnode.type = types.T_UBYTE
                        ^^ast.Node selcall = mem.alloc(sizeof(ast.Node))
                        selcall.kind = ast.N_CALL
                        selcall.line = e.line
                        selcall.col = e.col
                        selcall.file = e.file
                        selcall.a = d.d
                        selcall.b = idnode
                        selcall.type = types.T_UBYTE
                        bankreg, bankt = call_expr(selcall)
                    }
                    else if banksym.kind == symtab.K_VAR or banksym.kind == symtab.K_MEMVAR
                        bankreg, bankt = identifier(d.d)
                    else {
                        unsupported(e, "extsub bank expression")
                        return 0
                    }
                    bankreg = convert(bankreg, bankt, ir.T_BYTE, false)
                    buf.add_byte(tb, 'r')
                    buf.add_long(tb, bankreg)
                    buf.add_str(tb, ".b")
                    farop = ir.OP_CALLFARVB
                }
                buf.add_byte(tb, ',')
                buf.add_str(tb, address)
                buf.add_byte(tb, ',')
                buf.add_str(tb, sym_name(s))        ; the routine's name follows, as upstream writes it
                callins = ir.emit_call(chunk, strtab.intern(tb.data, tb.len as uword))
                callins.op = farop
            }
            else
                callins = ir.emit_call(chunk, address)
        }
        else
            callins = ir.emit_call(chunk, sym_name(s))
        callins.args = first
        last_asm_call = callins
        ^^ast.Node rt = typer.returns_of(s)
        if rt == 0 or (mode == 0 and rt.next == 0)
            return 0
        if mode == 2 or mode == 0 {
            ; (a statement call of a routine with several results lists them too, as upstream does)
            while rt != 0 {
                ubyte mt = irt(typer.return_type(rt))
                ^^ir.Arg mres = ir.new_arg(0, ir.new_reg(mt), mt)
                if rt.b != 0
                    mres.slot = register_slot(rt.b.name)
                ir.add_result(callins, mres)
                rt = rt.next
            }
            return 0
        }
        if rt.next != 0
            return 0
        ubyte t = irt(typer.return_type(rt))
        uword rr = ir.new_reg(t)
        ^^ir.Arg res = ir.new_arg(0, rr, t)
        ubyte rslot = 255
        if rt.b != 0
            rslot = register_slot(rt.b.name)
        res.slot = rslot
        ir.add_result(callins, res)
        if rslot == ir.SLOT_FLAGS {
            ; the carry flag as a value: rotate it into a zero
            void ir.emit_ri(chunk, ir.OP_LOAD, t, rr, 0)
            void ir.emit_r(chunk, ir.OP_ROXL, t, rr)
        }
        else if rslot > ir.SLOT_FLAGS and rslot != 255 {
            ^^ubyte isset = new_label()
            ^^ubyte fdone = new_label()
            when rslot - ir.SLOT_FLAGS {
                1 -> void ir.emit_t(chunk, ir.OP_BSTEQ, isset)
                2 -> void ir.emit_t(chunk, ir.OP_BSTVS, isset)
                else -> void ir.emit_t(chunk, ir.OP_BSTNEG, isset)
            }
            void ir.emit_ri(chunk, ir.OP_LOAD, t, rr, 0)
            jump(fdone)
            label(isset)
            void ir.emit_ri(chunk, ir.OP_LOAD, t, rr, 1)
            label(fdone)
        }
        return rr
    }

    ; The call-site ID of an extsub whose bank comes from a selector subroutine:
    ; its position among such extsubs in the program, as upstream numbers them
    ; (and lists them in the .bankedcalls file).
    sub call_site_id(^^ast.Node wanted) -> long {
        long id = 0
        ^^importer.Module m = importer.modules
        while m != 0 {
            ^^ast.Node b = m.tree.a
            while b != 0 {
                if b.kind == ast.N_BLOCK {
                    ^^ast.Node st = b.a
                    while st != 0 {
                        if st.kind == ast.N_EXTSUB and st.d != 0 and st.d.kind == ast.N_IDENT and st.d.extra != 0 {
                            ^^symtab.Sym sel = st.d.extra
                            if sel.kind == symtab.K_SUB {
                                if st == wanted
                                    return id
                                id++
                            }
                        }
                        st = st.next
                    }
                }
                b = b.next
            }
            m = m.next
        }
        return 0
    }

    ; The text of the .bankedcalls file: the extsubs whose bank a selector subroutine
    ; gives, with the ID each call hands it.  0 when the program has none.
    sub banked_calls() -> ^^buf.Buf {
        ^^buf.Buf out = 0
        ubyte pass
        long width = 4
        for pass in 0 to 1 {
            long id = 0
            ^^importer.Module m = importer.modules
            while m != 0 {
                ^^ast.Node b = m.tree.a
                while b != 0 {
                    if b.kind == ast.N_BLOCK {
                        ^^ast.Node st = b.a
                        while st != 0 {
                            if st.kind == ast.N_EXTSUB and st.d != 0 and st.d.kind == ast.N_IDENT and st.d.extra != 0 {
                                ^^symtab.Sym sel = st.d.extra
                                if sel.kind == symtab.K_SUB {
                                    long namelen = buf.cstr_len(b.name) + 1 + buf.cstr_len(st.name)
                                    if pass == 0 {
                                        if namelen > width
                                            width = namelen
                                    }
                                    else {
                                        long start = out.len
                                        buf.add_long(out, id)
                                        while out.len < start + 4
                                            buf.add_byte(out, ' ')
                                        bool aok
                                        quad address
                                        aok, address = typer.const_eval(st.c)
                                        buf.add_byte(out, '$')
                                        ^^ubyte hexdigits = "0123456789abcdef"
                                        byte shift
                                        for shift in 12 downto 0 step -4
                                            buf.add_byte(out, hexdigits[((address >> (shift as ubyte)) & 15) as ubyte])
                                        while out.len < start + 12
                                            buf.add_byte(out, ' ')
                                        buf.add_str(out, b.name)
                                        buf.add_byte(out, '.')
                                        buf.add_str(out, st.name)
                                        while out.len < start + 12 + width + 2
                                            buf.add_byte(out, ' ')
                                        ; the selector, with the block it is in
                                        if sel.scope != 0 and sel.scope.owner != 0 and sel.scope.owner.kind == ast.N_BLOCK {
                                            buf.add_str(out, sel.scope.owner.name)
                                            buf.add_byte(out, '.')
                                        }
                                        buf.add_str(out, sel.name)
                                        buf.add_byte(out, '\n')
                                    }
                                    id++
                                }
                            }
                            st = st.next
                        }
                    }
                    b = b.next
                }
                m = m.next
            }
            if id == 0
                return 0
            if pass == 0 {
                out = buf.new(1024)
                buf.add_str(out, "ID  Address Name")
                long pad = width + 2 - 4
                while pad > 0 {
                    buf.add_byte(out, ' ')
                    pad--
                }
                buf.add_str(out, "BankSelector\n")
                long dashes = out.len - 1
                while dashes > 0 {
                    buf.add_byte(out, '-')
                    dashes--
                }
                buf.add_byte(out, '\n')
            }
        }
        return out
    }

    sub call_expr(^^ast.Node e) -> uword, ubyte {
        ^^symtab.Sym s = e.a.extra
        ubyte t = irt(e.type)
        if s == 0
            return ir.new_reg(t), t
        if s.kind == symtab.K_BUILTIN {
            uword br
            ubyte bt
            br, bt = builtin(e, s.name)
            return br, bt
        }
        if s.kind == symtab.K_SUB {
            ; the carry and interrupt flag routines are single instructions
            ^^ubyte sname = sym_name(s)
            if strings.compare(sname, "sys.set_carry") == 0 {
                void ir.emit(chunk, ir.OP_SEC, ir.T_NONE, ir.M_NONE)
                return 0, t
            }
            if strings.compare(sname, "sys.clear_carry") == 0 {
                void ir.emit(chunk, ir.OP_CLC, ir.T_NONE, ir.M_NONE)
                return 0, t
            }
            uword sr = call_sub(e, true)
            return sr, t
        }
        if s.kind == symtab.K_VAR or s.kind == symtab.K_PARAM {
            ; calling through a pointer variable
            uword pr
            ubyte pt
            pr, pt = identifier(e.a)
            pr = convert(pr, pt, ir.T_POINTER, false)
            void ir.emit_r(chunk, ir.OP_CALLI, ir.T_POINTER, pr)
            if t == ir.T_NONE
                return 0, t
            return convert(called_value(), ir.T_WORD, t, false), t
        }
        if s.kind == symtab.K_LABEL {
            ; a label called like a subroutine: the code there returns
            void ir.emit_call(chunk, sym_name(s))
            return 0, t
        }
        unsupported(e, "call target")
        return ir.new_reg(t), t
    }

    ; Calls a subroutine with its arguments; returns the result register
    ; (for a single result) or 0.
    ; A call of an inline asmsub without parameters or results is replaced
    ; by its assembly code, as upstream does (the body has no rts).  Those
    ; with parameters or results stay calls, which the code generator
    ; inlines.  True when the call was handled here.
    sub inline_asm(^^ast.Node d) -> bool {
        if d.kind != ast.N_ASMSUB or (d.flags & ast.F_INLINE) == 0 or d.a != 0
            return false
        if d.b != 0 and d.b.op != token.T_KW_VOID
            return false
        ^^ast.Node body = d.c
        while body != 0 and body.kind != ast.N_ASM
            body = body.next
        if body == 0 or body.name == n_ir
            return false
        ; the text without the blank line it starts with and the white space it ends with
        ^^ubyte text = body.extra
        long start = 0
        long stop = body.value as long
        long k = 0
        while k < stop and (text[k] == ' ' or text[k] == '\t' or text[k] == '\n' or text[k] == '\r') {
            if text[k] == '\n'
                start = k + 1
            k++
        }
        while stop > start and (text[stop - 1] == ' ' or text[stop - 1] == '\t' or text[stop - 1] == '\n' or text[stop - 1] == '\r')
            stop--
        void ir.add_asm_chunk(cursub, 0, text + start, stop - start, false)
        chunk = ir.add_chunk(cursub, 0)
        return true
    }

    sub call_sub(^^ast.Node e, bool want_result) -> uword {
        ^^symtab.Sym s = e.a.extra
        ^^ast.Node d = s.decl
        if split_words and inline_asm(d)
            return 0
        if uses_registers(d) {
            if want_result
                return asm_call(e, 1)
            return asm_call(e, 0)
        }
        exit_unwinds(s)
        ; the arguments first: all evaluated before the call.  The argument
        ; list is built as a linked list held in scalar locals, because this
        ; sub recurses through expression() and a local array would be shared
        ; with the nested call.
        ^^ir.Arg first = 0
        ^^ir.Arg last = 0
        ^^ast.Node a = e.b
        ^^ast.Node p = d.a
        while a != 0 and p != 0 {
            ^^symtab.Sym ps = p.extra
            uword ptype = 0
            ^^ubyte pname = 0
            if ps != 0 {
                ptype = ps.type
                pname = plain_name(ps)      ; the parameter's own name, as upstream writes it
            }
            ubyte pt = irt(ptype)
            uword r
            ubyte at
            r, at = expression(a)
            r = convert(r, at, pt, types.is_signed(a.type))
            ^^ir.Arg arg = ir.new_arg(pname, r, pt)
            if first == 0
                first = arg
            else
                last.next = arg
            last = arg
            a = a.next
            p = p.next
        }
        ^^ir.Instr callins = ir.emit_call(chunk, sym_name(s))
        callins.args = first
        ^^ast.Node rt = typer.returns_of(s)
        if rt != 0 and rt.next != 0 and prefixing and types.POINTER_SIZE == 4 {
            ; Several values, on a 68000: they come back in d0, d1 ... (and fp0 ...), and
            ; are fetched from there after the call.  The call names those registers as
            ; results without a destination, as upstream does, so that a code generator
            ; knows the call writes them.
            ubyte rcount = return_slots(rt)
            ubyte rk
            for rk in 0 to rcount - 1 {
                ^^ir.Arg place = ir.new_arg(0, 0, ir.T_NONE)
                place.slot = return_slot[rk]
                ir.add_result(callins, place)
            }
            return 0
        }
        if rt != 0 and rt.next == 0 and want_result {
            ubyte t = irt(typer.return_type(rt))
            uword rr = ir.new_reg(t)
            ir.add_result(callins, ir.new_arg(0, rr, t))
            return rr
        }
        return 0
    }

    ; Applies a register operation (or its memory form) to an lvalue in
    ; place, evaluating any index or address expression only once.
    sub inplace(^^ast.Node target, ubyte rop, ubyte mop) {
        ubyte t = irt(target.type)
        uword r
        ubyte at
        ; a rotation through the carry: the status flags survive the address computation
        bool keep_status = rop == ir.OP_ROXL or rop == ir.OP_ROXR
        if target.kind == ast.N_IDENT and target.op != resolver.R_FIELDREF {
            ^^symtab.Sym s = target.extra
            if s != 0 and (s.kind == symtab.K_VAR or s.kind == symtab.K_PARAM or s.kind == symtab.K_MEMVAR) {
                ^^ubyte vs
                long va
                vs, va = var_ref(s)
                void ir.emit_m(chunk, mop, t, vs, va)
                return
            }
        }
        if target.kind == ast.N_INDEX and target.b != 0 and target.b.next == 0 {
            ^^ast.Node base = target.a
            ^^symtab.Sym arr = 0
            if base.kind == ast.N_IDENT and base.op != resolver.R_FIELDREF
                arr = base.extra
            if is_split(arr) {
                ; both halves loaded, the word changed, both halves stored;
                ; the index is evaluated for the load and for the store, as upstream does
                if keep_status
                    void ir.emit(chunk, ir.OP_PUSHST, ir.T_NONE, ir.M_NONE)
                r = split_load(arr, target.b)
                if keep_status
                    void ir.emit(chunk, ir.OP_POPST, ir.T_NONE, ir.M_NONE)
                void ir.emit_r(chunk, rop, ir.T_WORD, r)
                if keep_status
                    void ir.emit(chunk, ir.OP_PUSHST, ir.T_NONE, ir.M_NONE)
                split_store(arr, target.b, r)
                if keep_status
                    void ir.emit(chunk, ir.OP_POPST, ir.T_NONE, ir.M_NONE)
                return
            }
            if arr != 0 and (types.is_array(arr.type) or arr.type == types.T_STR) {
                long esize = types.size_of(target.type)
                if esize == 0
                    esize = 1
                ^^ubyte vs2
                long va2
                vs2, va2 = var_ref(arr)
                if keep_status
                    void ir.emit(chunk, ir.OP_PUSHST, ir.T_NONE, ir.M_NONE)
                uword ixr = index_register(target.b)
                r = ir.new_reg(t)
                void ir.emit_rmx(chunk, ir.OP_LOADX, t, r, vs2, va2, ixr, esize as ubyte)
                if keep_status
                    void ir.emit(chunk, ir.OP_POPST, ir.T_NONE, ir.M_NONE)
                void ir.emit_r(chunk, rop, t, r)
                void ir.emit_rmx(chunk, ir.OP_STOREX, t, r, vs2, va2, ixr, esize as ubyte)
                return
            }
        }
        ; anything else: through its address
        uword pr
        long off
        if keep_status
            void ir.emit(chunk, ir.OP_PUSHST, ir.T_NONE, ir.M_NONE)
        pr, off = lvalue_address(target)
        r = ir.new_reg(t)
        void ir.emit_rp(chunk, ir.OP_LOADI, t, r, pr, off)
        if keep_status
            void ir.emit(chunk, ir.OP_POPST, ir.T_NONE, ir.M_NONE)
        void ir.emit_r(chunk, rop, t, r)
        void ir.emit_rp(chunk, ir.OP_STOREI, t, r, pr, off)
    }

    ; The pointer register and displacement of an lvalue's memory location.
    sub lvalue_address(^^ast.Node target) -> uword, long {
        uword pr
        ubyte pt
        long off
        if target.kind == ast.N_IDENT and target.op == resolver.R_FIELDREF {
            pr, off = field_address(target)
            return pr, off
        }
        if target.kind == ast.N_FIELD {
            pr, pt = expression(target.a)
            ^^symtab.Sym f = target.extra
            if f == 0
                return pr, 0
            return pr, field_offset(f)
        }
        if target.kind == ast.N_DEREF {
            pr, pt = expression(target.a)
            return pr, 0
        }
        if target.kind == ast.N_INDEX and target.b != 0 {
            long esize = types.size_of(target.type)
            if esize == 0
                esize = 1
            pr, off = indexed_address(target.a, target.b, esize)
            return pr, off
        }
        if target.kind == ast.N_MEMREAD {
            pr, pt = expression(target.a)
            return convert(pr, pt, ir.T_POINTER, false), 0
        }
        ; a plain variable: its address
        uword ar
        ubyte art
        ^^ast.Node addr = target
        if target.kind == ast.N_IDENT and target.extra != 0 {
            ^^symtab.Sym s = target.extra
            ar = ir.new_reg(ir.T_POINTER)
            ^^ubyte vs
            long va
            vs, va = var_ref(s)
            if vs == 0
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_POINTER, ar, va)
            else
                void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, ar, vs, 0)
            return ar, 0
        }
        unsupported(target, "in-place operation target")
        return ir.new_reg(ir.T_POINTER), 0
    }

    ; the builtin functions that have IR instructions
    sub builtin(^^ast.Node e, ^^ubyte name) -> uword, ubyte {
        ubyte t = irt(e.type)
        ^^ast.Node a = e.b
        uword r
        ubyte at
        uword r2
        ubyte at2
        if strings.compare(name, "lsb") == 0 or strings.compare(name, "msb") == 0 or strings.compare(name, "lsw") == 0 or strings.compare(name, "msw") == 0 {
            r, at = expression(a)
            uword res = ir.new_reg(t)
            if (name[2] == 'b' and at == ir.T_BYTE) or (name[2] == 'w' and (at == ir.T_BYTE or at == ir.T_WORD)) {
                ; the value is no wider than the part asked for: itself, or zero for the upper part
                if name[0] == 'm'
                    void ir.emit_ri(chunk, ir.OP_LOAD, t, res, 0)
                else
                    res = convert(r, at, t, false)
                return res, t
            }
            if name[0] == 'm' and plain(at) == ir.T_QUAD {
                ; of 64 bits: the top byte or word (the instruction below knows 32)
                uword top = ir.new_reg(ir.T_QUAD)
                void ir.emit_rr(chunk, ir.OP_LOADR, ir.T_QUAD, top, r)
                if name[2] == 'w'
                    void ir.emit_ri(chunk, ir.OP_LSRI, ir.T_QUAD, top, 48)
                else
                    void ir.emit_ri(chunk, ir.OP_LSRI, ir.T_QUAD, top, 56)
                return convert(top, ir.T_QUAD, t, false), t
            }
            ubyte op = ir.OP_LSIGB
            if name[0] == 'm' {
                op = ir.OP_MSIGB
                if name[2] == 'w'
                    op = ir.OP_MSIGW
            }
            else if name[2] == 'w'
                op = ir.OP_LSIGW
            ^^ir.Instr i = ir.emit_rr(chunk, op, plain(at), res, r)
            i.t1 = t
            return res, t
        }
        if strings.compare(name, "mkword") == 0 {
            r, at = expression(a)
            r2, at2 = expression(a.next)
            uword wr = ir.new_reg(ir.T_WORD)
            ^^ir.Instr ci = ir.emit_rrr(chunk, ir.OP_CONCAT, ir.T_BYTE, wr, convert(r, at, ir.T_BYTE, false), convert(r2, at2, ir.T_BYTE, false))
            ci.t1 = ir.T_WORD
            return wr, ir.T_WORD
        }
        if strings.compare(name, "abs") == 0 {
            r, at = expression(a)
            if at == ir.T_FLOAT {
                uword fabsr = ir.new_reg(ir.T_FLOAT)
                void ir.emit_rr(chunk, ir.OP_FABS, ir.T_FLOAT, fabsr, r)
                return fabsr, at
            }
            if types.is_signed(a.type) {
                ^^ubyte done = new_label()
                void ir.emit_ri(chunk, ir.OP_CMPI, at, r, 0)
                void ir.emit_t(chunk, ir.OP_BSTPOS, done)
                void ir.emit_r(chunk, ir.OP_NEG, at, r)
                label(done)
            }
            return r, at
        }
        if strings.compare(name, "sgn") == 0 {
            r, at = expression(a)
            uword sr = ir.new_reg(ir.T_BYTE)
            if types.is_integer(a.type) and not types.is_signed(a.type) {
                ; sgn reads its operand as signed: an unsigned value is 0 or 1
                ^^ubyte positive = new_label()
                ^^ubyte sgndone = new_label()
                void ir.emit_rit(chunk, ir.OP_BGT, at, r, 0, positive)
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, sr, 0)
                jump(sgndone)
                label(positive)
                void ir.emit_ri(chunk, ir.OP_LOAD, ir.T_BYTE, sr, 1)
                label(sgndone)
                return sr, ir.T_BYTE
            }
            ^^ir.Instr si = ir.emit_rr(chunk, ir.OP_SGN, at, sr, r)
            si.t1 = ir.T_BYTE
            return sr, ir.T_BYTE
        }
        if strings.compare(name, "sqrt") == 0 {
            if split_words and a.type == types.T_LONG {
                ; on the 6502 the root of a long is a subroutine of the library
                library_call("prog8_lib", "sqrt_long", "prog8_lib.sqrt_long", a, e)
                return convert(library_result, ir.T_WORD, t, false), t
            }
            r, at = expression(a)
            uword qr = ir.new_reg(t)
            ^^ir.Instr qi = ir.emit_rr(chunk, ir.OP_SQRT, at, qr, r)
            qi.t1 = t
            return qr, t
        }
        if strings.compare(name, "min") == 0 or strings.compare(name, "max") == 0 {
            r, at = expression(a)
            r2, at2 = expression(a.next)
            r = convert(r, at, t, types.is_signed(a.type))
            r2 = convert(r2, at2, t, types.is_signed(a.next.type))
            ^^ubyte keep = new_label()
            bool signed = types.is_signed(e.type)
            ; keep r when r > r2 for max, r < r2 for min
            if name[1] == 'a'
                void ir.emit_rrt(chunk, reg_branch_op(token.T_GE, signed), t, r, r2, keep)
            else
                void ir.emit_rrt(chunk, reg_branch_op(token.T_GE, signed), t, r2, r, keep)
            void ir.emit_rr(chunk, ir.OP_LOADR, t, r, r2)
            label(keep)
            return r, t
        }
        if strings.compare(name, "peek") == 0 or strings.compare(name, "peekw") == 0 or strings.compare(name, "peekl") == 0
            or strings.compare(name, "peekbool") == 0 or strings.compare(name, "peekp") == 0 or strings.compare(name, "peekq") == 0
            or strings.compare(name, "peekf") == 0 {
            bool farok
            quad faraddr
            farok, faraddr = typer.const_eval(a)
            if farok and faraddr > 65535 and types.far_bits != 0 {
                ; an address in far memory: memory at a fixed address, not through a pointer
                uword fpr = ir.new_reg(t)
                void ir.emit_rm(chunk, ir.OP_LOADM, t, fpr, 0, faraddr as long)
                return fpr, t
            }
            r, at = expression(a)
            r = convert(r, at, address_type(a), false)
            uword pr = ir.new_reg(t)
            void ir.emit_rp(chunk, ir.OP_LOADI, t, pr, r, 0)
            return pr, t
        }
        if strings.compare(name, "poke") == 0 or strings.compare(name, "pokew") == 0 or strings.compare(name, "pokel") == 0
            or strings.compare(name, "pokebool") == 0 or strings.compare(name, "pokep") == 0 or strings.compare(name, "pokeq") == 0
            or strings.compare(name, "pokef") == 0 {
            bool pfarok
            quad pfaraddr
            pfarok, pfaraddr = typer.const_eval(a)
            bool pfar = pfarok and pfaraddr > 65535 and types.far_bits != 0
            if not pfar {
                r, at = expression(a)
                r = convert(r, at, address_type(a), false)
            }
            r2, at2 = expression(a.next)
            ubyte vt = ir.T_BYTE
            if name[4] == 'w'
                vt = ir.T_WORD
            else if name[4] == 'l'
                vt = ir.T_LONG
            else if name[4] == 'q'
                vt = ir.T_QUAD
            else if name[4] == 'p'
                vt = ir.T_POINTER
            else if name[4] == 'f'
                vt = ir.T_FLOAT
            ; (a value narrower than what is stored keeps its sign: pokel(a, -5))
            bool vsigned = a.next.type != 0 and types.is_signed(a.next.type)
            if pfar
                void ir.emit_rm(chunk, ir.OP_STOREM, vt, convert(r2, at2, vt, vsigned), 0, pfaraddr as long)
            else
                void ir.emit_rp(chunk, ir.OP_STOREI, vt, convert(r2, at2, vt, vsigned), r, 0)
            return 0, ir.T_BYTE
        }
        if strings.compare(name, "cmp") == 0 {
            r, at = expression(a)
            r2, at2 = expression(a.next)
            void ir.emit_rr(chunk, ir.OP_CMP, at, r, convert(r2, at2, at, false))
            return 0, ir.T_BYTE
        }
        if strings.compare(name, "call") == 0 {
            r, at = expression(a)
            void ir.emit_r(chunk, ir.OP_CALLI, ir.T_POINTER, convert(r, at, ir.T_POINTER, false))
            return called_value(), ir.T_WORD
        }
        if strings.compare(name, "rol") == 0 or strings.compare(name, "ror") == 0 or strings.compare(name, "rol2") == 0 or strings.compare(name, "ror2") == 0 {
            ubyte rop = ir.OP_ROXL
            ubyte mop = ir.OP_ROXLM
            if name[2] == 'r' {
                rop = ir.OP_ROXR
                mop = ir.OP_ROXRM
            }
            if name[3] == '2' {
                rop = ir.OP_ROL
                mop = ir.OP_ROLM
                if name[2] == 'r' {
                    rop = ir.OP_ROR
                    mop = ir.OP_RORM
                }
            }
            inplace(a, rop, mop)
            return 0, ir.T_BYTE
        }
        if strings.compare(name, "rsave") == 0 or strings.compare(name, "rrestore") == 0 {
            ; the status register on the stack, and back (what upstream's 6502 code does)
            if name[1] == 's'
                void ir.emit(chunk, ir.OP_PUSHST, ir.T_NONE, ir.M_NONE)
            else
                void ir.emit(chunk, ir.OP_POPST, ir.T_NONE, ir.M_NONE)
            return 0, ir.T_BYTE
        }
        if strings.compare(name, "setlsb") == 0 or strings.compare(name, "setmsb") == 0 {
            ; one byte of a word or long variable: the lowest, or the highest
            r, at = expression(a)
            ubyte wide = plain(at)
            ubyte shift = 0
            if name[3] == 'm' {
                shift = 8
                if wide == ir.T_LONG
                    shift = 24
            }
            quad bytemask = $ff00
            if shift == 8 and wide == ir.T_WORD
                bytemask = $00ff
            else if shift == 8
                bytemask = $ffff00ff
            else if shift == 24
                bytemask = $00ffffff
            else if wide == ir.T_LONG
                bytemask = $ffffff00
            void ir.emit_ri(chunk, ir.OP_AND, wide, r, bytemask)
            r2, at2 = expression(a.next)
            r2 = convert(convert(r2, at2, ir.T_BYTE, false), ir.T_BYTE, wide, false)
            if shift != 0
                void ir.emit_ri(chunk, ir.OP_LSLI, wide, r2, shift)
            void ir.emit_rr(chunk, ir.OP_ORR, wide, r, r2)
            store(a, r, wide, false)
            return 0, ir.T_BYTE
        }
        if strings.compare(name, "pokemon") == 0 {
            ; like poke, and what was there before is the result
            r, at = expression(a)
            r = convert(r, at, ir.T_POINTER, false)
            uword before = ir.new_reg(ir.T_BYTE)
            void ir.emit_rp(chunk, ir.OP_LOADI, ir.T_BYTE, before, r, 0)
            r2, at2 = expression(a.next)
            void ir.emit_rp(chunk, ir.OP_STOREI, ir.T_BYTE, convert(r2, at2, ir.T_BYTE, false), r, 0)
            return before, ir.T_BYTE
        }
        if name[0] == 'p' and (name[1] == 'u' or name[1] == 'o') and (name[2] == 's' or name[2] == 'p') {
            ; push/pop with a type letter suffix: push, pushw, pushl, pushq, pop, popw, popl, popq
            ubyte st = ir.T_BYTE
            ubyte last = name[3]
            if name[1] == 'o'
                last = name[3]
            else
                last = name[4]
            if last == 'w'
                st = ir.T_WORD
            else if last == 'l'
                st = ir.T_LONG
            else if last == 'q'
                st = ir.T_QUAD
            else if last == 'p'
                st = ir.T_POINTER
            else if last == 'f'
                st = ir.T_FLOAT
            if name[1] == 'u' {
                r, at = expression(a)
                void ir.emit_r(chunk, ir.OP_PUSH, st, convert(r, at, st, false))
                return 0, ir.T_BYTE
            }
            uword popr = ir.new_reg(st)
            void ir.emit_r(chunk, ir.OP_POP, st, popr)
            return popr, st
        }
        if strings.compare(name, "mklong2") == 0 {
            r, at = expression(a)
            r2, at2 = expression(a.next)
            uword lr2 = ir.new_reg(ir.T_LONG)
            ^^ir.Instr li = ir.emit_rrr(chunk, ir.OP_CONCAT, ir.T_WORD, lr2, convert(r, at, ir.T_WORD, false), convert(r2, at2, ir.T_WORD, false))
            li.t1 = ir.T_LONG
            return lr2, ir.T_LONG
        }
        if strings.compare(name, "mklong") == 0 {
            ; mklong(msb, b3, b2, lsb)
            r, at = expression(a)
            r2, at2 = expression(a.next)
            uword hi = ir.new_reg(ir.T_WORD)
            ^^ir.Instr hi_i = ir.emit_rrr(chunk, ir.OP_CONCAT, ir.T_BYTE, hi, convert(r, at, ir.T_BYTE, false), convert(r2, at2, ir.T_BYTE, false))
            hi_i.t1 = ir.T_WORD
            uword r3
            ubyte at3
            uword r4
            ubyte at4
            r3, at3 = expression(a.next.next)
            r4, at4 = expression(a.next.next.next)
            uword lo = ir.new_reg(ir.T_WORD)
            ^^ir.Instr lo_i = ir.emit_rrr(chunk, ir.OP_CONCAT, ir.T_BYTE, lo, convert(r3, at3, ir.T_BYTE, false), convert(r4, at4, ir.T_BYTE, false))
            lo_i.t1 = ir.T_WORD
            uword lr3 = ir.new_reg(ir.T_LONG)
            ^^ir.Instr li2 = ir.emit_rrr(chunk, ir.OP_CONCAT, ir.T_WORD, lr3, hi, lo)
            li2.t1 = ir.T_LONG
            return lr3, ir.T_LONG
        }
        if strings.compare(name, "memory") == 0 {
            ; memory("name", size, align): a slab, named prog8_slabs.memory_<name>
            if a.kind != ast.N_STR {
                unsupported(e, "memory() with a non-literal name")
                return ir.new_reg(ir.T_POINTER), ir.T_POINTER
            }
            ^^ubyte slabname = slab_of(e)
            uword slr = ir.new_reg(ir.T_POINTER)
            void ir.emit_rsym(chunk, ir.OP_LOAD, ir.T_POINTER, slr, slabname, 0)
            return slr, ir.T_POINTER
        }
        if strings.compare(name, "divmod") == 0 {
            unsupported(e, "divmod")
            return 0, ir.T_BYTE
        }
        if strings.compare(name, "clamp") == 0 {
            ; the virtual machine's clamp syscalls, one per type
            ^^ast.Node ca = e.b
            bool csigned = types.is_signed(e.type)
            ^^ubyte cnum = "$1012"
            when t {
                ir.T_BYTE -> {
                    if csigned
                        cnum = "$1013"
                }
                ir.T_WORD -> {
                    cnum = "$1014"
                    if csigned
                        cnum = "$1015"
                }
                ir.T_LONG -> cnum = "$1016"
                else -> {
                    unsupported(e, "clamp of this type")
                    return ir.new_reg(t), t
                }
            }
            uword c1
            uword c2
            uword c3
            ubyte ct
            c1, ct = expression(ca)
            c1 = convert(c1, ct, t, types.is_signed(ca.type))
            c2, ct = expression(ca.next)
            c2 = convert(c2, ct, t, types.is_signed(ca.next.type))
            c3, ct = expression(ca.next.next)
            c3 = convert(c3, ct, t, types.is_signed(ca.next.next.type))
            uword cres = ir.new_reg(t)
            if t == ir.T_LONG and split_words {
                ; the 6502's library clamps bytes and words: a long by comparing
                ^^ubyte clow = new_label()
                ^^ubyte chigh = new_label()
                ^^ubyte cdone = new_label()
                void ir.emit_rrt(chunk, reg_branch_op(token.T_GT, true), t, c2, c1, clow)
                void ir.emit_rrt(chunk, reg_branch_op(token.T_GT, true), t, c1, c3, chigh)
                void ir.emit_rr(chunk, ir.OP_LOADR, t, cres, c1)
                jump(cdone)
                label(clow)
                void ir.emit_rr(chunk, ir.OP_LOADR, t, cres, c2)
                jump(cdone)
                label(chigh)
                void ir.emit_rr(chunk, ir.OP_LOADR, t, cres, c3)
                label(cdone)
                return cres, t
            }
            ^^ir.Instr csys = ir.emit_syscall(chunk, cnum)
            ir.add_arg(csys, ir.new_arg(0, c1, t))
            ir.add_arg(csys, ir.new_arg(0, c2, t))
            ir.add_arg(csys, ir.new_arg(0, c3, t))
            ir.add_result(csys, ir.new_arg(0, cres, t))
            return cres, t
        }
        if strings.compare(name, "callfar") == 0 or strings.compare(name, "callfar2") == 0 {
            ; a call into another memory bank: a syscall that the 6502 code generator
            ; turns into the far call.  callfar(bank, address, argument word in AY),
            ; callfar2(bank, address, A, X, Y, carry); the routine's AY is the result.
            bool far2 = name[7] == '2'
            ^^ir.Instr fsys = 0
            ^^ir.Arg farg_first = 0
            ^^ir.Arg farg_last = 0
            ^^ast.Node fa = e.b
            ubyte fnum = 0
            while fa != 0 {
                ubyte want = ir.T_BYTE
                if fnum == 1 or (fnum == 2 and not far2)
                    want = ir.T_WORD
                uword fr
                ubyte ft
                fr, ft = expression(fa)
                fr = convert(fr, ft, want, false)
                ^^ir.Arg farg = ir.new_arg(0, fr, want)
                if farg_first == 0
                    farg_first = farg
                else
                    farg_last.next = farg
                farg_last = farg
                fnum++
                fa = fa.next
            }
            if far2
                fsys = ir.emit_syscall(chunk, "$1018")
            else
                fsys = ir.emit_syscall(chunk, "$1017")
            fsys.args = farg_first
            uword fres = ir.new_reg(ir.T_WORD)
            ir.add_result(fsys, ir.new_arg(0, fres, ir.T_WORD))
            return fres, ir.T_WORD
        }
        unsupported(e, "builtin function")
        return ir.new_reg(t), t
    }
}
