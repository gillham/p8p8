; The LLVM backend: writes a Prog8 IR program (ir.p8) as textual LLVM IR
; for the llvm64 target, the way upstream's codeGenLlvm does it:
;
; - every virtual register is an alloca slot in its function, typed by the
;   IR types it is used with (LONG registers hold whole addresses: i64);
; - a subroutine's parameters and scalar variables that nothing takes the
;   address of live in allocas too, the other variables are globals;
; - each chunk is a basic block; a conditional branch continues in a fresh
;   block; the status flags are i1 slots set by cmp/cmpi, shifts and
;   rotates and read by the bst* branches;
; - calls pass the arguments in parameter order; several return values go
;   through the hardware slot globals @.slot.sN; syscalls become calls of
;   the C library and of small helper routines emitted on first use;
; - %ir blocks of the libraries are parsed (irparse.p8) and lowered too.
; mem2reg and the optimizer turn the slots back into registers.

%import crumb
%import ir
%import irparse
%import strtab
%import mem
%import buf
%import out
%import strings
%import float_platform
%import llvmrt
%import importer
%import triple

llvmgen {
    %option ignore_unused

    ; LLVM types
    const ubyte L_VOID = 0
    const ubyte L_I1 = 1
    const ubyte L_I8 = 2
    const ubyte L_I16 = 3
    const ubyte L_I32 = 4
    const ubyte L_I64 = 5
    const ubyte L_DOUBLE = 6
    const ubyte L_PTR = 7
    str[] ltype_names = ["void", "i1", "i8", "i16", "i32", "i64", "double", "ptr"]
    ubyte[] ltype_bits = [0, 1, 8, 16, 32, 64, 64, 64]

    ^^ir.Program prog = 0
    bool llvm32 = false             ; the llvm32 target: its platform is the triple profile (triple.p8)
    long pointer_bytes = 8
    bool mos = false                ; the llvm16 target: a 6502 with the llvm-mos SDK
    bool c64 = false                ; its mos-c64 profile: a Commodore 64 program, not the simulator
    ^^ubyte host_name = 0           ; llvm64: the triple and data layout of the platform
    ^^ubyte host_layout = 0
    bool linux = false              ; readdir's struct dirent has its name at offset 19, not 21
    bool intel_mac = false          ; opendir and readdir are the $INODE64 variants there
    bool strict = false             ; calls through a pointer name the exact type (WebAssembly)
    bool console_keys = false       ; the program reads keys: characters and keys come from the console runtime
    bool console_size = false       ; the program asks for the terminal's size
    bool windows = false            ; 64 bit file offsets are _fseeki64 and _ftelli64; the dirent name is at 0
    ubyte long_lt = L_I64           ; C's long: 32 bits on WebAssembly and the 6502
    ^^ubyte long_name = "i64"
    ubyte size_lt = L_I64           ; C's size_t: 64 bits, 32 on WebAssembly, 16 on the 6502
    ^^ubyte size_name = "i64"
    ubyte int_lt = L_I32            ; C's int: 16 bits on the 6502
    ^^ubyte int_name = "i32"
    ^^buf.Buf outbuf = 0        ; the module text
    ^^buf.Buf fb = 0            ; the body of the function being lowered
    ^^buf.Buf pb = 0            ; its prologue (allocas, parameter stores)
    ^^buf.Buf decls = 0         ; declarations and helpers, written after the functions
    ^^buf.Buf nb = 0            ; name and number building
    ^^buf.Buf fixups = 0        ; stores of addresses that sit unaligned in packed data, run before main
    ^^ir.Sub cursub = 0
    ubyte cur_return = L_VOID   ; the current function's return type
    long value_seq = 0
    long block_seq = 0
    bool terminated = false     ; the current block ended with a terminator
    bool in_dead = false
    long errors = 0
    bool has_initglobals = false

    ; register slots of the current function: the LLVM type of each slot (L_VOID: unused)
    ^^ubyte slot_type = 0
    long slot_cap = 0

    ; the variables that are stack locals, by name, and the symbol table of all variables
    ^^pointer vartab = 0        ; open addressing hash of ^^ir.Var by name
    uword vartab_size = 0
    ^^pointer subtab = 0        ; ^^ir.Sub by name
    uword subtab_size = 0

    ; what was declared or emitted already (names)
    ^^pointer declared = 0
    uword declared_count = 0
    uword declared_cap = 0

    ; ---- entry ----

    ; Writes the program as LLVM IR into the buffer.
    sub generate(^^ir.Program p, ^^buf.Buf b) {
        prog = p
        outbuf = b
        if nb == 0 {
            nb = buf.new(256)
            fb = buf.new(65536)
            pb = buf.new(4096)
            decls = buf.new(4096)
            fixups = buf.new(1024)
        }
        buf.clear(fixups)
        buf.clear(fb)
        buf.clear(pb)
        buf.clear(decls)
        declared_count = 0
        file_runtime_done = false
        errors = 0
        ; the platform: llvm32 is WebAssembly with WASI (upstream's default triple profile for
        ; it), anything else the 64-bit machine p8p8 itself runs on
        llvm32 = strings.compare(p.target, "llvm32") == 0
        mos = strings.compare(p.target, "llvm16") == 0
        pointer_bytes = 8
        size_lt = L_I64
        size_name = "i64"
        int_lt = L_I32
        int_name = "i32"
        if llvm32 {
            pointer_bytes = 4
            size_lt = L_I32
            size_name = "i32"
        }
        strict = llvm32 and triple.strict_indirect_signatures
        c64 = mos and importer.triple != 0 and strings.compare(importer.triple, "mos-c64") == 0
        find_console_use(p)
        ; the hosted platform of llvm64: upstream's four profiles
        host_name = "arm64-apple-macosx"
        host_layout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
        linux = false
        intel_mac = false
        windows = false
        if not llvm32 and not mos and importer.triple != 0 {
            if strings.compare(importer.triple, "x86_64-apple-macosx") == 0 {
                host_name = "x86_64-apple-macosx"
                host_layout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
                intel_mac = true
            }
            else if strings.compare(importer.triple, "x86_64-unknown-linux-gnu") == 0 {
                host_name = "x86_64-unknown-linux-gnu"
                host_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
                linux = true
            }
            else if strings.compare(importer.triple, "x86_64-pc-windows-msvc") == 0 {
                host_name = "x86_64-pc-windows-msvc"
                host_layout = "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
                windows = true
            }
            else if strings.compare(importer.triple, "aarch64-unknown-linux-gnu") == 0 {
                host_name = "aarch64-unknown-linux-gnu"
                host_layout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"
                linux = true
            }
        }
        long_lt = L_I64
        long_name = "i64"
        if llvm32 or mos {
            long_lt = L_I32
            long_name = "i32"
        }
        if mos {
            ; (upstream's default triple profile for llvm16: the simulator of llvm-mos)
            pointer_bytes = 2
            size_lt = L_I16
            size_name = "i16"
            int_lt = L_I16
            int_name = "i16"
        }
        build_tables()
        build_clusters()
        mark_stack_locals()
        emit("; ModuleID = '")
        emit(p.name)
        emit("'\n; generated by p8p8 for the ")
        emit(p.target)
        emit(" target\nsource_filename = \"")
        emit(p.name)
        if llvm32 {
            emit("\"\ntarget datalayout = \"")
            emit(triple.datalayout)
            emit("\"\ntarget triple = \"")
            emit(triple.name)
            emit("\"\n\n")
        }
        else if mos
            emit("\"\ntarget datalayout = \"e-m:e-p:16:8-p1:8:8-i16:8-i32:8-i64:8-f32:8-f64:8-a:8-Fi8-n8\"\ntarget triple = \"mos\"\n\n")
        else {
            emit("\"\ntarget datalayout = \"")
            emit(host_layout)
            emit("\"\ntarget triple = \"")
            emit(host_name)
            emit("\"\n\n")
        }
        write_globals()
        if fixups.len != 0 {
            ; the linker wants pointers in data aligned, so unaligned ones are stored at startup, as upstream does
            emit("@llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @.init.addresses, ptr null }]\n\ndefine internal void @.init.addresses() {\nentry:\n")
            buf.add_bytes(outbuf, fixups.data, fixups.len)
            emit("  ret void\n}\n\n")
        }
        emit("@.sys.argc = internal global i32 0\n@.sys.argv = internal global ptr null\n@.sys.argv.none = internal constant [1 x i8] zeroinitializer\n\n")
        ; the global initialization code, if any
        has_initglobals = p.initglobals.first != 0
        ^^ir.Block bl = p.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if s.is_asm {
                    if s.is_external
                        declare_extsub(s)
                    else
                        unsupported_sub(s, "an asmsub with native assembly")
                }
                else
                    function(s)
                s = s.next
            }
            bl = bl.next
        }
        if has_initglobals
            initglobals_function()
        emit_main()
        buf.add_bytes(outbuf, decls.data, decls.len)
    }

    sub emit(str s) {
        buf.add_str(outbuf, s)
    }

    sub error(str message) {
        errors++
        out.err()
        out.puts("llvm: ")
        out.puts(message)
        if cursub != 0 {
            out.puts(" in ")
            out.puts(cursub.name)
        }
        out.nl()
        out.std()
    }

    sub unsupported_sub(^^ir.Sub s, str what) {
        out.err()
        out.puts("llvm: cannot translate ")
        out.puts(s.name)
        out.puts(": ")
        out.puts(what)
        out.nl()
        out.std()
        errors++
    }

    ; ---- symbol tables ----

    sub hash_ptr(pointer p, uword size) -> uword {
        uquad h = p as uquad
        h = (h >> 4) ^ (h >> 20)
        return (h as uword) & (size - 1)
    }

    sub build_tables() {
        long nvars = 0
        ^^ir.Var v = prog.vars
        while v != 0 {
            nvars++
            v = v.next
        }
        vartab_size = 1024
        while vartab_size < nvars * 2
            vartab_size <<= 1
        vartab = mem.alloc((vartab_size as long) * sizeof(pointer))     ; (a uword product would overflow)
        v = prog.vars
        while v != 0 {
            uword h = hash_ptr(v.name, vartab_size)
            while vartab[h] != 0
                h = (h + 1) & (vartab_size - 1)
            vartab[h] = v
            v = v.next
        }
        long nsubs = 0
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                nsubs++
                s = s.next
            }
            bl = bl.next
        }
        subtab_size = 256
        while subtab_size < nsubs * 2
            subtab_size <<= 1
        subtab = mem.alloc((subtab_size as long) * sizeof(pointer))
        bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s2 = bl.subs
            while s2 != 0 {
                uword h2 = hash_ptr(s2.name, subtab_size)
                while subtab[h2] != 0
                    h2 = (h2 + 1) & (subtab_size - 1)
                subtab[h2] = s2
                s2 = s2.next
            }
            bl = bl.next
        }
    }

    ; ---- memory-mapped variables ----
    ; The IR accesses them by absolute address.  As upstream does, they get
    ; backing storage: variables whose byte ranges overlap or touch share one
    ; global, so aliases such as cx16.r0 / r0L / r0H keep their layout.
    struct Cluster {
        ^^Cluster next
        long start
        long end
    }
    ^^Cluster clusters = 0

    sub build_clusters() {
        clusters = 0
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 {
                long start = parse_number(v.init)
                ; (on llvm16 an address below 64 KB is the machine's own memory; only what lies
                ;  beyond it, the virtual registers at $ff0000, gets storage)
                if not mos or start >= $10000
                    add_range(start, start + type_bytes(v.typestr))
            }
            v = v.next
        }
    }

    ; merges [start,end) into the sorted cluster list
    sub add_range(long start, long end) {
        ^^Cluster c = clusters
        ^^Cluster prev = 0
        while c != 0 and c.end < start {
            prev = c
            c = c.next
        }
        if c != 0 and c.start <= end {
            if start < c.start
                c.start = start
            if end > c.end
                c.end = end
            while c.next != 0 and c.next.start <= c.end {
                if c.next.end > c.end
                    c.end = c.next.end
                c.next = c.next.next
            }
            return
        }
        ^^Cluster n = mem.alloc(sizeof(Cluster))
        n.start = start
        n.end = end
        n.next = c
        if prev == 0
            clusters = n
        else
            prev.next = n
    }

    ; "$hex", "%binary" or decimal, with an optional sign
    sub parse_number(^^ubyte t) -> long {
        long v = 0
        long i = 0
        bool neg = false
        if t[0] == '-' {
            neg = true
            i++
        }
        if t[i] == '$' {
            i++
            while t[i] != 0 {
                ubyte d = t[i]
                if d >= '0' and d <= '9'
                    v = v * 16 + (d - '0')
                else if d >= 'a' and d <= 'f'
                    v = v * 16 + (d - 'a' + 10)
                else if d >= 'A' and d <= 'F'
                    v = v * 16 + (d - 'A' + 10)
                else
                    break
                i++
            }
        }
        else if t[i] == '%' {
            i++
            while t[i] == '0' or t[i] == '1' {
                v = v * 2 + (t[i] - '0')
                i++
            }
        }
        else {
            while t[i] >= '0' and t[i] <= '9' {
                v = v * 10 + (t[i] - '0')
                i++
            }
        }
        if neg
            return -v
        return v
    }

    ; the bytes a variable of this IR type string occupies
    sub type_bytes(^^ubyte t) -> long {
        long each = 1
        ubyte et = lt_of_typestr(t)
        when et {
            L_I16 -> each = 2
            L_I32 -> each = 4
            L_PTR -> each = pointer_bytes
            L_I64, L_DOUBLE -> each = 8
        }
        long n = array_length(t)
        if n == 0
            n = 1
        else {
            ^^ir.Var sd = element_struct(t)
            if sd != 0
                each = sd.size
        }
        return each * n
    }

    ; "@.memmapped.<hex start>" of the cluster holding an address, into nb
    sub add_cluster_name(^^Cluster c) {
        buf.add_str(nb, "@.memmapped.")
        quad v = c.start as quad
        ubyte digits = 1
        while (v >> (digits * 4)) != 0 and digits < 16
            digits++
        ubyte shift = (digits - 1) * 4
        repeat digits {
            buf.add_byte(nb, buf.hex_digit(((v >> shift) & 15) as ubyte))
            if shift >= 4
                shift -= 4
        }
    }

    ; the backing storage of an absolute address, or 0 when no memory-mapped variable covers it
    sub memmapped_address(long address) -> ^^ubyte {
        ^^Cluster c = clusters
        while c != 0 {
            if address >= c.start and address < c.end {
                buf.clear(nb)
                if address != c.start
                    buf.add_str(nb, "getelementptr (i8, ptr ")
                add_cluster_name(c)
                if address != c.start {
                    buf.add_str(nb, ", i64 ")
                    buf.add_long(nb, address - c.start)
                    buf.add_byte(nb, ')')
                }
                return keep_nb()
            }
            c = c.next
        }
        return 0
    }

    sub write_clusters() {
        ^^Cluster c = clusters
        while c != 0 {
            buf.clear(nb)
            add_cluster_name(c)
            buf.add_str(nb, " = internal global [")
            buf.add_long(nb, c.end - c.start)
            buf.add_str(nb, " x i8] zeroinitializer, align ")
            long align = 8
            if c.start != 0 {
                align = c.start & -c.start      ; the lowest set bit: the alignment the start address has
                if align > 8
                    align = 8
            }
            buf.add_long(nb, align)
            buf.add_byte(nb, '\n')
            emit(nb.data)
            c = c.next
        }
    }

    sub find_var(^^ubyte name) -> ^^ir.Var {
        if name == 0
            return 0
        uword h = hash_ptr(name, vartab_size)
        while vartab[h] != 0 {
            ^^ir.Var v = vartab[h]
            if v.name == name
                return v
            h = (h + 1) & (vartab_size - 1)
        }
        return 0
    }

    sub find_sub(^^ubyte name) -> ^^ir.Sub {
        if name == 0
            return 0
        uword h = hash_ptr(name, subtab_size)
        while subtab[h] != 0 {
            ^^ir.Sub s = subtab[h]
            if s.name == name
                return s
            h = (h + 1) & (subtab_size - 1)
        }
        return 0
    }

    ; the subroutine a variable belongs to: the longest prefix of its name that names one
    sub owner_of(^^ubyte name) -> ^^ir.Sub {
        long length = buf.cstr_len(name)
        long i = length
        while i > 0 {
            i--
            if name[i] == '.' {
                ^^ubyte prefix = strtab.intern(name, i as uword)
                ^^ir.Sub s = find_sub(prefix)
                if s != 0
                    return s
            }
        }
        return 0
    }

    sub is_scalar_type(^^ubyte typestr) -> bool {
        long i = 0
        while typestr[i] != 0 {
            if typestr[i] == '['
                return false
            i++
        }
        return true
    }

    ; Scalar variables of a subroutine that nothing refers to by address or
    ; from another subroutine become stack slots (recursion needs that).
    sub mark_stack_locals() {
        ^^ir.Var v = prog.vars
        while v != 0 {
            v.stacklocal = false
            if v.kind == ir.V_VAR and not v.shared and not v.dirty and v.align == 0 and is_scalar_type(v.typestr) {
                v.owner = owner_of(v.name)
                if v.owner != 0
                    v.stacklocal = true
            }
            v = v.next
        }
        ; disqualify
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                ^^ir.Chunk c = s.chunks
                while c != 0 {
                    ^^ir.Instr i = c.first
                    while i != 0 {
                        disqualify_uses(i, s)
                        i = i.next
                    }
                    c = c.next
                }
                s = s.next
            }
            bl = bl.next
        }
        ^^ir.Instr gi = prog.initglobals.first
        while gi != 0 {
            disqualify_uses(gi, 0)
            gi = gi.next
        }
        ; symbols in array initializers
        v = prog.vars
        while v != 0 {
            if v.init != 0 and v.init[0] == '@'
                disqualify_initializer(v.init)
            v = v.next
        }
    }

    sub disqualify_uses(^^ir.Instr i, ^^ir.Sub s) {
        if i.sym == 0
            return
        ^^ir.Var v = find_var(i.sym)
        if v == 0 or not v.stacklocal
            return
        ; an immediate symbol takes the address; memory access from elsewhere shares it
        if i.mode == ir.M_RI or i.mode == ir.M_I or i.mode == ir.M_RRI or v.owner != s
            v.stacklocal = false
    }

    sub disqualify_initializer(^^ubyte init) {
        long p = 0
        while init[p] != 0 {
            if init[p] == '@' {
                long q = p + 1
                while init[q] != 0 and init[q] != ','
                    q++
                ^^ir.Var v = find_var(strtab.intern(init + p + 1, (q - p - 1) as uword))
                if v != 0
                    v.stacklocal = false
                p = q
            }
            else
                p++
        }
    }

    ; ---- types ----

    sub lt(ubyte irtype) -> ubyte {
        when irtype {
            ir.T_BYTE -> return L_I8
            ir.T_WORD -> return L_I16
            ir.T_LONG -> return L_I32
            ir.T_QUAD -> return L_I64
            ir.T_FLOAT -> return L_DOUBLE
            ir.T_POINTER -> return L_PTR
        }
        return L_I8
    }

    ; the LLVM scalar type of an IR type string such as "ubyte" or "pointer"
    sub lt_of_typestr(^^ubyte t) -> ubyte {
        if strings.compare(t, "ubyte") == 0 or strings.compare(t, "byte") == 0 or strings.compare(t, "bool") == 0
            return L_I8
        if strings.compare(t, "uword") == 0 or strings.compare(t, "word") == 0
            return L_I16
        if strings.compare(t, "long") == 0
            return L_I32
        if strings.compare(t, "quad") == 0 or strings.compare(t, "uquad") == 0
            return L_I64
        if strings.compare(t, "float") == 0
            return L_DOUBLE
        if strings.compare(t, "pointer") == 0 or t[0] == '^'
            return L_PTR
        return L_I8
    }

    sub ltname(ubyte t) -> ^^ubyte {
        return ltype_names[t]
    }

    sub is_int(ubyte t) -> bool {
        return t >= L_I1 and t <= L_I64
    }

    ; ---- values ----

    ; a persistent copy of the name in nb
    sub keep_nb() -> ^^ubyte {
        ^^ubyte s = mem.alloc(nb.len + 1)
        mem.copy(nb.data, s, nb.len)
        s[nb.len] = 0
        return s
    }

    ; an LLVM identifier made of prefix and name: bare when it only has
    ; identifier characters, otherwise quoted (as for floats.π)
    sub ident2(str prefix, ^^ubyte name) -> ^^ubyte {
        bool bare = name[0] != 0
        long k = 0
        while name[k] != 0 {
            ubyte ch = name[k]
            if not (ch == '-' or ch == '$' or ch == '.' or ch == '_' or (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9'))
                bare = false
            k++
        }
        if bare and prefix[0] == 0
            return name
        buf.clear(nb)
        if not bare
            buf.add_byte(nb, '"')
        buf.add_str(nb, prefix)
        buf.add_str(nb, name)
        if not bare
            buf.add_byte(nb, '"')
        return keep_nb()
    }

    sub ident(^^ubyte name) -> ^^ubyte {
        return ident2("", name)
    }

    sub fresh() -> ^^ubyte {
        value_seq++
        buf.clear(nb)
        buf.add_str(nb, "%v")
        buf.add_long(nb, value_seq)
        return keep_nb()
    }

    ; the text of an integer constant of a type, as LLVM wants it: signed decimal of the type's width
    sub int_const(quad v, ubyte t) -> ^^ubyte {
        buf.clear(nb)
        when t {
            L_I1 -> {
                if v != 0
                    buf.add_str(nb, "true")
                else
                    buf.add_str(nb, "false")
            }
            L_I8 -> buf.add_long(nb, (v as ubyte) as byte)
            L_I16 -> buf.add_long(nb, (v as uword) as word)
            L_I32 -> buf.add_long(nb, (v as long))
            L_PTR -> {
                if v == 0
                    buf.add_str(nb, "null")
                else {
                    buf.add_str(nb, "inttoptr (i64 ")
                    buf.add_quad(nb, v)
                    buf.add_str(nb, " to ptr)")
                }
            }
            else -> buf.add_quad(nb, v)
        }
        return keep_nb()
    }

    float scratch_float = 0.0

    ; a double constant as the hex of its bits, which LLVM always reads exactly
    sub float_const(float v) -> ^^ubyte {
        scratch_float = v
        uquad bits = peekq(&scratch_float) as uquad
        buf.clear(nb)
        buf.add_str(nb, "0x")
        ubyte shift = 60
        repeat 16 {
            buf.add_byte(nb, buf.hex_digit(((bits >> shift) & 15) as ubyte))
            if shift >= 4
                shift -= 4
        }
        ; uppercase, as LLVM prints it (either case is read)
        return keep_nb()
    }

    ; ---- function text ----

    sub line(str s) {
        buf.add_str(fb, "  ")
        buf.add_str(fb, s)
    }

    sub add(str s) {
        buf.add_str(fb, s)
    }

    sub addn(^^ubyte s) {
        buf.add_str(fb, s)
    }

    sub nl() {
        buf.add_byte(fb, '\n')
    }

    ; a new block
    sub block(^^ubyte name) {
        buf.add_byte(fb, '\n')
        buf.add_str(fb, name)
        buf.add_str(fb, ":\n")
        terminated = false
    }

    sub fresh_block(str base) -> ^^ubyte {
        block_seq++
        buf.clear(nb)
        buf.add_str(nb, base)
        buf.add_byte(nb, '.')
        buf.add_long(nb, block_seq)
        return keep_nb()
    }

    ; "  %v = <op> " and returns %v
    sub result(ubyte t) -> ^^ubyte {
        ^^ubyte v = fresh()
        buf.add_str(fb, "  ")
        buf.add_str(fb, v)
        buf.add_str(fb, " = ")
        return v
    }

    sub typed(ubyte t, ^^ubyte v) {
        addn(ltname(t))
        add(" ")
        addn(v)
    }

    ; ---- register slots ----

    sub slot_name(uword r) -> ^^ubyte {
        buf.clear(nb)
        buf.add_str(nb, "%r")
        buf.add_long(nb, r)
        buf.add_str(nb, ".slot")
        return keep_nb()
    }

    ; the slot type of a register: from the IR types it is used with
    sub slot_of(uword r) -> ubyte {
        if r >= slot_cap
            return L_I64
        ubyte t = slot_type[r]
        if t == L_VOID
            return L_I64
        return t
    }

    ; collects the register types of a subroutine; marks mixed and LONG registers as i64 slots
    sub scan_registers(^^ir.Sub s) {
        long needed = (ir.regmax as long) + 2
        if needed > slot_cap {
            slot_type = mem.grow(slot_type, slot_cap, needed)
            slot_cap = needed
        }
        ; 255 = unused this function (cleared lazily: we clear the whole table; it is small)
        long k = 0
        while k < slot_cap {
            slot_type[k] = L_VOID
            k++
        }
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            ^^ir.Instr i = c.first
            while i != 0 {
                note_use(i.r1, reg_use_type(i, 1))
                note_use(i.r2, reg_use_type(i, 2))
                note_use(i.r3, reg_use_type(i, 3))
                ^^ir.Arg a = i.args
                while a != 0 {
                    if a.reg != 0
                        note_use(a.reg, a.type)
                    a = a.next
                }
                a = i.results
                while a != 0 {
                    if a.reg != 0
                        note_use(a.reg, a.type)
                    a = a.next
                }
                i = i.next
            }
            c = c.next
        }
    }

    ; the IR type a register operand of the instruction is used with
    sub reg_use_type(^^ir.Instr i, ubyte which) -> ubyte {
        uword r = i.r1
        ubyte t = i.t1
        if which == 2 {
            r = i.r2
            t = i.t2
        }
        else if which == 3 {
            r = i.r3
            t = i.t3
        }
        if r == 0
            return ir.T_NONE
        if t != ir.T_NONE
            return t
        ; the pointer register of an indirect memory reference, the index register of an indexed one
        if which == 2 and (i.mode == ir.M_RP or i.mode == ir.M_P)
            return ir.T_POINTER
        if which == 2 and (i.mode == ir.M_RM or i.mode == ir.M_M or i.mode == ir.M_IM)
            return ir.reg_type(r)
        if i.type != ir.T_NONE
            return i.type
        return ir.reg_type(r)
    }

    sub note_use(uword r, ubyte irtype) {
        if r == 0 or r >= slot_cap or irtype == ir.T_NONE
            return
        ubyte t = lt(irtype)
        if irtype == ir.T_LONG
            t = L_I64          ; a LONG register may hold a whole address
        ubyte cur = slot_type[r]
        if cur == L_VOID
            slot_type[r] = t
        else if cur != t {
            if cur == L_DOUBLE or t == L_DOUBLE
                slot_type[r] = L_DOUBLE
            else
                slot_type[r] = L_I64
        }
    }

    ; the value of a register as an LLVM type
    sub read(uword r, ubyte irtype) -> ^^ubyte {
        ubyte st = slot_of(r)
        ^^ubyte v = result(st)
        add("load ")
        addn(ltname(st))
        add(", ptr ")
        addn(slot_name(r))
        nl()
        return convert(v, st, lt(irtype))
    }

    ; a LONG register's whole slot, for addresses
    sub read_wide(uword r, ubyte irtype) -> ^^ubyte, ubyte {
        ubyte st = slot_of(r)
        ^^ubyte v = result(st)
        add("load ")
        addn(ltname(st))
        add(", ptr ")
        addn(slot_name(r))
        nl()
        if irtype == ir.T_LONG
            return v, st
        ubyte t = lt(irtype)
        ^^ubyte cv = convert(v, st, t)
        return cv, t
    }

    ; the address in a register, as a ptr
    sub pointer_value(uword r, ubyte irtype) -> ^^ubyte {
        ^^ubyte v
        ubyte t
        v, t = read_wide(r, irtype)
        return convert(v, t, L_PTR)
    }

    sub write(uword r, ^^ubyte v, ubyte t) {
        ubyte st = slot_of(r)
        ^^ubyte sv
        if t == L_I32 and st == L_I64
            sv = widen(v, t, st, true)       ; a long offset stays usable in wide address arithmetic
        else
            sv = convert(v, t, st)
        line("store ")
        typed(st, sv)
        add(", ptr ")
        addn(slot_name(r))
        nl()
    }

    ; Converts a value: integers truncate or zero extend, pointers convert to and from integers.
    sub convert(^^ubyte v, ubyte from, ubyte to_t) -> ^^ubyte {
        if from == to_t
            return v
        ^^ubyte op
        if is_int(from) and is_int(to_t) {
            if ltype_bits[to_t] < ltype_bits[from]
                op = "trunc"
            else
                op = "zext"
        }
        else if from == L_PTR and is_int(to_t)
            op = "ptrtoint"
        else if is_int(from) and to_t == L_PTR
            op = "inttoptr"
        else if from == L_DOUBLE and is_int(to_t)
            op = "fptosi"
        else if is_int(from) and to_t == L_DOUBLE
            op = "sitofp"
        else {
            buf.clear(nb)
            buf.add_str(nb, "impossible conversion from ")
            buf.add_str(nb, ltname(from))
            buf.add_str(nb, " to ")
            buf.add_str(nb, ltname(to_t))
            buf.add_byte(nb, 0)
            error(nb.data)
            return v
        }
        ^^ubyte r = result(to_t)
        addn(op)
        add(" ")
        typed(from, v)
        add(" to ")
        addn(ltname(to_t))
        nl()
        return r
    }

    sub widen(^^ubyte v, ubyte from, ubyte to_t, bool signed) -> ^^ubyte {
        if not signed or from == to_t
            return convert(v, from, to_t)
        ^^ubyte r = result(to_t)
        add("sext ")
        typed(from, v)
        add(" to ")
        addn(ltname(to_t))
        nl()
        return r
    }

    ; a pointer value as an integer of the address size, for arithmetic
    sub as_int(^^ubyte v, ubyte t) -> ^^ubyte, ubyte {
        if t == L_PTR {
            ^^ubyte iv = convert(v, L_PTR, L_I64)
            return iv, L_I64
        }
        return v, t
    }

    ; ---- memory ----

    ; the address of a symbol with an offset, as a ptr value
    ; What the address of a subroutine that returns a value is where a call through a
    ; pointer must have the type "void ()" (WebAssembly): a small function that calls
    ; the subroutine and leaves the value in slot 10, as OP_CALLI expects.
    sub indirect_entry(^^ir.Sub s, ubyte rt) -> ^^ubyte {
        ^^ubyte slot = hardware_slot(10, rt == L_DOUBLE)
        ^^ubyte gname = ident(s.name)
        buf.clear(nb)
        buf.add_str(nb, gname)
        buf.add_str(nb, ".indirect")
        ^^ubyte tname = keep_nb()
        buf.clear(nb)
        buf.add_str(nb, "define internal void @")
        buf.add_str(nb, tname)
        buf.add_str(nb, "() {\nentry:\n  %result = call ")
        buf.add_str(nb, ltname(rt))
        buf.add_str(nb, " @")
        buf.add_str(nb, gname)
        buf.add_str(nb, "()\n")
        when rt {
            L_I64 -> buf.add_str(nb, "  store i64 %result, ptr ")
            L_DOUBLE -> buf.add_str(nb, "  store double %result, ptr ")
            L_PTR -> buf.add_str(nb, "  %wide = ptrtoint ptr %result to i64\n  store i64 %wide, ptr ")
            else -> {
                buf.add_str(nb, "  %wide = zext ")
                buf.add_str(nb, ltname(rt))
                buf.add_str(nb, " %result to i64\n  store i64 %wide, ptr ")
            }
        }
        buf.add_str(nb, slot)
        buf.add_str(nb, "\n  ret void\n}")
        declare(tname, keep_nb())
        buf.clear(nb)
        buf.add_byte(nb, '@')
        buf.add_str(nb, tname)
        return keep_nb()
    }

    sub symbol_address(^^ubyte sym, long offset) -> ^^ubyte {
        if strict and offset == 0 {
            ^^ir.Sub called = find_sub(sym)
            if called != 0 and not called.is_asm and called.params == 0 {
                ubyte crt = return_ltype(called)
                if crt != L_VOID
                    return indirect_entry(called, crt)
            }
        }
        ^^ir.Var v = find_var(sym)
        ^^ubyte base
        if v != 0 and v.kind == ir.V_MEMVAR and v.init != 0 {
            long address = parse_number(v.init) + offset
            base = memmapped_address(address)
            if base == 0
                base = int_const(address, L_PTR)
            return base
        }
        if v != 0 and v.stacklocal {
            ^^ubyte lname = ident2("local.", sym)
            buf.clear(nb)
            buf.add_byte(nb, '%')
            buf.add_str(nb, lname)
            base = keep_nb()
        }
        else {
            ^^ubyte gname = ident(sym)
            buf.clear(nb)
            buf.add_byte(nb, '@')
            buf.add_str(nb, gname)
            base = keep_nb()
        }
        if offset == 0
            return base
        ^^ubyte r = result(L_PTR)
        add("getelementptr i8, ptr ")
        addn(base)
        add(", i64 ")
        buf.add_long(fb, offset)
        nl()
        return r
    }

    ; the memory address an instruction refers to: [sym+off], [$addr], [rN.p+off], with an optional index register
    sub memory_address(^^ir.Instr i) -> ^^ubyte {
        ^^ubyte base
        if i.mode == ir.M_RP or i.mode == ir.M_P {
            base = pointer_value(i.r2, ir.T_POINTER)
            if i.offset == 0
                return base
            ^^ubyte r = result(L_PTR)
            add("getelementptr i8, ptr ")
            addn(base)
            add(", i64 ")
            buf.add_long(fb, i.offset)
            nl()
            return r
        }
        if i.sym != 0
            base = symbol_address(i.sym, i.offset)
        else {
            base = memmapped_address(i.offset)
            if base == 0
                base = int_const(i.offset, L_PTR)
        }
        if i.r2 == 0
            return base
        ; indexed: an unsigned index times the scale
        ubyte ixt = i.t2
        if ixt == ir.T_NONE
            ixt = ir.reg_type(i.r2)
        if ixt == ir.T_NONE
            ixt = ir.T_WORD
        ^^ubyte ix = read(i.r2, ixt)
        ^^ubyte ix64 = convert(ix, lt(ixt), L_I64)
        if i.scale != 1 {
            ^^ubyte scaled = result(L_I64)
            add("mul i64 ")
            addn(ix64)
            add(", ")
            buf.add_long(fb, i.scale)
            nl()
            ix64 = scaled
        }
        ^^ubyte r2 = result(L_PTR)
        add("getelementptr i8, ptr ")
        addn(base)
        add(", i64 ")
        addn(ix64)
        nl()
        return r2
    }

    ; " volatile" for an access of a constant address that is hardware: on the Commodore 64
    ; every constant address (interrupts change system variables too), in the 6502
    ; simulator its I/O registers at $fff0-$ffff; nothing on the hosted targets
    sub volatility(^^ubyte addr) -> ^^ubyte {
        if not mos or not buf.bytes_equal(addr, "inttoptr (", 10)
            return ""
        if c64
            return "volatile "
        ; "inttoptr (i64 N to ptr)"
        long k = 10
        while addr[k] != 0 and addr[k] != ' '
            k++
        long value = 0
        k++
        while addr[k] >= '0' and addr[k] <= '9' {
            value = value * 10 + (addr[k] - '0')
            k++
        }
        if value >= $fff0 and value <= $ffff
            return "volatile "
        return ""
    }

    sub load_from(^^ubyte addr, ubyte t) -> ^^ubyte {
        ^^ubyte v = result(t)
        add("load ")
        addn(volatility(addr))
        addn(ltname(t))
        add(", ptr ")
        addn(addr)
        if t != L_I8
            add(", align 1")
        nl()
        return v
    }

    sub store_to(^^ubyte addr, ^^ubyte v, ubyte t) {
        line("store ")
        addn(volatility(addr))
        typed(t, v)
        add(", ptr ")
        addn(addr)
        if t != L_I8
            add(", align 1")
        nl()
    }

    ; ---- flags ----

    ; the four status flags as i1 slots
    sub set_flag(str flag, ^^ubyte v) {
        line("store i1 ")
        addn(v)
        add(", ptr %flag.")
        add(flag)
        nl()
    }

    sub get_flag(str flag) -> ^^ubyte {
        ^^ubyte v = result(L_I1)
        add("load i1, ptr %flag.")
        add(flag)
        nl()
        return v
    }

    sub icmp(str cond, ^^ubyte a, ^^ubyte b, ubyte t) -> ^^ubyte {
        ^^ubyte v = result(L_I1)
        add("icmp ")
        add(cond)
        add(" ")
        typed(t, a)
        add(", ")
        addn(b)
        nl()
        return v
    }

    sub binop(str op, ^^ubyte a, ^^ubyte b, ubyte t) -> ^^ubyte {
        ^^ubyte v = result(t)
        add(op)
        add(" ")
        typed(t, a)
        add(", ")
        addn(b)
        nl()
        return v
    }

    ; the flags of comparing a with b, as the VM's cmp sets them: carry means unsigned a >= b
    sub set_comparison(^^ubyte a, ^^ubyte b, ubyte t) {
        set_flag("z", icmp("eq", a, b, t))
        set_flag("c", icmp("uge", a, b, t))
        ^^ubyte diff = binop("sub", a, b, t)
        set_flag("n", icmp("slt", diff, int_const(0, t), t))
        ; signed overflow: the operands differ in sign and the result's sign differs from a's
        ^^ubyte signs = binop("xor", a, b, t)
        ^^ubyte rsign = binop("xor", a, diff, t)
        ^^ubyte ovf = binop("and", signs, rsign, t)
        set_flag("v", icmp("slt", ovf, int_const(0, t), t))
    }

    ; branches to target when the flag has the wanted state; execution continues in a fresh block
    sub branch_flag(str flag, bool whenset, ^^ubyte target) {
        ^^ubyte v = get_flag(flag)
        ^^ubyte cont = fresh_block("cont")
        line("br i1 ")
        addn(v)
        if whenset {
            add(", label %")
            addn(target)
            add(", label %")
            addn(cont)
        }
        else {
            add(", label %")
            addn(cont)
            add(", label %")
            addn(target)
        }
        nl()
        block(cont)
    }

    sub branch_if(^^ubyte cond, ^^ubyte target) {
        ^^ubyte cont = fresh_block("cont")
        line("br i1 ")
        addn(cond)
        add(", label %")
        addn(target)
        add(", label %")
        addn(cont)
        nl()
        block(cont)
    }

    sub jump_to(^^ubyte target) {
        line("br label %")
        addn(target)
        nl()
        terminated = true
    }

    ; ---- functions ----

    sub param_local(^^ubyte name) -> ^^ubyte {
        ^^ubyte lname = ident2("local.", name)
        buf.clear(nb)
        buf.add_byte(nb, '%')
        buf.add_str(nb, lname)
        return keep_nb()
    }

    sub return_ltype(^^ir.Sub s) -> ubyte {
        if s.returns[0] == 0
            return L_VOID
        ; several results go through the hardware slots; the text then has a comma
        long i = 0
        while s.returns[i] != 0 {
            if s.returns[i] == ','
                return L_VOID
            i++
        }
        return lt_of_typestr(s.returns)
    }

    sub function(^^ir.Sub s) {
        cursub = s
        crumb.name = s.name
        if not irparse.expand(s) {
            errors++
            return
        }
        buf.clear(fb)
        buf.clear(pb)
        value_seq = 0
        scan_registers(s)
        cur_return = return_ltype(s)
        ; the header
        emit("define internal ")
        emit(ltname(cur_return))
        emit(" @")
        emit(ident(s.name))
        emit("(")
        ^^ir.Param p = s.params
        uword pn = 0
        while p != 0 {
            if pn != 0
                emit(", ")
            emit(ltname(lt_of_typestr(p.typestr)))
            emit(" %p")
            buf.clear(nb)
            buf.add_long(nb, pn)
            emit(nb.data)
            pn++
            p = p.next
        }
        emit(") {\nentry:\n")
        ; the prologue: parameter stores (allocas are added as they are found)
        p = s.params
        pn = 0
        while p != 0 {
            ubyte pt = lt_of_typestr(p.typestr)
            ^^ir.Var pv = find_var(p.name)
            buf.add_str(pb, "  store ")
            buf.add_str(pb, ltname(pt))
            buf.add_str(pb, " %p")
            buf.add_long(pb, pn)
            buf.add_str(pb, ", ptr ")
            if pv != 0 and pv.stacklocal {
                buf.add_byte(pb, '%')
                buf.add_str(pb, ident2("local.", p.name))
            }
            else {
                buf.add_byte(pb, '@')
                buf.add_str(pb, ident(p.name))
            }
            if pt != L_I8
                buf.add_str(pb, ", align 1")
            buf.add_byte(pb, '\n')
            pn++
            p = p.next
        }
        ; the first chunk is entered from the prologue
        ^^ubyte first = 0
        if s.chunks != 0 {
            first = chunk_label(s.chunks)
            buf.add_str(pb, "  br label %")
            buf.add_str(pb, first)
            buf.add_byte(pb, '\n')
        }
        else
            buf.add_str(pb, "  ret void\n")
        ; the body
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            lower_chunk(c)
            c = c.next
        }
        ; the allocas: register slots, flags and locals
        buf.add_str(outbuf, "  %flag.c = alloca i1\n  %flag.z = alloca i1\n  %flag.n = alloca i1\n  %flag.v = alloca i1\n  store i1 false, ptr %flag.c\n  store i1 false, ptr %flag.z\n  store i1 false, ptr %flag.n\n  store i1 false, ptr %flag.v\n")
        long r = 1
        while r < slot_cap {
            if slot_type[r] != L_VOID {
                buf.add_str(outbuf, "  %r")
                buf.add_long(outbuf, r)
                buf.add_str(outbuf, ".slot = alloca ")
                buf.add_str(outbuf, ltname(slot_type[r]))
                buf.add_byte(outbuf, '\n')
            }
            r++
        }
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.stacklocal and v.owner == s {
                ubyte vt = lt_of_typestr(v.typestr)
                ^^ubyte lname2 = ident2("local.", v.name)
                buf.add_str(outbuf, "  %")
                buf.add_str(outbuf, lname2)
                buf.add_str(outbuf, " = alloca ")
                buf.add_str(outbuf, ltname(vt))
                buf.add_str(outbuf, "\n  store ")
                buf.add_str(outbuf, ltname(vt))
                if vt == L_PTR
                    buf.add_str(outbuf, " null")
                else if vt == L_DOUBLE
                    buf.add_str(outbuf, " 0.0")
                else
                    buf.add_str(outbuf, " 0")
                buf.add_str(outbuf, ", ptr %")
                buf.add_str(outbuf, lname2)
                buf.add_byte(outbuf, '\n')
            }
            v = v.next
        }
        buf.add_bytes(outbuf, pb.data, pb.len)
        buf.add_bytes(outbuf, fb.data, fb.len)
        emit("}\n\n")
        cursub = 0
    }

    ; a chunk's block name: its label, or a generated one kept in its text field
    sub chunk_label(^^ir.Chunk c) -> ^^ubyte {
        if c.label != 0
            return ident(c.label)
        if c.text == 0 or c.kind == ir.C_ASM {
            c.text = fresh_block("chunk")
            c.kind = ir.C_CODE
        }
        return c.text
    }

    sub lower_chunk(^^ir.Chunk c) {
        if c.kind == ir.C_ASM {
            error("inline assembly cannot be translated to LLVM")
            return
        }
        block(chunk_label(c))
        ^^ir.Instr i = c.first
        while i != 0 {
            if terminated {
                ; code after a jump or return: a block nothing reaches
                block(fresh_block("dead"))
            }
            lower(i)
            i = i.next
        }
        if not terminated {
            if c.next != 0
                jump_to(chunk_label(c.next))
            else
                end_function()
        }
    }

    sub end_function() {
        if cur_return == L_VOID
            line("ret void\n")
        else
            line("unreachable\n")
        terminated = true
    }

    ; ---- instructions ----

    sub lower(^^ir.Instr i) {
        ubyte op = i.op
        if op >= ir.OP_BSTCC and op <= ir.OP_BLES {
            lower_branch(i)
            return
        }
        when op {
            ir.OP_NOP -> {
            }
            ir.OP_LOAD -> {
                if i.sym != 0
                    write(i.r1, symbol_address(i.sym, i.offset), L_PTR)
                else if i.type == ir.T_FLOAT
                    write(i.r1, float_const(i.fvalue), L_DOUBLE)
                else
                    write(i.r1, int_const(i.value, lt(i.type)), lt(i.type))
            }
            ir.OP_LOADR -> {
                ^^ubyte v
                ubyte t
                v, t = read_wide(i.r2, i.type)
                write(i.r1, v, t)
            }
            ir.OP_LOADM, ir.OP_LOADX, ir.OP_LOADI, ir.OP_LOADMZ -> {
                ^^ubyte a = memory_address(i)
                write(i.r1, load_from(a, lt(i.type)), lt(i.type))
            }
            ir.OP_STOREM, ir.OP_STOREX, ir.OP_STOREI -> {
                ^^ubyte sv
                ubyte st
                sv, st = read_wide(i.r1, i.type)
                ^^ubyte a2 = memory_address(i)
                store_to(a2, convert(sv, st, lt(i.type)), lt(i.type))
            }
            ir.OP_STOREZM, ir.OP_STOREZX, ir.OP_STOREZI -> {
                ^^ubyte a3 = memory_address(i)
                ubyte zt = lt(i.type)
                if zt == L_DOUBLE
                    store_to(a3, "0.0", zt)
                else
                    store_to(a3, int_const(0, zt), zt)
            }
            ir.OP_STOREIM -> {
                ^^ubyte a4 = memory_address(i)
                if i.type == ir.T_FLOAT
                    store_to(a4, float_const(i.fvalue), L_DOUBLE)
                else
                    store_to(a4, int_const(i.value, lt(i.type)), lt(i.type))
            }
            ir.OP_LOADHR -> {
                ^^ubyte hs = hardware_slot(i.slot, i.type == ir.T_FLOAT)
                if i.type == ir.T_FLOAT
                    write(i.r1, load_from(hs, L_DOUBLE), L_DOUBLE)
                else
                    write(i.r1, load_from(hs, L_I64), L_I64)
            }
            ir.OP_STOREHR -> {
                ^^ubyte hs2 = hardware_slot(i.slot, i.type == ir.T_FLOAT)
                ^^ubyte hv
                ubyte ht
                hv, ht = read_wide(i.r1, i.type)
                if i.type == ir.T_FLOAT
                    store_to(hs2, hv, L_DOUBLE)
                else
                    store_to(hs2, convert(hv, ht, L_I64), L_I64)
            }
            ir.OP_PUSH -> {
                ^^ubyte pv
                ubyte pt
                pv, pt = read_wide(i.r1, i.type)
                push_value(pv, pt)
            }
            ir.OP_POP -> {
                ubyte popt = lt(i.type)
                if i.type == ir.T_LONG
                    popt = L_I64
                write(i.r1, pop_value(popt), popt)
            }
            ir.OP_PUSHST -> push_status()
            ir.OP_POPST -> pop_status()
            ir.OP_JUMP -> jump_to(ident(i.sym))
            ir.OP_JUMPI -> {
                ^^ubyte jp = pointer_value(i.r1, ir.T_POINTER)
                line("call void ")
                addn(jp)
                add("()\n")
                end_function_return()
            }
            ir.OP_RETURN -> end_function_return()
            ir.OP_RETURNR -> {
                ^^ubyte rv
                ubyte rt
                rv, rt = read_wide(i.r1, i.type)
                ^^ubyte rvc = convert(rv, rt, cur_return)
                line("ret ")
                typed(cur_return, rvc)
                nl()
                terminated = true
            }
            ir.OP_RETURNI -> {
                line("ret ")
                if cur_return == L_DOUBLE
                    typed(L_DOUBLE, float_const(i.fvalue))
                else
                    typed(cur_return, int_const(i.value, cur_return))
                nl()
                terminated = true
            }
            ir.OP_CMP -> {
                ^^ubyte ca = read(i.r1, i.type)
                ^^ubyte cb = read(i.r2, i.type)
                ubyte ct = lt(i.type)
                ubyte cbt = ct
                ca, ct = as_int(ca, ct)
                cb, cbt = as_int(cb, cbt)
                set_comparison(ca, cb, ct)
            }
            ir.OP_CMPI -> {
                ^^ubyte ia = read(i.r1, i.type)
                ubyte it = lt(i.type)
                ia, it = as_int(ia, it)
                set_comparison(ia, int_const(i.value, it), it)
            }
            ir.OP_SEC -> set_flag("c", "true")
            ir.OP_CLC -> set_flag("c", "false")
            ir.OP_SEI, ir.OP_CLI, ir.OP_BREAKPOINT -> {
            }
            ir.OP_SGN -> lower_sgn(i)
            ir.OP_BITTST -> {
                ^^ubyte bv = read(i.r1, i.type)
                ubyte bt = lt(i.type)
                bv, bt = as_int(bv, bt)
                ^^ubyte bit = binop("and", bv, int_const(1 << (i.value as ubyte), bt), bt)
                set_flag("z", icmp("eq", bit, int_const(0, bt), bt))
            }
            ir.OP_FCOMP -> {
                ^^ubyte fa = read(i.r2, ir.T_FLOAT)
                ^^ubyte fbv = read(i.r3, ir.T_FLOAT)
                ^^ubyte lt1 = fcmp("olt", fa, fbv)
                ^^ubyte gt1 = fcmp("ogt", fa, fbv)
                write(i.r1, minus_zero_plus(lt1, gt1), L_I8)
            }
            ir.OP_CALL -> lower_call(i)
            ir.OP_CALLI -> {
                ; A call of the code at an address, without arguments.  The word it may
                ; return goes to slot 10, where the IR of call() takes it from.  WebAssembly
                ; wants the exact type of what is called: there it is called as "void ()",
                ; and a subroutine that returns a value is reached by its indirect entry
                ; (indirect_entry), which leaves the value in the slot.
                ^^ubyte cp = pointer_value(i.r1, ir.T_POINTER)
                ^^ubyte cslot = hardware_slot(10, false)
                if strict {
                    store_to(cslot, int_const(0, L_I64), L_I64)
                    line("call void ")
                    addn(cp)
                    add("()\n")
                }
                else {
                    ^^ubyte cr = result(L_I16)
                    add("call i16 ")
                    addn(cp)
                    add("()")
                    nl()
                    store_to(cslot, convert(cr, L_I16, L_I64), L_I64)
                }
            }
            ir.OP_SYSCALL -> lower_syscall(i)
            ir.OP_INC, ir.OP_INCM, ir.OP_DEC, ir.OP_DECM, ir.OP_NEG, ir.OP_NEGM, ir.OP_INV, ir.OP_INVM,
            ir.OP_ADD, ir.OP_ADDR, ir.OP_ADDM, ir.OP_ADDIM, ir.OP_SUB, ir.OP_SUBR, ir.OP_SUBM, ir.OP_SUBIM,
            ir.OP_MUL, ir.OP_MULR, ir.OP_MULM, ir.OP_MULS, ir.OP_MULSR, ir.OP_MULSM,
            ir.OP_AND, ir.OP_ANDR, ir.OP_ANDM, ir.OP_OR, ir.OP_ORR, ir.OP_ORM, ir.OP_XOR, ir.OP_XORR, ir.OP_XORM,
            ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_LSLN, ir.OP_LSRN, ir.OP_ASRN, ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI,
            ir.OP_LSLM, ir.OP_LSRM, ir.OP_ASRM, ir.OP_LSLNM, ir.OP_LSRNM, ir.OP_ASRNM,
            ir.OP_ROL, ir.OP_ROR, ir.OP_ROXL, ir.OP_ROXR, ir.OP_ROLM, ir.OP_RORM, ir.OP_ROXLM, ir.OP_ROXRM,
            ir.OP_BITSET, ir.OP_BITCLR, ir.OP_BITTOG -> lower_modify(i)
            ir.OP_DIV, ir.OP_DIVR, ir.OP_DIVM, ir.OP_DIVS, ir.OP_DIVSR, ir.OP_DIVSM,
            ir.OP_MOD, ir.OP_MODR, ir.OP_MODS, ir.OP_MODSR -> lower_divide(i)
            ir.OP_DIVMODR, ir.OP_DIVMOD, ir.OP_SDIVMODR, ir.OP_SDIVMOD -> lower_divmod(i)
            ir.OP_SQUARE -> {
                ^^ubyte sq = read(i.r2, i.type)
                write(i.r1, binop(mul_op(i.type), sq, sq, lt(i.type)), lt(i.type))
            }
            ir.OP_SQRT -> lower_sqrt(i)
            ir.OP_EXT, ir.OP_EXTS, ir.OP_EXTL, ir.OP_EXTLS, ir.OP_EXTQ, ir.OP_EXTQS -> {
                bool signed = op == ir.OP_EXTS or op == ir.OP_EXTLS or op == ir.OP_EXTQS
                ubyte dt = i.t1
                if dt == ir.T_NONE
                    dt = ir.reg_type(i.r1)
                ^^ubyte ev = read(i.r2, i.type)
                ubyte et = lt(i.type)
                ev, et = as_int(ev, et)
                write(i.r1, widen(ev, et, lt(dt), signed), lt(dt))
            }
            ir.OP_LSIGB, ir.OP_LSIGW, ir.OP_LSIGL, ir.OP_MSIGB, ir.OP_MSIGW -> {
                ubyte xt = i.t1
                if xt == ir.T_NONE
                    xt = ir.reg_type(i.r1)
                ^^ubyte xv = read(i.r2, i.type)
                ubyte xlt = lt(i.type)
                xv, xlt = as_int(xv, xlt)
                ubyte shift = 0
                if op == ir.OP_MSIGB {
                    shift = 8
                    if i.type != ir.T_WORD
                        shift = 24
                }
                else if op == ir.OP_MSIGW
                    shift = 16
                if shift != 0
                    xv = binop("lshr", xv, int_const(shift, xlt), xlt)
                write(i.r1, convert(xv, xlt, lt(xt)), lt(xt))
            }
            ir.OP_CONCAT -> {
                ubyte ct2 = i.t1
                if ct2 == ir.T_NONE
                    ct2 = ir.reg_type(i.r1)
                ubyte wt = lt(ct2)
                ^^ubyte upper = convert(read(i.r2, i.type), lt(i.type), wt)
                ^^ubyte lowerv = convert(read(i.r3, i.type), lt(i.type), wt)
                ^^ubyte shifted = binop("shl", upper, int_const(ltype_bits[lt(i.type)], wt), wt)
                write(i.r1, binop("or", shifted, lowerv, wt), wt)
            }
            ir.OP_FFROMUB, ir.OP_FFROMUW -> {
                ubyte st2 = i.t2
                if st2 == ir.T_NONE
                    st2 = ir.reg_type(i.r2)
                ^^ubyte uv = read(i.r2, st2)
                ^^ubyte fr = result(L_DOUBLE)
                add("uitofp ")
                typed(lt(st2), uv)
                add(" to double\n")
                write(i.r1, fr, L_DOUBLE)
            }
            ir.OP_FFROMSB, ir.OP_FFROMSW, ir.OP_FFROMSL -> {
                ubyte st3 = i.t2
                if st3 == ir.T_NONE
                    st3 = ir.reg_type(i.r2)
                ^^ubyte sv3 = read(i.r2, st3)
                ^^ubyte fr2 = result(L_DOUBLE)
                add("sitofp ")
                typed(lt(st3), sv3)
                add(" to double\n")
                write(i.r1, fr2, L_DOUBLE)
            }
            ir.OP_FTOUB, ir.OP_FTOSB, ir.OP_FTOUW, ir.OP_FTOSW, ir.OP_FTOSL -> {
                ubyte dt2 = i.t1
                if dt2 == ir.T_NONE
                    dt2 = ir.reg_type(i.r1)
                ^^ubyte fv = read(i.r2, ir.T_FLOAT)
                ^^ubyte iv = result(L_I32)
                add("call i32 @llvm.fptosi.sat.i32.f64(double ")
                addn(fv)
                add(")\n")
                declare("llvm.fptosi.sat.i32.f64", "declare i32 @llvm.fptosi.sat.i32.f64(double)")
                write(i.r1, convert(iv, L_I32, lt(dt2)), lt(dt2))
            }
            ir.OP_FSIN, ir.OP_FCOS, ir.OP_FTAN, ir.OP_FATAN, ir.OP_FLN, ir.OP_FLOG, ir.OP_FROUND, ir.OP_FFLOOR, ir.OP_FCEIL, ir.OP_FABS -> {
                ^^ubyte farg = read(i.r2, ir.T_FLOAT)
                write(i.r1, float_function(op, farg), L_DOUBLE)
            }
            ir.OP_FPOW -> {
                ^^ubyte base = read(i.r1, ir.T_FLOAT)
                ^^ubyte expo = read(i.r2, ir.T_FLOAT)
                ^^ubyte pr = result(L_DOUBLE)
                add("call double @llvm.pow.f64(double ")
                addn(base)
                add(", double ")
                addn(expo)
                add(")\n")
                declare("llvm.pow.f64", "declare double @llvm.pow.f64(double, double)")
                write(i.r1, pr, L_DOUBLE)
            }
            else -> {
                buf.clear(nb)
                buf.add_str(nb, "unsupported instruction ")
                buf.add_str(nb, ir.opcode_names[op])
                buf.add_byte(nb, 0)
                error(nb.data)
            }
        }
    }

    sub end_function_return() {
        if cur_return == L_VOID
            line("ret void\n")
        else if cur_return == L_DOUBLE
            line("ret double 0.0\n")
        else if cur_return == L_PTR
            line("ret ptr null\n")
        else {
            line("ret ")
            typed(cur_return, "0")
            nl()
        }
        terminated = true
    }

    sub fcmp(str cond, ^^ubyte a, ^^ubyte b) -> ^^ubyte {
        ^^ubyte v = result(L_I1)
        add("fcmp ")
        add(cond)
        add(" double ")
        addn(a)
        add(", ")
        addn(b)
        nl()
        return v
    }

    ; the byte -1, 0 or 1 from two i1 values
    sub minus_zero_plus(^^ubyte negative, ^^ubyte positive) -> ^^ubyte {
        ^^ubyte m = convert(negative, L_I1, L_I8)
        ^^ubyte p = convert(positive, L_I1, L_I8)
        return binop("sub", p, m, L_I8)
    }

    sub lower_sgn(^^ir.Instr i) {
        ^^ubyte v = read(i.r2, i.type)
        ubyte t = lt(i.type)
        ^^ubyte neg
        ^^ubyte pos
        if t == L_DOUBLE {
            neg = fcmp("olt", v, "0.0")
            pos = fcmp("ogt", v, "0.0")
        }
        else {
            v, t = as_int(v, t)
            neg = icmp("slt", v, int_const(0, t), t)
            pos = icmp("sgt", v, int_const(0, t), t)
        }
        ^^ubyte sign = minus_zero_plus(neg, pos)
        write(i.r1, sign, L_I8)
        set_comparison(sign, "0", L_I8)
    }

    ; a conditional branch comparing a register with a register or an immediate
    sub lower_branch(^^ir.Instr i) {
        ubyte op = i.op
        if op == ir.OP_BSTCC {
            branch_flag("c", false, i.sym)
            return
        }
        if op == ir.OP_BSTCS {
            branch_flag("c", true, i.sym)
            return
        }
        if op == ir.OP_BSTEQ {
            branch_flag("z", true, i.sym)
            return
        }
        if op == ir.OP_BSTNE {
            branch_flag("z", false, i.sym)
            return
        }
        if op == ir.OP_BSTNEG {
            branch_flag("n", true, i.sym)
            return
        }
        if op == ir.OP_BSTPOS {
            branch_flag("n", false, i.sym)
            return
        }
        if op == ir.OP_BSTVS {
            branch_flag("v", true, i.sym)
            return
        }
        if op == ir.OP_BSTVC {
            branch_flag("v", false, i.sym)
            return
        }
        ^^ubyte cond
        when op {
            ir.OP_BGTR, ir.OP_BGT -> cond = "ugt"
            ir.OP_BLT -> cond = "ult"
            ir.OP_BGER, ir.OP_BGE -> cond = "uge"
            ir.OP_BLE -> cond = "ule"
            ir.OP_BGTSR, ir.OP_BGTS -> cond = "sgt"
            ir.OP_BLTS -> cond = "slt"
            ir.OP_BGESR, ir.OP_BGES -> cond = "sge"
            else -> cond = "sle"
        }
        ^^ubyte a = read(i.r1, i.type)
        ubyte t = lt(i.type)
        a, t = as_int(a, t)
        ^^ubyte b
        if i.mode == ir.M_RRT {
            b = read(i.r2, i.type)
            ubyte bt = lt(i.type)
            b, bt = as_int(b, bt)
            b = convert(b, bt, t)
        }
        else
            b = int_const(i.value, t)
        branch_if(icmp(cond, a, b, t), ident(i.sym))
    }

    sub mul_op(ubyte irtype) -> ^^ubyte {
        if irtype == ir.T_FLOAT
            return "fmul"
        return "mul"
    }

    ; the operand of a register-or-memory modifying instruction, and the store back
    sub lower_modify(^^ir.Instr i) {
        ubyte op = i.op
        ubyte t = lt(i.type)
        bool to_memory = i.mode == ir.M_M or i.mode == ir.M_RM or i.mode == ir.M_IM
        bool uses_reg_operand = i.mode == ir.M_RM     ; addm r1,[mem]: memory op= r1
        ^^ubyte addr = 0
        ^^ubyte left
        ubyte lt0 = t
        if to_memory {
            addr = memory_address(i)
            left = load_from(addr, t)
        }
        else {
            left, lt0 = read_wide(i.r1, i.type)
        }
        ^^ubyte right = 0
        ubyte rt = t
        bool have_right = false
        if i.mode == ir.M_RR {
            right, rt = read_wide(i.r2, i.type)
            have_right = true
        }
        else if i.mode == ir.M_RM {
            right, rt = read_wide(i.r1, i.type)
            have_right = true
        }
        else if i.mode == ir.M_RI or i.mode == ir.M_IM {
            if i.type == ir.T_FLOAT
                right = float_const(i.fvalue)
            else
                right = int_const(i.value, t)
            rt = t
            have_right = true
        }
        ^^ubyte res
        when op {
            ir.OP_INC, ir.OP_INCM -> res = step(left, lt0, true)
            ir.OP_DEC, ir.OP_DECM -> res = step(left, lt0, false)
            ir.OP_NEG, ir.OP_NEGM -> res = negate(left, lt0)
            ir.OP_INV, ir.OP_INVM -> {
                left, lt0 = as_int(left, lt0)
                res = binop("xor", left, int_const(-1, lt0), lt0)
                result_type = lt0
            }
            ir.OP_ADD, ir.OP_ADDR, ir.OP_ADDM, ir.OP_ADDIM -> res = arith("add", left, lt0, right, rt)
            ir.OP_SUB, ir.OP_SUBR, ir.OP_SUBM, ir.OP_SUBIM -> res = arith("sub", left, lt0, right, rt)
            ir.OP_MUL, ir.OP_MULR, ir.OP_MULM, ir.OP_MULS, ir.OP_MULSR, ir.OP_MULSM -> {
                if i.type == ir.T_WORD and lt0 == L_I16 and rt == L_I16 {
                    ; the upper 16 bits of the 32-bit product, for math.mul16_last_upper
                    bool signed_mul = op == ir.OP_MULS or op == ir.OP_MULSR or op == ir.OP_MULSM
                    ^^ubyte wl = widen(left, L_I16, L_I32, signed_mul)
                    ^^ubyte wr = widen(right, L_I16, L_I32, signed_mul)
                    ^^ubyte product = binop("mul", wl, wr, L_I32)
                    ^^ubyte upper = binop("lshr", product, "16", L_I32)
                    declare(".math.mul16_upper", "@.math.mul16_upper = internal global i16 0")
                    store_to("@.math.mul16_upper", convert(upper, L_I32, L_I16), L_I16)
                    res = convert(product, L_I32, L_I16)
                    result_type = L_I16
                }
                else
                    res = arith("mul", left, lt0, right, rt)
            }
            ir.OP_AND, ir.OP_ANDR, ir.OP_ANDM -> res = arith("and", left, lt0, right, rt)
            ir.OP_OR, ir.OP_ORR, ir.OP_ORM -> res = arith("or", left, lt0, right, rt)
            ir.OP_XOR, ir.OP_XORR, ir.OP_XORM -> res = arith("xor", left, lt0, right, rt)
            ir.OP_LSL, ir.OP_LSLM -> res = shift_once(left, lt0, "shl")
            ir.OP_LSR, ir.OP_LSRM -> res = shift_once(left, lt0, "lshr")
            ir.OP_ASR, ir.OP_ASRM -> res = shift_once(left, lt0, "ashr")
            ir.OP_LSLN, ir.OP_LSLI, ir.OP_LSLNM -> res = shift_by(left, lt0, i, "shl")
            ir.OP_LSRN, ir.OP_LSRI, ir.OP_LSRNM -> res = shift_by(left, lt0, i, "lshr")
            ir.OP_ASRN, ir.OP_ASRI, ir.OP_ASRNM -> res = shift_by(left, lt0, i, "ashr")
            ir.OP_ROL, ir.OP_ROLM -> res = rotate(left, lt0, true, false)
            ir.OP_ROR, ir.OP_RORM -> res = rotate(left, lt0, false, false)
            ir.OP_ROXL, ir.OP_ROXLM -> res = rotate(left, lt0, true, true)
            ir.OP_ROXR, ir.OP_ROXRM -> res = rotate(left, lt0, false, true)
            ir.OP_BITSET -> {
                left, lt0 = as_int(left, lt0)
                res = binop("or", left, int_const(1 << (i.value as ubyte), lt0), lt0)
            }
            ir.OP_BITCLR -> {
                left, lt0 = as_int(left, lt0)
                res = binop("and", left, int_const(~(1 << (i.value as ubyte)), lt0), lt0)
            }
            ir.OP_BITTOG -> {
                left, lt0 = as_int(left, lt0)
                res = binop("xor", left, int_const(1 << (i.value as ubyte), lt0), lt0)
            }
            else -> res = left
        }
        ; the result has the type of the (possibly integer-converted) left operand
        ubyte restype = result_type
        if to_memory
            store_to(addr, convert(res, restype, t), t)
        else
            write(i.r1, res, restype)
    }

    ubyte result_type = L_I8          ; the type of the last arithmetic result

    ; left op right: floats with f-operations, a pointer plus an integer as a byte offset
    sub arith(str op, ^^ubyte left, ubyte lt0, ^^ubyte right, ubyte rt) -> ^^ubyte {
        if lt0 == L_DOUBLE {
            result_type = L_DOUBLE
            buf.clear(nb)
            buf.add_byte(nb, 'f')
            buf.add_str(nb, op)
            return binop(keep_nb(), left, right, L_DOUBLE)
        }
        if lt0 == L_PTR and rt != L_PTR and (strings.compare(op, "add") == 0 or strings.compare(op, "sub") == 0) {
            ^^ubyte off = widen(right, rt, L_I64, true)
            if strings.compare(op, "sub") == 0
                off = negate(off, L_I64)
            ^^ubyte r = result(L_PTR)
            add("getelementptr i8, ptr ")
            addn(left)
            add(", i64 ")
            addn(off)
            nl()
            result_type = L_PTR
            return r
        }
        left, lt0 = as_int(left, lt0)
        right, rt = as_int(right, rt)
        ^^ubyte operand
        if ltype_bits[rt] < ltype_bits[lt0]
            operand = widen(right, rt, lt0, true)
        else
            operand = convert(right, rt, lt0)
        result_type = lt0
        return binop(op, left, operand, lt0)
    }

    sub step(^^ubyte v, ubyte t, bool up) -> ^^ubyte {
        result_type = t
        if t == L_DOUBLE {
            if up
                return binop("fadd", v, "1.0", L_DOUBLE)
            return binop("fsub", v, "1.0", L_DOUBLE)
        }
        if t == L_PTR {
            ^^ubyte r = result(L_PTR)
            add("getelementptr i8, ptr ")
            addn(v)
            if up
                add(", i64 1\n")
            else
                add(", i64 -1\n")
            return r
        }
        if up
            return binop("add", v, int_const(1, t), t)
        return binop("sub", v, int_const(1, t), t)
    }

    sub negate(^^ubyte v, ubyte t) -> ^^ubyte {
        if t == L_DOUBLE {
            result_type = L_DOUBLE
            ^^ubyte r = result(L_DOUBLE)
            add("fneg double ")
            addn(v)
            nl()
            return r
        }
        v, t = as_int(v, t)
        result_type = t
        return binop("sub", int_const(0, t), v, t)
    }

    ; a single shift: the bit shifted out becomes the carry
    sub shift_once(^^ubyte v, ubyte t, str op) -> ^^ubyte {
        v, t = as_int(v, t)
        if strings.compare(op, "shl") == 0
            set_flag("c", icmp("slt", v, int_const(0, t), t))
        else
            set_flag("c", convert(v, t, L_I1))
        result_type = t
        return binop(op, v, int_const(1, t), t)
    }

    ; a shift by a count, which shifts out everything from the bit width on
    sub shift_by(^^ubyte v, ubyte t, ^^ir.Instr i, str op) -> ^^ubyte {
        v, t = as_int(v, t)
        result_type = t
        quad bits = ltype_bits[t]
        if i.mode == ir.M_RI {
            quad n = i.value
            if n >= 0 and n < bits
                return binop(op, v, int_const(n, t), t)
            if strings.compare(op, "ashr") == 0
                return binop(op, v, int_const(bits - 1, t), t)
            return int_const(0, t)
        }
        ubyte ct = i.t2
        if ct == ir.T_NONE
            ct = ir.reg_type(i.r2)
        ^^ubyte count = convert(read(i.r2, ct), lt(ct), t)
        ^^ubyte inrange = icmp("ult", count, int_const(bits, t), t)
        if strings.compare(op, "ashr") == 0 {
            ^^ubyte limited = select(inrange, count, int_const(bits - 1, t), t)
            return binop(op, v, limited, t)
        }
        ^^ubyte shifted = binop(op, v, count, t)
        return select(inrange, shifted, int_const(0, t), t)
    }

    sub select(^^ubyte cond, ^^ubyte a, ^^ubyte b, ubyte t) -> ^^ubyte {
        ^^ubyte r = result(t)
        add("select i1 ")
        addn(cond)
        add(", ")
        typed(t, a)
        add(", ")
        typed(t, b)
        nl()
        return r
    }

    ; a rotation by one bit through the carry or not; the bit going out becomes the carry
    sub rotate(^^ubyte v, ubyte t, bool left, bool through_carry) -> ^^ubyte {
        v, t = as_int(v, t)
        result_type = t
        ^^ubyte outbit
        if left
            outbit = icmp("slt", v, int_const(0, t), t)
        else
            outbit = convert(v, t, L_I1)
        ^^ubyte incoming = outbit
        if through_carry
            incoming = get_flag("c")
        ^^ubyte inbit = convert(incoming, L_I1, t)
        ^^ubyte shifted
        ^^ubyte placed
        if left {
            shifted = binop("shl", v, int_const(1, t), t)
            placed = inbit
        }
        else {
            shifted = binop("lshr", v, int_const(1, t), t)
            placed = binop("shl", inbit, int_const(ltype_bits[t] - 1, t), t)
        }
        set_flag("c", outbit)
        return binop("or", shifted, placed, t)
    }

    ; division gives the VM's results for a zero divisor: the largest value, or a remainder of 0
    sub lower_divide(^^ir.Instr i) {
        ubyte op = i.op
        bool signed = op == ir.OP_DIVS or op == ir.OP_DIVSR or op == ir.OP_DIVSM or op == ir.OP_MODS or op == ir.OP_MODSR
        bool remainder = op == ir.OP_MOD or op == ir.OP_MODR or op == ir.OP_MODS or op == ir.OP_MODSR
        ubyte t = lt(i.type)
        bool to_memory = i.mode == ir.M_M or i.mode == ir.M_RM or i.mode == ir.M_IM
        ^^ubyte addr = 0
        ^^ubyte left
        if to_memory {
            addr = memory_address(i)
            left = load_from(addr, t)
        }
        else
            left = read(i.r1, i.type)
        ^^ubyte right
        if i.mode == ir.M_RR
            right = read(i.r2, i.type)
        else if i.mode == ir.M_RM
            right = read(i.r1, i.type)
        else if t == L_DOUBLE
            right = float_const(i.fvalue)
        else
            right = int_const(i.value, t)
        ^^ubyte res
        if t == L_DOUBLE {
            ^^ubyte q = binop("fdiv", left, right, L_DOUBLE)
            ^^ubyte zero = fcmp("oeq", right, "0.0")
            res = select(zero, "0x7FEFFFFFFFFFFFFF", q, L_DOUBLE)
        }
        else {
            ubyte lt0 = t
            left, lt0 = as_int(left, t)
            right, lt0 = as_int(right, t)
            res = quotient(left, right, lt0, signed, remainder)
        }
        if to_memory
            store_to(addr, res, t)
        else
            write(i.r1, res, t)
    }

    sub quotient(^^ubyte dividend, ^^ubyte divisor, ubyte t, bool signed, bool remainder) -> ^^ubyte {
        quad byzero = -1
        if remainder
            byzero = 0
        else if signed
            byzero = (1 << (ltype_bits[t] - 1)) - 1
        ; a signed division works one size wider, where MIN / -1 does not overflow
        ubyte ct = t
        if signed and t != L_I64
            ct = t + 1
        ^^ubyte iszero = icmp("eq", divisor, int_const(0, t), t)
        ^^ubyte wd = widen(divisor, t, ct, signed)
        ^^ubyte safe = select(iszero, int_const(1, ct), wd, ct)
        ^^ubyte wn = widen(dividend, t, ct, signed)
        ^^ubyte op
        if signed {
            if remainder
                op = "srem"
            else
                op = "sdiv"
        }
        else if remainder
            op = "urem"
        else
            op = "udiv"
        ^^ubyte r = convert(binop(op, wn, safe, ct), ct, t)
        return select(iszero, int_const(byzero, t), r, t)
    }

    sub lower_divmod(^^ir.Instr i) {
        bool signed = i.op == ir.OP_SDIVMODR or i.op == ir.OP_SDIVMOD
        ubyte t = lt(i.type)
        ^^ubyte dividend = read(i.r1, i.type)
        ^^ubyte divisor
        if i.mode == ir.M_RRI
            divisor = int_const(i.value, t)
        else
            divisor = read(i.r2, i.type)
        ^^ubyte q = quotient(dividend, divisor, t, signed, false)
        ^^ubyte r = quotient(dividend, divisor, t, signed, true)
        write(i.r1, q, t)
        write(i.r2, r, t)
    }

    sub lower_sqrt(^^ir.Instr i) {
        ^^ubyte v = read(i.r2, i.type)
        ubyte t = lt(i.type)
        ubyte dt = i.t1
        if dt == ir.T_NONE
            dt = ir.reg_type(i.r1)
        declare("llvm.sqrt.f64", "declare double @llvm.sqrt.f64(double)")
        if t == L_DOUBLE {
            ^^ubyte fr = result(L_DOUBLE)
            add("call double @llvm.sqrt.f64(double ")
            addn(v)
            add(")\n")
            write(i.r1, fr, L_DOUBLE)
            return
        }
        v, t = as_int(v, t)
        ^^ubyte f = result(L_DOUBLE)
        if i.type == ir.T_LONG
            add("sitofp ")
        else
            add("uitofp ")
        typed(t, v)
        add(" to double\n")
        ^^ubyte root = result(L_DOUBLE)
        add("call double @llvm.sqrt.f64(double ")
        addn(f)
        add(")\n")
        ^^ubyte iv = result(L_I32)
        add("call i32 @llvm.fptosi.sat.i32.f64(double ")
        addn(root)
        add(")\n")
        declare("llvm.fptosi.sat.i32.f64", "declare i32 @llvm.fptosi.sat.i32.f64(double)")
        write(i.r1, convert(iv, L_I32, lt(dt)), lt(dt))
    }

    sub float_function(ubyte op, ^^ubyte arg) -> ^^ubyte {
        ^^ubyte name
        when op {
            ir.OP_FSIN -> name = "llvm.sin.f64"
            ir.OP_FCOS -> name = "llvm.cos.f64"
            ir.OP_FTAN -> name = "tan"
            ir.OP_FATAN -> name = "atan"
            ir.OP_FLN -> name = "llvm.log.f64"
            ir.OP_FLOG -> name = "llvm.log2.f64"
            ir.OP_FROUND -> name = "llvm.roundeven.f64"
            ir.OP_FFLOOR -> name = "llvm.floor.f64"
            ir.OP_FCEIL -> name = "llvm.ceil.f64"
            else -> name = "llvm.fabs.f64"
        }
        buf.clear(nb)
        buf.add_str(nb, "declare double @")
        buf.add_str(nb, name)
        buf.add_str(nb, "(double)")
        declare(name, keep_nb())
        ^^ubyte r = result(L_DOUBLE)
        add("call double @")
        addn(name)
        add("(double ")
        addn(arg)
        add(")\n")
        return r
    }

    ; ---- calls ----

    sub lower_call(^^ir.Instr i) {
        ^^ir.Sub callee = find_sub(i.sym)
        ^^ubyte cname = i.sym
        ubyte rettype = L_VOID
        bool known = callee != 0
        if callee != 0 {
            rettype = return_ltype(callee)
            if callee.is_asm and callee.is_external
                cname = c_name(callee.name)
            else if callee.is_asm {
                error("call of an asmsub")
                return
            }
        }
        else if i.results != 0 {
            ; a routine outside the program: declared with the signature of this call
            ^^ir.Arg r0 = i.results
            rettype = lt(r0.type)
        }
        ; the argument values, converted to the parameter types
        ^^ubyte[32] argvals
        ubyte[32] argtypes
        ubyte nargs = 0
        ^^ir.Arg a = i.args
        ^^ir.Param p = 0
        if callee != 0
            p = callee.params
        while a != 0 and nargs < 32 {
            ubyte pt
            if p != 0
                pt = lt_of_typestr(p.typestr)
            else
                pt = lt(a.type)
            ^^ubyte av
            ubyte at
            if a.reg != 0 {
                av, at = read_wide(a.reg, a.type)
                av = convert(av, at, pt)
            }
            else if a.type == ir.T_FLOAT
                av = float_const(0.0)
            else
                av = int_const(a.value, pt)
            argvals[nargs] = av
            argtypes[nargs] = pt
            nargs++
            a = a.next
            if p != 0
                p = p.next
        }
        if not known
            declare_call(cname, rettype, argtypes, nargs)
        ^^ubyte rv = 0
        if rettype != L_VOID {
            rv = result(rettype)
            add("call ")
        }
        else
            line("call ")
        addn(ltname(rettype))
        add(" @")
        addn(ident(cname))
        add("(")
        ubyte k = 0
        while k < nargs {
            if k != 0
                add(", ")
            typed(argtypes[k], argvals[k])
            k++
        }
        add(")\n")
        if rettype != L_VOID and i.results != 0 {
            ^^ir.Arg r1 = i.results
            if r1.reg != 0
                write(r1.reg, rv, rettype)
        }
    }

    ; the C name of an extsub: the last part of its label
    sub c_name(^^ubyte label) -> ^^ubyte {
        long i = buf.cstr_len(label)
        while i > 0 and label[i - 1] != '.'
            i--
        ^^ubyte plain = strtab.intern(label + i, (buf.cstr_len(label) - i) as uword)
        if windows {
            ; the Microsoft C library has these POSIX routines under another name
            if strings.compare(plain, "popen") == 0
                return "_popen"
            if strings.compare(plain, "pclose") == 0
                return "_pclose"
        }
        return plain
    }

    sub declare_extsub(^^ir.Sub s) {
        buf.clear(nb)
        buf.add_str(nb, "declare ")
        buf.add_str(nb, ltname(return_ltype(s)))
        buf.add_str(nb, " @")
        ^^ubyte cn = c_name(s.name)
        buf.add_str(nb, cn)
        buf.add_byte(nb, '(')
        ^^ir.Param p = s.params
        bool first = true
        while p != 0 {
            if not first
                buf.add_str(nb, ", ")
            first = false
            buf.add_str(nb, ltname(lt_of_typestr(p.typestr)))
            p = p.next
        }
        buf.add_byte(nb, ')')
        declare(cn, keep_nb())
    }

    sub declare_call(^^ubyte cname, ubyte rettype, ^^ubyte argtypes, ubyte nargs) {
        ^^ubyte qname = ident(cname)
        buf.clear(nb)
        buf.add_str(nb, "declare ")
        buf.add_str(nb, ltname(rettype))
        buf.add_str(nb, " @")
        buf.add_str(nb, qname)
        buf.add_byte(nb, '(')
        ubyte k = 0
        while k < nargs {
            if k != 0
                buf.add_str(nb, ", ")
            buf.add_str(nb, ltname(argtypes[k]))
            k++
        }
        buf.add_byte(nb, ')')
        declare(cname, keep_nb())
    }

    ; Adds a declaration or helper definition once.
    ; the file and directory helper functions (src/llvmrt.p8), once per module
    bool file_runtime_done = false
    sub file_runtime() {
        if file_runtime_done
            return
        file_runtime_done = true
        ubyte k
        if c64 {
            for k in 0 to llvmrt.FILE16_DECLARES - 1
                declare(llvmrt.file16_declare_names[k], llvmrt.file16_declares[k])
            for k in 0 to llvmrt.FILE16_CHUNKS - 1
                buf.add_str(decls, llvmrt.file16_text[k])
        }
        else if llvm32 {
            for k in 0 to llvmrt.FILE32_DECLARES - 1
                declare(llvmrt.file32_declare_names[k], profile_text(llvmrt.file32_declares[k]))
            for k in 0 to llvmrt.FILE32_CHUNKS - 1
                buf.add_str(decls, profile_text(llvmrt.file32_text[k]))
        }
        else {
            for k in 0 to llvmrt.FILE_DECLARES - 1
                declare(llvmrt.file_declare_names[k], host_text(llvmrt.file_declares[k]))
            for k in 0 to llvmrt.FILE_CHUNKS - 1
                buf.add_str(decls, host_text(llvmrt.file_text[k]))
        }
        buf.add_byte(decls, '\n')
    }

    ; text with the type of C's int, or of size_t, in the gaps between its parts
    sub join_parts(^^ubyte t, str p1, str p2, str p3, str p4, str p5) -> ^^ubyte {
        ^^buf.Buf cb = buf.new(96)
        buf.add_str(cb, p1)
        buf.add_str(cb, t)
        buf.add_str(cb, p2)
        if p3[0] != 0 or p4[0] != 0 or p5[0] != 0 {
            buf.add_str(cb, t)
            buf.add_str(cb, p3)
        }
        if p4[0] != 0 or p5[0] != 0 {
            buf.add_str(cb, t)
            buf.add_str(cb, p4)
        }
        if p5[0] != 0 {
            buf.add_str(cb, t)
            buf.add_str(cb, p5)
        }
        return strtab.intern(cb.data, cb.len as uword)
    }

    sub int_declare(str before, str after) -> ^^ubyte {
        return join_parts(int_name, before, after, "", "", "")
    }

    sub int_text(str before, str after) -> ^^ubyte {
        return join_parts(int_name, before, after, "", "", "")
    }

    sub int_text3(str p1, str p2, str p3, str p4, str p5) -> ^^ubyte {
        return join_parts(int_name, p1, p2, p3, p4, p5)
    }

    sub size_text(str before, str after) -> ^^ubyte {
        return join_parts(size_name, before, after, "", "", "")
    }

    sub size_text3(str p1, str p2, str p3) -> ^^ubyte {
        return join_parts(size_name, p1, p2, p3, "", "")
    }

    sub declare_putchar() {
        declare("putchar", int_text3("declare ", " @putchar(", ")", "", ""))
    }

    ; The helper text was taken from a program for arm64 macOS.  Two things in it
    ; differ on the other hosts: where readdir()'s struct dirent has its name (the
    ; "i32 21" of the one getelementptr on %dirent), and on Intel macOS the names of
    ; opendir and readdir.  Gives the text for the host, the same text when nothing changes.
    ; The helper text of llvm32 was taken from a program for WebAssembly.  The
    ; triple profile says where the dirent has its name there (the "i32 9"), and
    ; which C routine readdir is.
    sub profile_text(^^ubyte text) -> ^^ubyte {
        bool other_readdir = strings.compare(triple.readdir_symbol, "readdir") != 0
        if triple.dirent_name_offset == 9 and not other_readdir
            return text
        ^^buf.Buf hb = buf.new(300)
        long i = 0
        while text[i] != 0 {
            if buf.bytes_equal(text + i, "ptr %dirent, i32 9", 18) {
                buf.add_str(hb, "ptr %dirent, i32 ")
                buf.add_long(hb, triple.dirent_name_offset)
                i += 18
            }
            else if other_readdir and buf.bytes_equal(text + i, "@readdir(", 9) {
                buf.add_byte(hb, '@')
                buf.add_str(hb, triple.readdir_symbol)
                buf.add_byte(hb, '(')
                i += 9
            }
            else {
                buf.add_byte(hb, text[i])
                i++
            }
        }
        return strtab.intern(hb.data, hb.len as uword)
    }

    sub host_text(^^ubyte text) -> ^^ubyte {
        if not linux and not intel_mac and not windows
            return text
        ^^buf.Buf hb = buf.new(300)
        long i = 0
        while text[i] != 0 {
            if linux and buf.bytes_equal(text + i, "ptr %dirent, i32 21", 19) {
                buf.add_str(hb, "ptr %dirent, i32 19")
                i += 19
            }
            else if windows and buf.bytes_equal(text + i, "ptr %dirent, i32 21", 19) {
                buf.add_str(hb, "ptr %dirent, i32 0")
                i += 19
            }
            else if windows and buf.bytes_equal(text + i, "@fseek(", 7) {
                buf.add_str(hb, "@_fseeki64(")
                i += 7
            }
            else if windows and buf.bytes_equal(text + i, "@ftell(", 7) {
                buf.add_str(hb, "@_ftelli64(")
                i += 7
            }
            else if intel_mac and buf.bytes_equal(text + i, "@opendir(", 9) {
                buf.add_str(hb, "@\"opendir$INODE64\"(")
                i += 9
            }
            else if intel_mac and buf.bytes_equal(text + i, "@readdir(", 9) {
                buf.add_str(hb, "@\"readdir$INODE64\"(")
                i += 9
            }
            else {
                buf.add_byte(hb, text[i])
                i++
            }
        }
        return strtab.intern(hb.data, hb.len as uword)
    }

    ; a C declaration with the type of size_t and long between its two parts
    sub c_declare(str before, str after) -> ^^ubyte {
        ^^buf.Buf cb = buf.new(64)
        buf.add_str(cb, before)
        buf.add_str(cb, size_name)
        buf.add_str(cb, after)
        return strtab.intern(cb.data, cb.len as uword)
    }

    sub declare(^^ubyte name, ^^ubyte text) {
        ^^ubyte key = strtab.intern_cstr(name)
        uword k = 0
        while k < declared_count {
            if declared[k] == key
                return
            k++
        }
        if declared_count >= declared_cap {
            uword newcap = declared_cap * 2
            if newcap < 64
                newcap = 64
            declared = mem.grow(declared, declared_cap * sizeof(pointer), newcap * sizeof(pointer))
            declared_cap = newcap
        }
        declared[declared_count] = key
        declared_count++
        buf.add_str(decls, text)
        buf.add_str(decls, "\n\n")
    }

    ; the global of a hardware slot
    sub hardware_slot(ubyte slot, bool is_float) -> ^^ubyte {
        buf.clear(nb)
        if is_float {
            buf.add_str(nb, ".slot.f")
            buf.add_long(nb, slot)
            ^^ubyte fname = keep_nb()
            buf.clear(nb)
            buf.add_byte(nb, '@')
            buf.add_str(nb, fname)
            buf.add_str(nb, " = internal global double 0.0")
            declare(fname, keep_nb())
            buf.clear(nb)
            buf.add_byte(nb, '@')
            buf.add_str(nb, fname)
            return keep_nb()
        }
        buf.add_str(nb, ".slot.s")
        buf.add_long(nb, slot)
        ^^ubyte sname = keep_nb()
        buf.clear(nb)
        buf.add_byte(nb, '@')
        buf.add_str(nb, sname)
        buf.add_str(nb, " = internal global i64 0")
        declare(sname, keep_nb())
        buf.clear(nb)
        buf.add_byte(nb, '@')
        buf.add_str(nb, sname)
        return keep_nb()
    }

    ; ---- the value stack ----

    sub stack_globals() {
        declare(".stack.top", "@.stack.top = internal global i64 0")
        declare(".stack.data", "@.stack.data = internal global [1024 x i8] zeroinitializer")
    }

    sub push_value(^^ubyte v, ubyte t) {
        stack_globals()
        ^^ubyte sp = load_from("@.stack.top", L_I64)
        ^^ubyte entry = result(L_PTR)
        add("getelementptr i8, ptr @.stack.data, i64 ")
        addn(sp)
        nl()
        store_to(entry, v, t)
        ^^ubyte nsp = binop("add", sp, int_const(ltype_bits[t] / 8, L_I64), L_I64)
        store_to("@.stack.top", nsp, L_I64)
    }

    sub pop_value(ubyte t) -> ^^ubyte {
        stack_globals()
        ^^ubyte sp = load_from("@.stack.top", L_I64)
        ^^ubyte nsp = binop("sub", sp, int_const(ltype_bits[t] / 8, L_I64), L_I64)
        store_to("@.stack.top", nsp, L_I64)
        ^^ubyte entry = result(L_PTR)
        add("getelementptr i8, ptr @.stack.data, i64 ")
        addn(nsp)
        nl()
        return load_from(entry, t)
    }

    ; the status byte of pushst/popst: N bit 7, V bit 6, Z bit 1, C bit 0
    sub push_status() {
        ^^ubyte n = binop("shl", convert(get_flag("n"), L_I1, L_I8), "7", L_I8)
        ^^ubyte v = binop("shl", convert(get_flag("v"), L_I1, L_I8), "6", L_I8)
        ^^ubyte z = binop("shl", convert(get_flag("z"), L_I1, L_I8), "1", L_I8)
        ^^ubyte c = convert(get_flag("c"), L_I1, L_I8)
        ^^ubyte status = binop("or", binop("or", binop("or", n, v, L_I8), z, L_I8), c, L_I8)
        push_value(status, L_I8)
    }

    sub pop_status() {
        ^^ubyte status = pop_value(L_I8)
        set_flag("n", icmp("ne", binop("and", status, "-128", L_I8), "0", L_I8))
        set_flag("v", icmp("ne", binop("and", status, "64", L_I8), "0", L_I8))
        set_flag("z", icmp("ne", binop("and", status, "2", L_I8), "0", L_I8))
        set_flag("c", icmp("ne", binop("and", status, "1", L_I8), "0", L_I8))
    }

    ; ---- syscalls ----

    ; the value of the n-th argument of a syscall, as a given LLVM type
    sub sysarg(^^ir.Instr i, ubyte n, ubyte t) -> ^^ubyte {
        ^^ir.Arg a = i.args
        while n != 0 and a != 0 {
            a = a.next
            n--
        }
        if a == 0 {
            error("syscall argument missing")
            return int_const(0, t)
        }
        ^^ubyte v
        ubyte at
        v, at = read_wide(a.reg, a.type)
        return convert(v, at, t)
    }

    ; a call of a C routine without arguments that returns an int
    sub c_int_call(^^ubyte name) -> ^^ubyte {
        if name[0] == 'g'
            declare(name, int_declare("declare ", " @getchar()"))
        else if name[6] == 'g' and name[9] == 'c'
            declare(name, int_declare("declare ", " @prog8_getchar()"))
        else if name[6] == 'g'
            declare(name, int_declare("declare ", " @prog8_getkey()"))
        else if name[6] == 'w'
            declare(name, int_declare("declare ", " @prog8_waitkey()"))
        else
            declare(name, int_declare("declare ", " @prog8_termsize()"))
        ^^ubyte v = result(int_lt)
        add("call ")
        addn(int_name)
        add(" @")
        addn(name)
        add("()\n")
        return v
    }

    ; Does the program read keys, or ask for the terminal's size?  Then it is
    ; built with the console runtime (runtime/hosted-keys.c), on the hosted
    ; platforms.  Subroutines that nothing calls are gone by now.
    sub find_console_use(^^ir.Program p) {
        console_keys = false
        console_size = false
        if mos or (llvm32 and triple.getkey_source == 0)
            return
        ^^ir.Block bl = p.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                ^^ir.Chunk c = s.chunks
                while c != 0 {
                    ^^ir.Instr i = c.first
                    while i != 0 {
                        if i.op == ir.OP_SYSCALL
                            console_syscall(i.value as long)
                        i = i.next
                    }
                    ; (the library's routines are inline IR, which is text here)
                    if c.is_ir and c.text != 0 {
                        long k = 0
                        while k + 11 < c.textlen {
                            if c.text[k] == 's' and buf.bytes_equal(c.text + k, "syscall 21", 10)
                                console_syscall(210 + (c.text[k + 10] - '0'))
                            k++
                        }
                    }
                    c = c.next
                }
                s = s.next
            }
            bl = bl.next
        }
    }

    sub console_syscall(long n) {
        if n == 217 or n == 218
            console_keys = true
        else if n == 219
            console_size = true
    }

    sub sysresult(^^ir.Instr i, ^^ubyte v, ubyte t) {
        ^^ir.Arg r = i.results
        if r != 0 and r.reg != 0
            write(r.reg, v, t)
    }

    ; a call of a C routine or helper with up to three typed arguments, the operands evaluated first
    ^^ubyte[3] sa
    ubyte[3] sat
    ubyte san = 0

    sub syscall_args(^^ir.Instr i, ubyte t0, ubyte t1, ubyte t2, ubyte count) {
        san = count
        if count > 0 {
            sa[0] = sysarg(i, 0, t0)
            sat[0] = t0
        }
        if count > 1 {
            sa[1] = sysarg(i, 1, t1)
            sat[1] = t1
        }
        if count > 2 {
            sa[2] = sysarg(i, 2, t2)
            sat[2] = t2
        }
    }

    ; "call <ret> @name(<args>)" with the prepared arguments in the given order; returns the result value or 0
    sub emit_call(^^ubyte name, ubyte rettype, ubyte a0, ubyte a1, ubyte a2) -> ^^ubyte {
        ^^ubyte rv = 0
        if rettype != L_VOID {
            rv = result(rettype)
            add("call ")
        }
        else
            line("call ")
        addn(ltname(rettype))
        add(" @")
        addn(name)
        add("(")
        if san > 0
            typed(sat[a0], sa[a0])
        if san > 1 {
            add(", ")
            typed(sat[a1], sa[a1])
        }
        if san > 2 {
            add(", ")
            typed(sat[a2], sa[a2])
        }
        add(")\n")
        return rv
    }

    ; The llvm-mos C library has no files, directories, sleep or I/O ports: on llvm16 a
    ; syscall that needs them gives its result for a failure, as upstream's does.
    ; False when the syscall is not one of those.
    sub without_files(^^ir.Instr i, quad n) -> bool {
        if c64 {
            ; the Commodore 64 library has files, but no fseek and no directories
            when n {
                14 -> {
                    declare("prog8_c64_waitvsync", "declare void @prog8_c64_waitvsync()")
                    line("call void @prog8_c64_waitvsync()\n")
                }
                216 -> {
                    declare("prog8_c64_ticks", "declare i16 @prog8_c64_ticks()")
                    ^^ubyte ticks = result(L_I16)
                    add("call i16 @prog8_c64_ticks()\n")
                    sysresult(i, ticks, L_I16)
                }
                214 -> return true
                40, 41 -> sysresult(i, "null", L_PTR)
                48 -> sysresult(i, "@.sys.argv.none", L_PTR)
                64, 65 -> sysresult(i, "0", L_I32)
                215 -> sysresult(i, "255", L_I8)
                49, 50, 51, 63, 206, 212, 213 -> sysresult(i, "0", L_I8)
                else -> return false
            }
            return true
        }
        when n {
            13, 14, 56, 57, 214 -> return true
            40, 41, 202 -> sysresult(i, "null", L_PTR)
            48 -> sysresult(i, "@.sys.argv.none", L_PTR)       ; an empty string
            54, 204, 205 -> sysresult(i, "0", L_I16)
            64, 65 -> sysresult(i, "0", L_I32)
            207 -> sysresult(i, "-1", L_I64)
            209 -> sysresult(i, "1", L_I8)
            215 -> sysresult(i, "255", L_I8)
            42, 43, 44, 49, 50, 51, 52, 53, 55, 63, 203, 206, 208, 212, 213 -> sysresult(i, "0", L_I8)
            else -> return false
        }
        return true
    }

    sub lower_syscall(^^ir.Instr i) {
        quad n = i.value
        ^^ubyte v
        ^^ubyte st
        if mos and without_files(i, n)
            return
        when n {
            1 -> {
                declare("exit", int_declare("declare void @exit(", ")"))
                syscall_args(i, int_lt, 0, 0, 1)
                void emit_call("exit", L_VOID, 0, 1, 2)
            }
            2 -> {
                declare_putchar()
                syscall_args(i, int_lt, 0, 0, 1)
                void emit_call("putchar", int_lt, 0, 1, 2)
            }
            3 -> {
                print_string_helper()
                syscall_args(i, L_PTR, 0, 0, 1)
                void emit_call(".print.string", L_VOID, 0, 1, 2)
            }
            13 -> {
                wait_helper()
                syscall_args(i, L_I16, 0, 0, 1)
                void emit_call(".sys.wait", L_VOID, 0, 1, 2)
            }
            14 -> {
                wait_helper()
                line("call void @.sys.wait(i16 1)\n")
            }
            36 -> {
                ^^ubyte mmname = size_text("llvm.memmove.p0.p0.", "")
                declare(mmname, size_text3("declare void @llvm.memmove.p0.p0.", "(ptr, ptr, ", ", i1)"))
                syscall_args(i, L_PTR, L_PTR, size_lt, 3)
                line("call void @")
                addn(mmname)
                add("(ptr ")
                addn(sa[1])
                add(", ptr ")
                addn(sa[0])
                add(", ")
                addn(size_name)
                add(" ")
                addn(sa[2])
                add(", i1 false)\n")
            }
            37 -> {
                ^^ubyte msname = size_text("llvm.memset.p0.", "")
                declare(msname, size_text3("declare void @llvm.memset.p0.", "(ptr, i8, ", ", i1)"))
                syscall_args(i, L_PTR, size_lt, L_I8, 3)
                line("call void @")
                addn(msname)
                add("(ptr ")
                addn(sa[0])
                add(", i8 ")
                addn(sa[2])
                add(", ")
                addn(size_name)
                add(" ")
                addn(sa[1])
                add(", i1 false)\n")
            }
            38 -> {
                memsetw_helper()
                syscall_args(i, L_PTR, L_I16, L_I16, 3)
                void emit_call(".memsetw", L_VOID, 0, 1, 2)
            }
            69, 217, 218 -> {
                ; a character, a key without waiting, a key: the console
                ; runtime's routines when the program reads keys (raw mode,
                ; cursor keys), plain getchar otherwise
                ^^ubyte reader = "getchar"
                if console_keys {
                    reader = "prog8_getchar"
                    if n == 217
                        reader = "prog8_getkey"
                    else if n == 218
                        reader = "prog8_waitkey"
                }
                ^^ubyte smax = int_text("llvm.smax.", "")
                declare(smax, int_text3("declare ", " @llvm.smax.", "(", ", ", ")"))
                ^^ubyte ch = c_int_call(reader)
                ^^ubyte pos = result(int_lt)
                add("call ")
                addn(int_name)
                add(" @")
                addn(smax)
                add("(")
                addn(int_name)
                add(" ")
                addn(ch)
                add(", ")
                addn(int_name)
                add(" 0)\n")
                sysresult(i, convert(pos, int_lt, L_I8), L_I8)
            }
            200 -> {
                declare("llvm.umin.i32", "declare i32 @llvm.umin.i32(i32, i32)")
                ^^ubyte argc = load_from("@.sys.argc", L_I32)
                ^^ubyte lim = result(L_I32)
                add("call i32 @llvm.umin.i32(i32 ")
                addn(argc)
                add(", i32 65535)\n")
                sysresult(i, convert(lim, L_I32, L_I16), L_I16)
            }
            201 -> {
                argv_helper()
                syscall_args(i, L_I16, 0, 0, 1)
                sysresult(i, emit_call(".sys.argv.at", L_PTR, 0, 1, 2), L_PTR)
            }
            40, 41 -> {
                ; load, load_raw: (name, address) -> end address
                file_runtime()
                syscall_args(i, L_PTR, L_PTR, 0, 2)
                san = 3
                sat[2] = L_I1
                sa[2] = "false"
                if n == 41
                    sa[2] = "true"
                sysresult(i, emit_call(".file.load", L_PTR, 0, 1, 2), L_PTR)
            }
            42 -> {
                ; save: (raw, name, start, size) -> success
                file_runtime()
                ^^ubyte sraw = icmp("ne", sysarg(i, 0, L_I8), "0", L_I8)
                ^^ubyte sname = sysarg(i, 1, L_PTR)
                ^^ubyte sstart = sysarg(i, 2, L_PTR)
                ^^ubyte ssize = sysarg(i, 3, size_lt)
                ^^ubyte saved = result(L_I8)
                add("call i8 @.file.save(i1 ")
                addn(sraw)
                add(", ptr ")
                addn(sname)
                add(", ptr ")
                addn(sstart)
                add(", ")
                addn(size_name)
                add(" ")
                addn(ssize)
                add(")\n")
                sysresult(i, saved, L_I8)
            }
            43, 44, 49, 50, 51 -> {
                ; delete, rename, mkdir, chdir, rmdir: the C library's status 0 is success
                ^^ubyte fsname = "remove"
                ubyte fscount = 1
                when n {
                    44 -> {
                        declare("rename", int_declare("declare ", " @rename(ptr, ptr)"))
                        fsname = "rename"
                        fscount = 2
                    }
                    49 -> {
                        declare("mkdir", "declare i32 @mkdir(ptr, i32)")
                        fsname = "mkdir"
                    }
                    50 -> {
                        declare("chdir", "declare i32 @chdir(ptr)")
                        fsname = "chdir"
                    }
                    51 -> {
                        declare("rmdir", "declare i32 @rmdir(ptr)")
                        fsname = "rmdir"
                    }
                    else -> declare("remove", int_declare("declare ", " @remove(ptr)"))
                }
                syscall_args(i, L_PTR, L_PTR, 0, fscount)
                if n == 49 {
                    san = 2
                    sat[1] = L_I32
                    sa[1] = "493"       ; mode 0755
                }
                ubyte fst = L_I32
                if n == 43 or n == 44
                    fst = int_lt
                st = emit_call(fsname, fst, 0, 1, 2)
                sysresult(i, convert(icmp("eq", st, "0", fst), L_I1, L_I8), L_I8)
            }
            48 -> {
                file_runtime()
                declare("getcwd", c_declare("declare ptr @getcwd(ptr, ", ")"))
                san = 2
                sat[0] = L_PTR
                sa[0] = "@.sys.curdir.buf"
                sat[1] = size_lt
                sa[1] = "4096"
                sysresult(i, emit_call("getcwd", L_PTR, 0, 1, 2), L_PTR)
            }
            52, 53 -> {
                ; open the one file for reading, or the one for writing
                file_runtime()
                syscall_args(i, L_PTR, 0, 0, 1)
                san = 3
                sat[1] = L_PTR
                sat[2] = L_PTR
                if n == 52 {
                    sa[1] = "@.file.mode.rb"
                    sa[2] = "@.file.read_stream"
                }
                else {
                    sa[1] = "@.file.mode.wb"
                    sa[2] = "@.file.write_stream"
                }
                sysresult(i, emit_call(".file.open", L_I8, 0, 1, 2), L_I8)
            }
            54 -> {
                file_runtime()
                san = 0
                sysresult(i, emit_call(".file.read.byte", L_I16, 0, 1, 2), L_I16)
            }
            55 -> {
                file_runtime()
                syscall_args(i, L_I8, 0, 0, 1)
                sysresult(i, emit_call(".file.write.byte", L_I8, 0, 1, 2), L_I8)
            }
            56, 57 -> {
                file_runtime()
                san = 1
                sat[0] = L_PTR
                sa[0] = "@.file.read_stream"
                if n == 57
                    sa[0] = "@.file.write_stream"
                void emit_call(".file.close", L_VOID, 0, 1, 2)
            }
            63 -> {
                file_runtime()
                syscall_args(i, L_I32, 0, 0, 1)
                sysresult(i, emit_call(".file.seek", L_I8, 0, 1, 2), L_I8)
            }
            64, 65 -> {
                file_runtime()
                san = 0
                if n == 64
                    sysresult(i, emit_call(".file.tell", L_I32, 0, 1, 2), L_I32)
                else
                    sysresult(i, emit_call(".file.size", L_I32, 0, 1, 2), L_I32)
            }
            212 -> {
                file_runtime()
                syscall_args(i, L_I8, 0, 0, 1)
                sysresult(i, emit_call(".diskio.list", L_I8, 0, 1, 2), L_I8)
            }
            215 -> sysresult(i, "-1", L_I8)       ; last_drive: there are no drives
            202 -> {
                declare("fopen", "declare ptr @fopen(ptr, ptr)")
                syscall_args(i, L_PTR, L_PTR, 0, 2)
                sysresult(i, emit_call("fopen", L_PTR, 0, 1, 2), L_PTR)
            }
            203, 208 -> {
                ^^ubyte routine = "fclose"
                if n == 208
                    routine = "fflush"
                buf.clear(nb)
                buf.add_str(nb, "declare ")
                buf.add_str(nb, int_name)
                buf.add_str(nb, " @")
                buf.add_str(nb, routine)
                buf.add_str(nb, "(ptr)")
                declare(routine, keep_nb())
                syscall_args(i, L_PTR, 0, 0, 1)
                st = emit_call(routine, int_lt, 0, 1, 2)
                sysresult(i, convert(icmp("eq", st, "0", int_lt), L_I1, L_I8), L_I8)
            }
            204, 205 -> {
                ^^ubyte routine2 = "fread"
                if n == 205
                    routine2 = "fwrite"
                buf.clear(nb)
                buf.add_str(nb, "declare ")
                buf.add_str(nb, size_name)
                buf.add_str(nb, " @")
                buf.add_str(nb, routine2)
                buf.add_str(nb, "(ptr, ")
                buf.add_str(nb, size_name)
                buf.add_str(nb, ", ")
                buf.add_str(nb, size_name)
                buf.add_str(nb, ", ptr)")
                declare(routine2, keep_nb())
                syscall_args(i, L_PTR, L_PTR, size_lt, 3)
                ^^ubyte done = result(size_lt)
                add("call ")
                addn(size_name)
                add(" @")
                addn(routine2)
                add("(ptr ")
                addn(sa[1])
                add(", ")
                addn(size_name)
                add(" 1, ")
                addn(size_name)
                add(" ")
                addn(sa[2])
                add(", ptr ")
                addn(sa[0])
                add(")\n")
                sysresult(i, convert(done, size_lt, L_I16), L_I16)
            }
            206 -> {
                ^^ubyte seeker = "fseek"
                if windows
                    seeker = "_fseeki64"
                declare(seeker, host_text(join_parts(long_name, "declare i32 @fseek(ptr, ", ", i32)", "", "", "")))
                syscall_args(i, L_PTR, long_lt, L_I32, 3)
                st = emit_call(seeker, L_I32, 0, 1, 2)
                sysresult(i, convert(icmp("eq", st, "0", L_I32), L_I1, L_I8), L_I8)
            }
            207 -> {
                ^^ubyte teller = "ftell"
                if windows
                    teller = "_ftelli64"
                declare(teller, host_text(join_parts(long_name, "declare ", " @ftell(ptr)", "", "", "")))
                syscall_args(i, L_PTR, 0, 0, 1)
                sysresult(i, emit_call(teller, long_lt, 0, 1, 2), long_lt)
            }
            209 -> {
                declare("feof", int_declare("declare ", " @feof(ptr)"))
                syscall_args(i, L_PTR, 0, 0, 1)
                st = emit_call("feof", int_lt, 0, 1, 2)
                sysresult(i, convert(icmp("ne", st, "0", int_lt), L_I1, L_I8), L_I8)
            }
            210 -> {
                float_digits_helper()
                syscall_args(i, L_PTR, L_DOUBLE, 0, 2)
                void emit_call(".float.digits", L_VOID, 0, 1, 2)
            }
            211 -> {
                parse_float_helper()
                syscall_args(i, L_PTR, 0, 0, 1)
                sysresult(i, emit_call(".float.parse", L_DOUBLE, 0, 1, 2), L_DOUBLE)
            }
            216 -> sysresult(i, "0", L_I64)
            ; the terminal's size, columns in the low byte and rows in the high
            ; one; 0 is "not a terminal", and what there is without the console
            ; runtime (WebAssembly, the 6502)
            219 -> {
                if console_size
                    sysresult(i, convert(c_int_call("prog8_termsize"), int_lt, L_I16), L_I16)
                else
                    sysresult(i, "0", L_I16)
            }
            31 -> {
                declare("atan2", "declare double @atan2(double, double)")
                declare("llvm.floor.f64", "declare double @llvm.floor.f64(double)")
                ^^ubyte x1 = coordinate(i, 0)
                ^^ubyte y1 = coordinate(i, 1)
                ^^ubyte x2 = coordinate(i, 2)
                ^^ubyte y2 = coordinate(i, 3)
                ^^ubyte dy = binop("fsub", y2, y1, L_DOUBLE)
                ^^ubyte dx = binop("fsub", x2, x1, L_DOUBLE)
                ^^ubyte radians = result(L_DOUBLE)
                add("call double @atan2(double ")
                addn(dy)
                add(", double ")
                addn(dx)
                add(")\n")
                ^^ubyte negative = fcmp("olt", radians, "0.0")
                ^^ubyte turned = binop("fadd", radians, float_const(6.283185307179586), L_DOUBLE)
                ^^ubyte full = select(negative, turned, radians, L_DOUBLE)
                ^^ubyte halved = binop("fdiv", full, "2.0", L_DOUBLE)
                ^^ubyte turns = binop("fdiv", halved, float_const(3.141592653589793), L_DOUBLE)
                ^^ubyte scaled = binop("fmul", turns, "256.0", L_DOUBLE)
                ^^ubyte floored = result(L_DOUBLE)
                add("call double @llvm.floor.f64(double ")
                addn(scaled)
                add(")\n")
                ^^ubyte steps = convert(floored, L_DOUBLE, L_I32)
                sysresult(i, convert(steps, L_I32, L_I8), L_I8)
            }
            33 -> {
                declare(".math.mul16_upper", "@.math.mul16_upper = internal global i16 0")
                sysresult(i, load_from("@.math.mul16_upper", L_I16), L_I16)
            }
            $100d -> {
                compare_strings_helper()
                syscall_args(i, L_PTR, L_PTR, 0, 2)
                sysresult(i, emit_call(".compare.strings", L_I8, 0, 1, 2), L_I8)
            }
            $100e -> {
                string_contains_helper()
                syscall_args(i, L_I8, L_PTR, 0, 2)
                sysresult(i, emit_call(".contains.string", L_I8, 0, 1, 2), L_I8)
            }
            $1012, $1013, $1014, $1015, $1016 -> {
                ; clamp(value, low, high), unsigned or signed
                ubyte kt = L_I8
                if n == $1014 or n == $1015
                    kt = L_I16
                else if n == $1016
                    kt = L_I32
                bool ksigned = n == $1013 or n == $1015 or n == $1016
                syscall_args(i, kt, kt, kt, 3)
                ^^ubyte below
                ^^ubyte above
                if ksigned
                    below = icmp("slt", sa[0], sa[1], kt)
                else
                    below = icmp("ult", sa[0], sa[1], kt)
                ^^ubyte raised = select(below, sa[1], sa[0], kt)
                if ksigned
                    above = icmp("sgt", raised, sa[2], kt)
                else
                    above = icmp("ugt", raised, sa[2], kt)
                sysresult(i, select(above, sa[2], raised, kt), kt)
            }
            $100f, $1010, $101b, $101c, $1011 -> {
                ubyte et = L_I8
                if n == $1010
                    et = L_I16
                else if n == $101b
                    et = L_I32
                else if n == $101c
                    et = L_I64
                else if n == $1011
                    et = L_DOUBLE
                contains_helper(et)
                syscall_args(i, et, L_PTR, L_I16, 3)
                buf.clear(nb)
                buf.add_str(nb, ".contains.")
                buf.add_str(nb, ltname(et))
                sysresult(i, emit_call(keep_nb(), L_I8, 0, 1, 2), L_I8)
            }
            else -> {
                buf.clear(nb)
                buf.add_str(nb, "unsupported syscall ")
                buf.add_quad(nb, n)
                buf.add_byte(nb, 0)
                error(nb.data)
            }
        }
    }

    ; a coordinate byte argument of the angle syscall as a double
    sub coordinate(^^ir.Instr i, ubyte n) -> ^^ubyte {
        ^^ubyte b = sysarg(i, n, L_I8)
        ^^ubyte d = result(L_DOUBLE)
        add("uitofp i8 ")
        addn(b)
        add(" to double\n")
        return d
    }

    ; ---- helper routines, each emitted once ----

    sub print_string_helper() {
        declare_putchar()
        buf.clear(nb)
        buf.add_str(nb, "define internal void @.print.string(ptr %str) {\nentry:\n  br label %loop\n\nloop:\n  %curr_ptr = phi ptr [ %str, %entry ], [ %next, %print ]\n  %ch = load i8, ptr %curr_ptr\n")
        buf.add_str(nb, "  %end = icmp eq i8 %ch, 0\n  br i1 %end, label %done, label %print\n\nprint:\n  %ch_ext = zext i8 %ch to ")
        buf.add_str(nb, int_name)
        buf.add_str(nb, "\n  call ")
        buf.add_str(nb, int_name)
        buf.add_str(nb, " @putchar(")
        buf.add_str(nb, int_name)
        buf.add_str(nb, " %ch_ext)\n")
        buf.add_str(nb, "  %next = getelementptr i8, ptr %curr_ptr, i64 1\n  br label %loop\n\ndone:\n  ret void\n}")
        declare(".print.string", keep_nb())
    }

    sub wait_helper() {
        declare("usleep", int_declare("declare ", " @usleep(i32)"))
        declare("llvm.umin.i32", "declare i32 @llvm.umin.i32(i32, i32)")
        buf.clear(nb)
        buf.add_str(nb, "define internal void @.sys.wait(i16 %jiffies) {\nentry:\n  %count = zext i16 %jiffies to i32\n  %total = mul i32 %count, 16667\n  br label %loop\n\nloop:\n")
        buf.add_str(nb, "  %left = phi i32 [ %total, %entry ], [ %next, %sleep ]\n  %over = icmp eq i32 %left, 0\n  br i1 %over, label %finished, label %sleep\n\nsleep:\n")
        buf.add_str(nb, "  %part = call i32 @llvm.umin.i32(i32 %left, i32 500000)\n  call ") 
        buf.add_str(nb, int_name)
        buf.add_str(nb, " @usleep(i32 %part)\n  %next = sub i32 %left, %part\n  br label %loop\n\nfinished:\n  ret void\n}")
        declare(".sys.wait", keep_nb())
    }

    sub argv_helper() {
        buf.clear(nb)
        buf.add_str(nb, "define internal ptr @.sys.argv.at(i16 %index) {\nentry:\n  %i = zext i16 %index to i64\n  %argc = load i32, ptr @.sys.argc\n  %n = zext i32 %argc to i64\n")
        buf.add_str(nb, "  %inrange = icmp ult i64 %i, %n\n  br i1 %inrange, label %present, label %absent\n\npresent:\n  %argv = load ptr, ptr @.sys.argv\n  %slot = getelementptr ptr, ptr %argv, i64 %i\n")
        buf.add_str(nb, "  %argument = load ptr, ptr %slot\n  ret ptr %argument\n\nabsent:\n  ret ptr @.sys.argv.none\n}")
        declare(".sys.argv.at", keep_nb())
    }

    sub memsetw_helper() {
        buf.clear(nb)
        buf.add_str(nb, "define internal void @.memsetw(ptr %address, i16 %count, i16 %value) {\nentry:\n  %n = zext i16 %count to i64\n  br label %loop\n\nloop:\n")
        buf.add_str(nb, "  %i = phi i64 [ 0, %entry ], [ %next, %body ]\n  %more = icmp ult i64 %i, %n\n  br i1 %more, label %body, label %done\n\nbody:\n  %slot = getelementptr i16, ptr %address, i64 %i\n")
        buf.add_str(nb, "  store i16 %value, ptr %slot, align 1\n  %next = add i64 %i, 1\n  br label %loop\n\ndone:\n  ret void\n}")
        declare(".memsetw", keep_nb())
    }

    sub compare_strings_helper() {
        buf.clear(nb)
        buf.add_str(nb, "define internal i8 @.compare.strings(ptr %first, ptr %second) {\nentry:\n  br label %loop\n\nloop:\n  %i = phi i64 [ 0, %entry ], [ %next, %same ]\n")
        buf.add_str(nb, "  %first.slot = getelementptr i8, ptr %first, i64 %i\n  %first.char = load i8, ptr %first.slot\n  %second.slot = getelementptr i8, ptr %second, i64 %i\n")
        buf.add_str(nb, "  %second.char = load i8, ptr %second.slot\n  %equal = icmp eq i8 %first.char, %second.char\n  br i1 %equal, label %same, label %differ\n\nsame:\n")
        buf.add_str(nb, "  %end = icmp eq i8 %first.char, 0\n  %next = add i64 %i, 1\n  br i1 %end, label %done, label %loop\n\ndone:\n  ret i8 0\n\ndiffer:\n")
        buf.add_str(nb, "  %less = icmp ult i8 %first.char, %second.char\n  %order = select i1 %less, i8 -1, i8 1\n  ret i8 %order\n}")
        declare(".compare.strings", keep_nb())
    }

    sub string_contains_helper() {
        buf.clear(nb)
        buf.add_str(nb, "define internal i8 @.contains.string(i8 %wanted, ptr %string) {\nentry:\n  br label %loop\n\nloop:\n  %i = phi i64 [ 0, %entry ], [ %next, %more ]\n")
        buf.add_str(nb, "  %slot = getelementptr i8, ptr %string, i64 %i\n  %char = load i8, ptr %slot\n  %end = icmp eq i8 %char, 0\n  br i1 %end, label %absent, label %more\n\nmore:\n")
        buf.add_str(nb, "  %found = icmp eq i8 %char, %wanted\n  %next = add i64 %i, 1\n  br i1 %found, label %present, label %loop\n\npresent:\n  ret i8 1\n\nabsent:\n  ret i8 0\n}")
        declare(".contains.string", keep_nb())
    }

    sub contains_helper(ubyte et) {
        ^^ubyte tn = ltname(et)
        buf.clear(nb)
        buf.add_str(nb, ".contains.")
        buf.add_str(nb, tn)
        ^^ubyte name = keep_nb()
        ^^ubyte cmptext = "icmp eq "
        if et == L_DOUBLE
            cmptext = "fcmp oeq "
        buf.clear(nb)
        buf.add_str(nb, "define internal i8 @")
        buf.add_str(nb, name)
        buf.add_byte(nb, '(')
        buf.add_str(nb, tn)
        buf.add_str(nb, " %needle, ptr %array, i16 %count) {\nentry:\n  %n = zext i16 %count to i64\n  br label %loop\n\nloop:\n  %i = phi i64 [ 0, %entry ], [ %next, %body ]\n  %more = icmp ult i64 %i, %n\n  br i1 %more, label %body, label %absent\n\nbody:\n  %slot = getelementptr ")
        buf.add_str(nb, tn)
        buf.add_str(nb, ", ptr %array, i64 %i\n  %element = load ")
        buf.add_str(nb, tn)
        buf.add_str(nb, ", ptr %slot, align 1\n  %found = ")
        buf.add_str(nb, cmptext)
        buf.add_str(nb, tn)
        buf.add_str(nb, " %element, %needle\n  %next = add i64 %i, 1\n  br i1 %found, label %present, label %loop\n\npresent:\n  ret i8 1\n\nabsent:\n  ret i8 0\n}")
        declare(name, keep_nb())
    }

    sub float_digits_helper() {
        declare("snprintf", c_declare("declare i32 @snprintf(ptr, ", ", ptr, ...)"))
        declare("strtod", "declare double @strtod(ptr, ptr)")
        declare(".float.digits.format", "@.float.digits.format = private unnamed_addr constant [5 x i8] c\"%.*e\\00\"")
        buf.clear(nb)
        buf.add_str(nb, "define internal void @.float.digits(ptr %buffer, double %value) {\nentry:\n  br label %loop\n\nloop:\n  %precision = phi i32 [ 1, %entry ], [ %next, %loop ]\n")
        buf.add_str(nb, "  call i32 (ptr, ")
        buf.add_str(nb, size_name)
        buf.add_str(nb, ", ptr, ...) @snprintf(ptr %buffer, ")
        buf.add_str(nb, size_name)
        buf.add_str(nb, " 32, ptr @.float.digits.format, i32 %precision, double %value)\n  %parsed = call double @strtod(ptr %buffer, ptr null)\n")
        buf.add_str(nb, "  %same = fcmp oeq double %parsed, %value\n  %next = add i32 %precision, 1\n  %last = icmp sge i32 %next, 17\n  %found = or i1 %same, %last\n")
        buf.add_str(nb, "  br i1 %found, label %done, label %loop\n\ndone:\n  ret void\n}")
        declare(".float.digits", keep_nb())
    }

    sub parse_float_helper() {
        declare("strtod", "declare double @strtod(ptr, ptr)")
        buf.clear(nb)
        buf.add_str(nb, "define internal double @.float.parse(ptr %string) {\nentry:\n  %end_slot = alloca ptr\n  %parsed = call double @strtod(ptr %string, ptr %end_slot)\n")
        buf.add_str(nb, "  %end = load ptr, ptr %end_slot\n  %rest = load i8, ptr %end\n  %whole = icmp eq i8 %rest, 0\n  %result = select i1 %whole, double %parsed, double 0.0\n  ret double %result\n}")
        declare(".float.parse", keep_nb())
    }

    ; ---- globals ----

    ; the LLVM type text of a variable: scalar name, or [N x elem] for arrays and strings
    sub global_type(^^ir.Var v, bool with_pointers) {
        ^^ubyte t = v.typestr
        long i = 0
        while t[i] != 0 and t[i] != '['
            i++
        if t[i] == 0 {
            emit(ltname(lt_of_typestr(t)))
            return
        }
        ; element type then [N]
        buf.clear(nb)
        buf.add_bytes(nb, t, i)
        buf.add_byte(nb, 0)
        ubyte et = lt_of_typestr(nb.data)
        if with_pointers
            et = L_PTR
        emit("[")
        long n = 0
        i++
        while t[i] >= '0' and t[i] <= '9' {
            n = n * 10 + (t[i] - '0')
            i++
        }
        buf.clear(nb)
        buf.add_long(nb, n)
        emit(nb.data)
        emit(" x ")
        emit(ltname(et))
        emit("]")
    }

    ; the number of elements of an array type text, or 0 for a scalar
    sub array_length(^^ubyte t) -> long {
        long i = 0
        while t[i] != 0 and t[i] != '['
            i++
        if t[i] == 0
            return 0
        i++
        long n = 0
        while t[i] >= '0' and t[i] <= '9' {
            n = n * 10 + (t[i] - '0')
            i++
        }
        return n
    }

    sub init_has_symbols(^^ubyte init) -> bool {
        long i = 0
        while init[i] != 0 {
            if init[i] == '@'
                return true
            i++
        }
        return false
    }

    ; a number in initializer text: decimal, $hex, with a sign; stops at ',' or the end
    sub init_number(^^ubyte s, long p) -> quad, long {
        bool negative = false
        if s[p] == '-' {
            negative = true
            p++
        }
        quad v = 0
        if s[p] == '$' {
            p++
            while true {
                ubyte c = s[p]
                ubyte d = 255
                if c >= '0' and c <= '9'
                    d = c - '0'
                else if c >= 'a' and c <= 'f'
                    d = c - 'a' + 10
                else if c >= 'A' and c <= 'F'
                    d = c - 'A' + 10
                if d == 255
                    break
                v = (v << 4) | d
                p++
            }
        }
        else {
            while s[p] >= '0' and s[p] <= '9' {
                v = v * 10 + (s[p] - '0')
                p++
            }
        }
        if negative
            v = -v
        return v, p
    }

    sub is_float_text(^^ubyte s, long p) -> bool {
        if s[p] == '$' or (s[p] == '-' and s[p + 1] == '$')
            return false            ; a hex number may contain an e
        while s[p] != 0 and s[p] != ',' {
            if s[p] == '.' or s[p] == 'e' or s[p] == 'E'
                return true
            p++
        }
        return false
    }

    sub write_globals() {
        write_clusters()
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_VAR and not v.stacklocal
                write_var(v)
            else if v.kind == ir.V_INSTANCE
                write_instance(v)
            else if v.kind == ir.V_CONST
                write_const(v)
            else if v.kind == ir.V_SLAB {
                emit("@")
                emit(ident(v.name))
                emit(" = internal global [")
                buf.clear(nb)
                buf.add_long(nb, v.size)
                emit(nb.data)
                emit(" x i8] zeroinitializer")
                if v.align > 1 {
                    emit(", align ")
                    buf.clear(nb)
                    buf.add_long(nb, v.align)
                    emit(nb.data)
                }
                emit("\n")
            }
            v = v.next
        }
        emit("\n")
    }

    ; a static struct instance: a packed struct of its field values, or zero bytes
    sub write_instance(^^ir.Var v) {
        emit("@")
        emit(ident(v.name))
        emit(" = internal global ")
        if v.init == 0 {
            emit("[")
            buf.clear(nb)
            buf.add_long(nb, v.size)
            buf.add_byte(nb, 0)
            emit(nb.data)
            emit(" x i8] zeroinitializer\n")
            return
        }
        instance_part(v, false, v.name, 0)
        emit(" ")
        instance_part(v, true, v.name, 0)
        emit("\n")
    }

    ; The packed struct type of a static instance, "<{ i8, i16 }>", or with_values its
    ; constant, "<{ i8 1, i16 2 }>".  A pointer at an unaligned offset is null here and
    ; stored at startup instead; owner and base say where the instance is (itself, or
    ; an element of an array of struct instances).
    sub instance_part(^^ir.Var v, bool with_values, ^^ubyte owner, long base) {
        emit("<{ ")
        long p = 0
        long offset = 0
        ^^ubyte t = v.init
        bool first = true
        while t[p] != 0 {
            long colon = p
            while t[colon] != ':'
                colon++
            long stop = colon + 1
            while t[stop] != 0 and t[stop] != ','
                stop++
            ubyte ft = L_PTR
            if t[p] != '^' {
                buf.clear(nb)
                buf.add_bytes(nb, t + p, colon - p)
                ft = lt_of_typestr(keep_nb())
            }
            if not first
                emit(", ")
            first = false
            emit(ltname(ft))
            if with_values {
                emit(" ")
                buf.clear(nb)
                buf.add_bytes(nb, t + colon + 1, stop - colon - 1)
                ^^ubyte vt = keep_nb()
                if vt[0] == '@' and ((base + offset) & (pointer_bytes - 1)) != 0 {
                    if ft == L_PTR
                        emit("null")
                    else
                        emit("0")
                    buf.add_str(fixups, "  store volatile ptr @")
                    buf.add_str(fixups, ident(vt + 1))
                    buf.add_str(fixups, ", ptr getelementptr inbounds (i8, ptr @")
                    buf.add_str(fixups, ident(owner))
                    buf.add_str(fixups, ", i64 ")
                    buf.add_long(fixups, base + offset)
                    buf.add_str(fixups, "), align 1\n")
                }
                else if vt[0] == '@' and ft == L_PTR {
                    emit("@")
                    emit(ident(vt + 1))
                }
                else if vt[0] == '@' {
                    ; an address in an integer field
                    emit("ptrtoint (ptr @")
                    emit(ident(vt + 1))
                    emit(" to ")
                    emit(ltname(ft))
                    emit(")")
                }
                else if ft == L_DOUBLE
                    emit(float_const(float_platform.parse(vt)))
                else {
                    quad n0
                    long p0
                    n0, p0 = init_number(vt, 0)
                    emit(int_const(n0, ft))
                }
            }
            when ft {
                L_I8 -> offset += 1
                L_I16 -> offset += 2
                L_I32 -> offset += 4
                L_PTR -> offset += pointer_bytes
                else -> offset += 8
            }
            p = stop
            if t[p] == ','
                p++
        }
        emit(" }>")
    }

    ; the struct definition that is the element type of an array type text, or 0
    sub element_struct(^^ubyte typestr) -> ^^ir.Var {
        long i = 0
        while typestr[i] != 0 and typestr[i] != '['
            i++
        if typestr[i] == 0
            return 0
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_STRUCT and buf.cstr_len(v.name) == i and buf.bytes_equal(v.name, typestr, i)
                return v
            v = v.next
        }
        return 0
    }

    ; An array of struct instances: bytes when it has no initial values, else a packed
    ; struct of its elements, whose values are those of the static instances named in
    ; the initializer ("@instance,@instance").
    sub write_struct_array(^^ir.Var v, ^^ir.Var sd, long length) {
        emit("@")
        emit(ident(v.name))
        emit(" = internal global ")
        if v.init == 0 {
            emit("[")
            buf.clear(nb)
            buf.add_long(nb, length * sd.size)
            buf.add_byte(nb, 0)
            emit(nb.data)
            emit(" x i8] zeroinitializer\n")
            return
        }
        ubyte pass
        for pass in 0 to 1 {
            emit("<{ ")
            long p = 0
            long k = 0
            ^^ubyte t = v.init
            while t[p] != 0 {
                long stop = p
                while t[stop] != 0 and t[stop] != ','
                    stop++
                ^^ir.Var inst = 0
                if t[p] == '@'
                    inst = find_var(strtab.intern(t + p + 1, (stop - p - 1) as uword))
                if k != 0
                    emit(", ")
                if inst == 0 or inst.init == 0 {
                    ; no values: zero bytes of the struct's size
                    emit("[")
                    buf.clear(nb)
                    buf.add_long(nb, sd.size)
                    buf.add_byte(nb, 0)
                    emit(nb.data)
                    emit(" x i8]")
                    if pass == 1
                        emit(" zeroinitializer")
                }
                else {
                    instance_part(inst, false, v.name, k * sd.size)
                    if pass == 1 {
                        emit(" ")
                        instance_part(inst, true, v.name, k * sd.size)
                    }
                }
                k++
                p = stop
                if t[p] == ','
                    p++
            }
            if pass == 0
                emit(" }> ")
            else
                emit(" }>\n")
        }
    }

    sub write_const(^^ir.Var v) {
        ubyte t = lt_of_typestr(v.typestr)
        emit("@")
        emit(ident(v.name))
        emit(" = internal constant ")
        emit(ltname(t))
        emit(" ")
        if t == L_DOUBLE
            emit(float_const(float_platform.parse(v.init)))
        else {
            quad n
            long p
            n, p = init_number(v.init, 0)
            emit(int_const(n, t))
        }
        emit("\n")
    }

    sub write_var(^^ir.Var v) {
        bool interned = v.init != 0 and starts_with(v.name, "prog8_interned_strings.")
        bool pointers = v.init != 0 and init_has_symbols(v.init)
        long length = array_length(v.typestr)
        if length != 0 {
            ^^ir.Var sd = element_struct(v.typestr)
            if sd != 0 {
                write_struct_array(v, sd, length)
                return
            }
        }
        emit("@")
        emit(ident(v.name))
        if interned
            emit(" = private unnamed_addr constant ")
        else
            emit(" = internal global ")
        global_type(v, pointers)
        emit(" ")
        if v.init == 0 {
            if length != 0
                emit("zeroinitializer")
            else {
                ubyte st = lt_of_typestr(v.typestr)
                if st == L_PTR
                    emit("null")
                else if st == L_DOUBLE
                    emit("0.0")
                else
                    emit("0")
            }
        }
        else if length == 0 {
            ubyte st2 = lt_of_typestr(v.typestr)
            if st2 == L_DOUBLE
                emit(float_const(float_platform.parse(v.init)))
            else {
                quad n0
                long p0
                n0, p0 = init_number(v.init, 0)
                emit(int_const(n0, st2))
            }
        }
        else {
            ; an array: a string of bytes, or a list of elements
            buf.clear(nb)
            long i = 0
            ^^ubyte t = v.typestr
            while t[i] != 0 and t[i] != '['
                i++
            buf.add_bytes(nb, t, i)
            buf.add_byte(nb, 0)
            ubyte et = lt_of_typestr(nb.data)
            if pointers
                et = L_PTR
            if et == L_I8 and not pointers
                write_bytes_init(v.init)
            else
                write_array_init(v.init, et, length)
        }
        if v.align > 8 or (v.align > 1 and not pointers) {
            ; @alignword, @align64, @alignpage
            emit(", align ")
            buf.clear(nb)
            buf.add_long(nb, v.align)
            buf.add_byte(nb, 0)
            emit(nb.data)
        }
        else if pointers
            emit(", align 8")
        emit("\n")
    }

    sub starts_with(^^ubyte s, str prefix) -> bool {
        long i = 0
        while prefix[i] != 0 {
            if s[i] != prefix[i]
                return false
            i++
        }
        return true
    }

    ; "104,101,0" as c"he\00"
    sub write_bytes_init(^^ubyte init) {
        emit("c\"")
        long p = 0
        quad n
        while init[p] != 0 {
            n, p = init_number(init, p)
            ubyte b = n as ubyte
            if b == '"'
                emit("\\22")
            else if b == '\\'
                emit("\\\\")
            else if b >= $20 and b <= $7e {
                buf.clear(nb)
                buf.add_byte(nb, b)
                buf.add_byte(nb, 0)
                emit(nb.data)
            }
            else {
                buf.clear(nb)
                buf.add_byte(nb, '\\')
                buf.add_byte(nb, buf.hex_digit(b >> 4))
                buf.add_byte(nb, buf.hex_digit(b & 15))
                buf.add_byte(nb, 0)
                emit(nb.data)
            }
            if init[p] == ','
                p++
        }
        emit("\"")
    }

    sub write_array_init(^^ubyte init, ubyte et, long length) {
        emit("[")
        long p = 0
        long count = 0
        quad n
        while init[p] != 0 {
            if count != 0
                emit(", ")
            emit(ltname(et))
            emit(" ")
            if init[p] == '@' {
                long q = p + 1
                while init[q] != 0 and init[q] != ','
                    q++
                emit("@")
                buf.clear(nb)
                buf.add_bytes(nb, init + p + 1, q - p - 1)
                ^^ubyte iname = keep_nb()
                emit(ident(iname))
                p = q
            }
            else if et == L_DOUBLE or is_float_text(init, p) {
                long q2 = p
                while init[q2] != 0 and init[q2] != ','
                    q2++
                buf.clear(nb)
                buf.add_bytes(nb, init + p, q2 - p)
                buf.add_byte(nb, 0)
                emit(float_const(float_platform.parse(nb.data)))
                p = q2
            }
            else if et == L_PTR {
                n, p = init_number(init, p)
                emit(int_const(n, L_PTR))
            }
            else {
                n, p = init_number(init, p)
                emit(int_const(n, et))
            }
            count++
            if init[p] == ','
                p++
        }
        emit("]")
    }

    ; ---- the global initialization code and main ----

    sub initglobals_function() {
        ^^ir.Sub s = mem.alloc(sizeof(ir.Sub))
        s.name = ".init.globals"
        s.returns = ""
        s.chunks = prog.initglobals
        s.lastchunk = prog.initglobals
        function(s)
    }

    sub emit_main() {
        ; (wasi-libc's startup code calls the C main by its mangled name)
        if mos {
            ; (the simulator passes no arguments)
            emit("define i16 @main() {\nentry:\n")
        }
        else {
            if llvm32 {
                emit("define i32 @")
                emit(triple.c_main_symbol)
                emit("(i32 %argc, ptr %argv) {\n")
            }
            else
                emit("define i32 @main(i32 %argc, ptr %argv) {\n")
            emit("entry:\n  store i32 %argc, ptr @.sys.argc\n  store ptr %argv, ptr @.sys.argv\n")
        }
        if has_initglobals
            emit("  call void @.init.globals()\n")
        if mos
            emit("  call void @main.start()\n  ret i16 0\n}\n\n")
        else
            emit("  call void @main.start()\n  ret i32 0\n}\n\n")
    }
}
