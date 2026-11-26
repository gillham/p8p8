; The in-memory Prog8 intermediate representation and its .p8ir text writer.
; It mirrors the upstream IR: a program is a list of blocks; a block holds
; subroutines; a subroutine holds chunks; a chunk is a label followed by
; instructions (or a piece of inline IR text).  Variables, constants and
; struct definitions are kept at the program level under scoped names such
; as block.sub.var, exactly as upstream writes them, so that the upstream
; virtual machine can run what this writes.
;
; An instruction keeps its operands in fixed slots (up to three registers,
; one immediate, one memory reference, one symbol) and a 'mode' that says
; which slots are used and how they are written.  Registers are virtual,
; numbered from 1 per program; the register type table remembers the type
; each one was created with.

%import mem
%import buf
%import out
%import strings
%import float_platform

ir {
    %option ignore_unused

    ; IR data types
    const ubyte T_NONE = 0
    const ubyte T_BYTE = 1
    const ubyte T_WORD = 2
    const ubyte T_LONG = 3
    const ubyte T_QUAD = 4
    const ubyte T_FLOAT = 5
    const ubyte T_POINTER = 6
    str type_suffix = "-bwlqfp"
    str[] type_names = ["NONE", "BYTE", "WORD", "LONG", "QUAD", "FLOAT", "POINTER"]

    ; opcodes; the index is the position in opcode_names
    const ubyte OP_NOP = 0
    const ubyte OP_LOAD = 1
    const ubyte OP_LOADM = 2
    const ubyte OP_LOADX = 3
    const ubyte OP_LOADR = 4
    const ubyte OP_LOADI = 5
    const ubyte OP_LOADHR = 6
    const ubyte OP_STOREM = 7
    const ubyte OP_STOREX = 8
    const ubyte OP_STOREZM = 9
    const ubyte OP_STOREZI = 10
    const ubyte OP_STOREIM = 11
    const ubyte OP_STOREZX = 12
    const ubyte OP_STOREI = 13
    const ubyte OP_STOREHR = 14
    const ubyte OP_JUMP = 15
    const ubyte OP_JUMPI = 16
    const ubyte OP_CALLI = 17
    const ubyte OP_CALL = 18
    const ubyte OP_SYSCALL = 19
    const ubyte OP_RETURN = 20
    const ubyte OP_RETURNR = 21
    const ubyte OP_RETURNI = 22
    const ubyte OP_BSTCC = 23
    const ubyte OP_BSTCS = 24
    const ubyte OP_BSTEQ = 25
    const ubyte OP_BSTNE = 26
    const ubyte OP_BSTNEG = 27
    const ubyte OP_BSTPOS = 28
    const ubyte OP_BSTVC = 29
    const ubyte OP_BSTVS = 30
    const ubyte OP_BGTR = 31
    const ubyte OP_BGT = 32
    const ubyte OP_BLT = 33
    const ubyte OP_BGTSR = 34
    const ubyte OP_BGTS = 35
    const ubyte OP_BLTS = 36
    const ubyte OP_BGER = 37
    const ubyte OP_BGE = 38
    const ubyte OP_BLE = 39
    const ubyte OP_BGESR = 40
    const ubyte OP_BGES = 41
    const ubyte OP_BLES = 42
    const ubyte OP_INC = 43
    const ubyte OP_INCM = 44
    const ubyte OP_DEC = 45
    const ubyte OP_DECM = 46
    const ubyte OP_NEG = 47
    const ubyte OP_NEGM = 48
    const ubyte OP_ADDR = 49
    const ubyte OP_ADD = 50
    const ubyte OP_ADDM = 51
    const ubyte OP_ADDIM = 52
    const ubyte OP_SUBR = 53
    const ubyte OP_SUB = 54
    const ubyte OP_SUBM = 55
    const ubyte OP_SUBIM = 56
    const ubyte OP_MULR = 57
    const ubyte OP_MUL = 58
    const ubyte OP_MULM = 59
    const ubyte OP_MULSR = 60
    const ubyte OP_MULS = 61
    const ubyte OP_MULSM = 62
    const ubyte OP_DIVR = 63
    const ubyte OP_DIV = 64
    const ubyte OP_DIVM = 65
    const ubyte OP_DIVSR = 66
    const ubyte OP_DIVS = 67
    const ubyte OP_DIVSM = 68
    const ubyte OP_MODR = 69
    const ubyte OP_MOD = 70
    const ubyte OP_MODSR = 71
    const ubyte OP_MODS = 72
    const ubyte OP_SQRT = 73
    const ubyte OP_SQUARE = 74
    const ubyte OP_SGN = 75
    const ubyte OP_CMP = 76
    const ubyte OP_CMPI = 77
    const ubyte OP_EXT = 78
    const ubyte OP_EXTS = 79
    const ubyte OP_EXTL = 80
    const ubyte OP_EXTLS = 81
    const ubyte OP_EXTQ = 82
    const ubyte OP_EXTQS = 83
    const ubyte OP_ANDR = 84
    const ubyte OP_AND = 85
    const ubyte OP_ANDM = 86
    const ubyte OP_ORR = 87
    const ubyte OP_OR = 88
    const ubyte OP_ORM = 89
    const ubyte OP_XORR = 90
    const ubyte OP_XOR = 91
    const ubyte OP_XORM = 92
    const ubyte OP_INV = 93
    const ubyte OP_INVM = 94
    const ubyte OP_ASRN = 95
    const ubyte OP_LSRN = 96
    const ubyte OP_LSLN = 97
    const ubyte OP_ASRI = 98
    const ubyte OP_LSRI = 99
    const ubyte OP_LSLI = 100
    const ubyte OP_ASR = 101
    const ubyte OP_LSR = 102
    const ubyte OP_LSL = 103
    const ubyte OP_ROR = 104
    const ubyte OP_ROXR = 105
    const ubyte OP_ROL = 106
    const ubyte OP_ROXL = 107
    const ubyte OP_BITTST = 108
    const ubyte OP_BITSET = 109
    const ubyte OP_BITCLR = 110
    const ubyte OP_BITTOG = 111
    const ubyte OP_CLC = 112
    const ubyte OP_SEC = 113
    const ubyte OP_LSIGB = 114
    const ubyte OP_LSIGW = 115
    const ubyte OP_LSIGL = 116
    const ubyte OP_MSIGB = 117
    const ubyte OP_MSIGW = 118
    const ubyte OP_CONCAT = 119
    const ubyte OP_PUSH = 120
    const ubyte OP_POP = 121
    const ubyte OP_BREAKPOINT = 122
    const ubyte OP_DIVMODR = 123
    const ubyte OP_DIVMOD = 124
    const ubyte OP_SDIVMODR = 125
    const ubyte OP_SDIVMOD = 126
    const ubyte OP_FFROMUB = 127
    const ubyte OP_FFROMSB = 128
    const ubyte OP_FFROMUW = 129
    const ubyte OP_FFROMSW = 130
    const ubyte OP_FFROMSL = 131
    const ubyte OP_FTOUB = 132
    const ubyte OP_FTOSB = 133
    const ubyte OP_FTOUW = 134
    const ubyte OP_FTOSW = 135
    const ubyte OP_FTOSL = 136
    const ubyte OP_FCOMP = 137
    const ubyte OP_ROLM = 138
    const ubyte OP_ROXLM = 139
    const ubyte OP_RORM = 140
    const ubyte OP_ROXRM = 141
    const ubyte OP_PUSHST = 142
    const ubyte OP_POPST = 143
    const ubyte OP_FPOW = 144
    const ubyte OP_FABS = 145
    const ubyte OP_FSIN = 146
    const ubyte OP_FCOS = 147
    const ubyte OP_FTAN = 148
    const ubyte OP_FATAN = 149
    const ubyte OP_FLN = 150
    const ubyte OP_FLOG = 151
    const ubyte OP_FROUND = 152
    const ubyte OP_FFLOOR = 153
    const ubyte OP_FCEIL = 154
    const ubyte OP_FFROMSQ = 155
    const ubyte OP_FFROMUQ = 156
    const ubyte OP_FTOSQ = 157
    const ubyte OP_FTOUQ = 158
    const ubyte OP_ASRNM = 159
    const ubyte OP_LSRNM = 160
    const ubyte OP_LSLNM = 161
    const ubyte OP_LSRM = 162
    const ubyte OP_ASRM = 163
    const ubyte OP_LSLM = 164
    const ubyte OP_ALIGN = 165
    const ubyte OP_SEI = 166
    const ubyte OP_CLI = 167
    const ubyte OP_CALLFAR = 168        ; a banked call: the target text is "#bank,address"
    const ubyte OP_CALLFARVB = 169      ; a banked call with the bank in a register: "rN.b,address"
    const ubyte OP_LOADMZ = 170         ; a byte from memory into a word register, zero extended: loadmz.b r1.w,[mem]
    const ubyte OP_COUNT = 171

    str[] opcode_names = [
        "nop", "load", "loadm", "loadx", "loadr", "loadi", "loadhr", "storem", "storex", "storezm",
        "storezi", "storeim", "storezx", "storei", "storehr", "jump", "jumpi", "calli", "call", "syscall",
        "return", "returnr", "returni", "bstcc", "bstcs", "bsteq", "bstne", "bstneg", "bstpos", "bstvc",
        "bstvs", "bgtr", "bgt", "blt", "bgtsr", "bgts", "blts", "bger", "bge", "ble",
        "bgesr", "bges", "bles", "inc", "incm", "dec", "decm", "neg", "negm", "addr",
        "add", "addm", "addim", "subr", "sub", "subm", "subim", "mulr", "mul", "mulm",
        "mulsr", "muls", "mulsm", "divr", "div", "divm", "divsr", "divs", "divsm", "modr",
        "mod", "modsr", "mods", "sqrt", "square", "sgn", "cmp", "cmpi", "ext", "exts",
        "extl", "extls", "extq", "extqs", "andr", "and", "andm", "orr", "or", "orm",
        "xorr", "xor", "xorm", "inv", "invm", "asrn", "lsrn", "lsln", "asri", "lsri",
        "lsli", "asr", "lsr", "lsl", "ror", "roxr", "rol", "roxl", "bittst", "bitset",
        "bitclr", "bittog", "clc", "sec", "lsigb", "lsigw", "lsigl", "msigb", "msigw", "concat",
        "push", "pop", "breakpoint", "divmodr", "divmod", "sdivmodr", "sdivmod", "ffromub", "ffromsb", "ffromuw",
        "ffromsw", "ffromsl", "ftoub", "ftosb", "ftouw", "ftosw", "ftosl", "fcomp", "rolm", "roxlm",
        "rorm", "roxrm", "pushst", "popst", "fpow", "fabs", "fsin", "fcos", "ftan", "fatan",
        "fln", "flog", "fround", "ffloor", "fceil", "ffromsq", "ffromuq", "ftosq", "ftouq", "asrnm",
        "lsrnm", "lslnm", "lsrm", "asrm", "lslm", "align", "sei", "cli",
        "callfar", "callfarvb", "loadmz"
    ]

    ; operand modes: which slots an instruction uses and how they are written
    const ubyte M_NONE = 0      ; no operands
    const ubyte M_R = 1         ; r1
    const ubyte M_RR = 2        ; r1,r2
    const ubyte M_RRR = 3       ; r1,r2,r3
    const ubyte M_RI = 4        ; r1,#value
    const ubyte M_RRI = 5       ; r1,r2,#value
    const ubyte M_I = 6         ; #value
    const ubyte M_RM = 7        ; r1,[memory]  (memory may be indexed by r2*scale)
    const ubyte M_M = 8         ; [memory]  (memory may be indexed by r2*scale)
    const ubyte M_IM = 9        ; #value,[memory]
    const ubyte M_RP = 10       ; r1,[r2+offset]
    const ubyte M_P = 11        ; [r2+offset]
    const ubyte M_T = 12        ; target label
    const ubyte M_RIT = 13      ; r1,#value,target
    const ubyte M_RRT = 14      ; r1,r2,target
    const ubyte M_CALL = 15     ; target(args):results
    const ubyte M_RS = 16       ; r1,slot

    struct Instr {
        ^^Instr next
        ^^ubyte sym         ; memory symbol, immediate address symbol, or call/jump target
        ^^Arg args          ; call arguments
        ^^Arg results       ; call results
        quad value          ; immediate value, or a fixed address when sym is 0 in a memory reference
        float fvalue        ; a floating point immediate (type T_FLOAT)
        long offset         ; displacement of a memory reference
        uword r1
        uword r2
        uword r3
        ubyte op
        ubyte type          ; the instruction's type suffix (T_NONE for none)
        ubyte t1            ; the type r1 is written with, when it differs from type
        ubyte t2            ; the same for r2
        ubyte t3            ; and r3
        ubyte mode
        ubyte scale         ; element size of an indexed memory reference
        ubyte slot          ; hardware register slot number
    }

    struct Arg {
        ^^Arg next
        ^^ubyte name        ; parameter name (scoped), or 0
        quad value          ; immediate value when reg is 0
        uword reg           ; register, or 0 for an immediate
        ubyte type
        ubyte slot          ; hardware slot (255 = none)
    }

    const ubyte C_CODE = 0
    const ubyte C_ASM = 1       ; inline IR or assembly text

    struct Chunk {
        ^^Chunk next
        ^^ubyte label       ; or 0
        ^^Instr first
        ^^Instr last
        ^^ubyte text        ; inline text (C_ASM)
        long textlen
        long order          ; a block's chunk: its place among the block's chunks and subroutines
        ubyte kind
        bool is_ir          ; inline text is IR, not native assembly
    }

    struct Param {
        ^^Param next
        ^^ubyte name        ; scoped name
        ubyte type          ; prog8 type keyword name index: see type_string
        ^^ubyte typestr     ; IR type string of the parameter ("ubyte", "pointer" ...)
        ^^ubyte reg         ; an asmsub parameter's register or status flag ("A", "AY", "R0", "Pc"), or 0
        ^^ubyte asmtype     ; and its type as the asmsub declaration spells it ("ubyte", "^^ubyte")
    }

    ; the overlay numbers that the program's %overlay directives name (a block or a
    ; subroutine that nothing uses has no code, and its overlay may then be empty)
    bool[256] overlay_wanted

    struct Sub {
        ^^Sub next
        ^^ubyte name        ; scoped name
        long order          ; its place among its block's chunks and subroutines
        ^^Param params
        ^^ubyte returns     ; comma separated IR type strings, or empty
        ^^Chunk chunks
        ^^Chunk lastchunk
        ^^ubyte pos         ; position text
        ^^ubyte asmtext     ; for an asmsub/extsub: its inline text, or 0
        long asmlen
        bool is_asm
        bool is_external
        bool is_inline
        bool asm_is_ir      ; asmtext is inline IR, not native assembly
        bool clobbers_declared
        ubyte overlay       ; %overlay n in it: its code goes into that overlay (0: where its block's is)
        ^^ubyte why_not     ; -overlayinfo: why it cannot go into an overlay by itself, or 0
        bool keeps_data     ; -overlayinfo: its assembly writes to places in its own text
        bool no_pool        ; backend use: may run from an interrupt, so it keeps off the shared temporaries
        bool reenter        ; backend use: may be called again while it runs (recursion, or it is not known)
        ^^ubyte clobbered   ; an asmsub's clobbered CPU registers ("A,X,Y"), or 0
        ^^ubyte asmreturns  ; an asmsub's returns as "register:type,...", or 0 when it names no registers
    }

    struct Block {
        ^^Block next
        ^^ubyte name
        ^^Sub subs
        ^^Sub lastsub
        ^^Chunk chunks      ; block level chunks (labels, inline asm)
        ^^Chunk lastchunk
        long members        ; how many chunks and subroutines it has been given (their order numbers)
        ^^ubyte pos
        ^^ubyte address     ; text or 0
        bool library
        bool force_output
        bool chipram        ; %option amiga_chipram: its code and variables go in the Amiga's chip memory
        ubyte overlay       ; %overlay n: its code goes into that overlay (0: the main program)
        ^^ubyte why_not     ; -overlayinfo: why the block cannot go into an overlay, or 0
        bool keeps_data     ; -overlayinfo: its assembly writes to places in its own text
        bool overlay_safe   ; %option overlay_safe: it never chooses a bank, and is called like the library from an overlay_data block
        bool overlay_data   ; %option overlay_data: the library is called with this block's overlay left in the window
        bool no_prefixing
        bool ignore_unused
    }

    ; a static variable, constant, memory-mapped variable or struct definition
    const ubyte V_VAR = 0
    const ubyte V_CONST = 1
    const ubyte V_MEMVAR = 2
    const ubyte V_STRUCT = 3
    const ubyte V_SLAB = 4      ; a memory() block: typestr unused, size and align set
    const ubyte V_INSTANCE = 5  ; a static struct instance: typestr is the struct's name, init the "type:value,..." list or 0, size set

    struct Var {
        ^^Var next
        ^^ubyte name        ; scoped name
        ^^ubyte typestr     ; IR type string ("ubyte", "uword[10]", "pointer", or the fields of a struct)
        ^^ubyte init        ; initializer text (the part after '='), or 0 for no initializer
        ^^ubyte zp          ; "DONTCARE" etc.
        long align
        long size           ; struct size
        long zpaddr         ; backend use: its address in the zero page, or 0
        pointer owner       ; backend use: the ^^Sub a stack local belongs to
        ubyte kind
        bool shared
        bool dirty
        bool noprefix
        bool stacklocal     ; backend use: lives in a stack slot of its subroutine
        bool plain          ; backend use: every use is of the whole variable
        bool addressable    ; backend use: an address that is only loaded, stored and added to
        ubyte hwreg         ; backend use: the CPU register it lives in, or 0
        long uses           ; backend use: how often the code names it
        bool split          ; one half (_lsb or _msb) of a split word array
        ubyte home          ; backend use: the overlay its initial values are in (0: main memory)
    }

    struct Program {
        ^^ubyte name
        ^^Chunk initglobals     ; code that initializes block variables with non-constant values
        ^^Block blocks
        ^^Block lastblock
        ^^Var vars
        ^^Var lastvar
        ^^ubyte target
        bool floats
        ^^ubyte options     ; the <OPTIONS> lines after compTarget (output type, launcher, zero page, addresses), or 0 for the defaults
        long vars_address   ; %varsaddress: where the variables without an initial value go, or -1
    }

    ; register types, indexed by register number
    ^^ubyte regtypes = 0
    long regcap = 0
    uword regcount = 0
    uword regmax = 0            ; the highest register number given out (regcount goes back where numbers are used again)
    long instr_count = 0
    long chunk_count = 0

    ; ---- building ----

    sub new_program(^^ubyte name, ^^ubyte target) -> ^^Program {
        ^^Program p = mem.alloc(sizeof(Program))
        p.name = name
        p.target = target
        p.initglobals = mem.alloc(sizeof(Chunk))
        p.vars_address = -1
        regcount = 0
        regmax = 0
        pool = 0
        pinned = 0
        pinned_cap = 0
        instr_count = 0
        chunk_count = 0
        return p
    }

    ; Where every subroutine is a function with registers of its own (the llvm targets),
    ; a subroutine uses the numbers of the ones before it again, and a number is only
    ; ever a register of one type: so the one table of types stays true for all of them.
    ; (A program the size of this compiler has more registers than there are numbers.)
    ; For each type the numbers given out so far, and how many of them the subroutine
    ; being generated has taken.
    const ubyte POOLS = 8
    bool reuse_numbers = false
    ^^pointer pool = 0              ; POOLS tables of register numbers
    uword[POOLS] pool_count
    uword[POOLS] pool_cap
    uword[POOLS] pool_taken
    ^^ubyte pinned = 0              ; per register: its type was changed, it is not given out again
    long pinned_cap = 0

    ; begin a subroutine: the numbers taken so far, to give back to end_numbers
    sub begin_numbers() -> ^^uword {
        if not reuse_numbers
            return 0
        ^^uword taken = mem.alloc(POOLS * sizeof(uword))
        ubyte k = 0
        while k < POOLS {
            taken[k] = pool_taken[k]
            pool_taken[k] = 0
            k++
        }
        return taken
    }

    sub end_numbers(^^uword taken) {
        if taken == 0
            return
        ubyte k = 0
        while k < POOLS {
            pool_taken[k] = taken[k]
            k++
        }
    }

    ; a register changes its type (an address-sized integer that is a pointer from here on)
    sub retype(uword r, ubyte type) {
        regtypes[r] = type
        if reuse_numbers {
            if (r as long) >= pinned_cap {
                long newcap = regcap
                if newcap <= (r as long)
                    newcap = (r as long) + 256
                pinned = mem.grow(pinned, pinned_cap, newcap)
                long z = pinned_cap
                while z < newcap {
                    pinned[z] = 0
                    z++
                }
                pinned_cap = newcap
            }
            pinned[r] = 1
        }
    }

    sub new_reg(ubyte type) -> uword {
        if reuse_numbers and type < POOLS {
            if pool == 0 {
                pool = mem.alloc(POOLS as long * sizeof(pointer))
                ubyte pk = 0
                while pk < POOLS {
                    pool[pk] = 0
                    pool_count[pk] = 0
                    pool_cap[pk] = 0
                    pool_taken[pk] = 0
                    pk++
                }
            }
            ^^uword numbers = pool[type]
            while pool_taken[type] < pool_count[type] {
                uword again = numbers[pool_taken[type]]
                pool_taken[type]++
                if (again as long) >= pinned_cap or pinned[again] == 0
                    return again
            }
        }
        if regcount == 65535 {
            ; (register numbers are words; counting on would begin again at 0, without a word)
            out.err()
            out.puts("error: the program needs more than 65535 IR registers")
            out.nl()
            out.exit(1)
        }
        regcount++
        if regcount >= regcap {
            long newcap = regcap * 2
            if newcap < 256
                newcap = 256
            regtypes = mem.grow(regtypes, regcap, newcap)
            regcap = newcap
        }
        regtypes[regcount] = type
        if regcount > regmax
            regmax = regcount
        if reuse_numbers and type < POOLS {
            ; (a new number: the first of its type that this subroutine did not find)
            if pool_count[type] == pool_cap[type] {
                long morecap = (pool_cap[type] as long) * 2
                if morecap < 64
                    morecap = 64
                pool[type] = mem.grow(pool[type], (pool_cap[type] as long) * sizeof(uword), morecap * sizeof(uword))
                pool_cap[type] = morecap as uword
            }
            ^^uword grown = pool[type]
            grown[pool_count[type]] = regcount
            pool_count[type]++
            pool_taken[type] = pool_count[type]
        }
        return regcount
    }

    sub reg_type(uword r) -> ubyte {
        if r >= regcap
            return T_NONE
        return regtypes[r]
    }

    ; Records the type of a register that came from IR text, growing the table as needed.
    sub note_reg(uword r, ubyte type) {
        if r >= regcap {
            long newcap = regcap * 2
            if newcap < 256
                newcap = 256
            while newcap <= r
                newcap *= 2
            regtypes = mem.grow(regtypes, regcap, newcap)
            regcap = newcap
        }
        if regtypes[r] == T_NONE
            regtypes[r] = type
        if r > regcount
            regcount = r
        if r > regmax
            regmax = r
    }

    sub add_block(^^Program p, ^^ubyte name, ^^ubyte pos, bool library) -> ^^Block {
        ^^Block b = mem.alloc(sizeof(Block))
        b.name = name
        b.pos = pos
        b.library = library
        if p.lastblock == 0
            p.blocks = b
        else
            p.lastblock.next = b
        p.lastblock = b
        return b
    }

    sub add_sub(^^Block b, ^^ubyte name, ^^ubyte pos) -> ^^Sub {
        ^^Sub s = mem.alloc(sizeof(Sub))
        s.name = name
        s.pos = pos
        s.returns = ""
        s.order = b.members
        b.members++
        if b.lastsub == 0
            b.subs = s
        else
            b.lastsub.next = s
        b.lastsub = s
        return s
    }

    sub add_param(^^Sub s, ^^ubyte name, ^^ubyte typestr) -> ^^Param {
        ^^Param p = mem.alloc(sizeof(Param))
        p.name = name
        p.typestr = typestr
        if s.params == 0 {
            s.params = p
            return p
        }
        ^^Param last = s.params
        while last.next != 0
            last = last.next
        last.next = p
        return p
    }

    ; A new code chunk with an optional label, appended to the subroutine.
    sub add_chunk(^^Sub s, ^^ubyte label) -> ^^Chunk {
        ^^Chunk c = mem.alloc(sizeof(Chunk))
        c.label = label
        if s.lastchunk == 0
            s.chunks = c
        else
            s.lastchunk.next = c
        s.lastchunk = c
        chunk_count++
        return c
    }

    sub add_asm_chunk(^^Sub s, ^^ubyte label, ^^ubyte text, long length, bool is_ir) -> ^^Chunk {
        ^^Chunk c = add_chunk(s, label)
        c.kind = C_ASM
        c.text = text
        c.textlen = length
        c.is_ir = is_ir
        return c
    }

    sub add_block_chunk(^^Block b, ^^ubyte label) -> ^^Chunk {
        ^^Chunk c = mem.alloc(sizeof(Chunk))
        c.label = label
        c.order = b.members
        b.members++
        if b.lastchunk == 0
            b.chunks = c
        else
            b.lastchunk.next = c
        b.lastchunk = c
        chunk_count++
        return c
    }

    sub add_var(^^Program p, ubyte kind, ^^ubyte name, ^^ubyte typestr, ^^ubyte init) -> ^^Var {
        ^^Var v = mem.alloc(sizeof(Var))
        v.kind = kind
        v.name = name
        v.typestr = typestr
        v.init = init
        v.zp = "DONTCARE"
        if p.lastvar == 0
            p.vars = v
        else
            p.lastvar.next = v
        p.lastvar = v
        return v
    }

    ; ---- instructions ----

    sub emit(^^Chunk c, ubyte op, ubyte type, ubyte mode) -> ^^Instr {
        ^^Instr i = mem.alloc(sizeof(Instr))
        i.op = op
        i.type = type
        i.mode = mode
        i.scale = 1
        if c.last == 0
            c.first = i
        else
            c.last.next = i
        c.last = i
        instr_count++
        return i
    }

    sub emit_r(^^Chunk c, ubyte op, ubyte type, uword r1) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_R)
        i.r1 = r1
        return i
    }

    sub emit_rr(^^Chunk c, ubyte op, ubyte type, uword r1, uword r2) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RR)
        i.r1 = r1
        i.r2 = r2
        return i
    }

    sub emit_rrr(^^Chunk c, ubyte op, ubyte type, uword r1, uword r2, uword r3) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RRR)
        i.r1 = r1
        i.r2 = r2
        i.r3 = r3
        return i
    }

    sub emit_ri(^^Chunk c, ubyte op, ubyte type, uword r1, quad value) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RI)
        i.r1 = r1
        i.value = value
        return i
    }

    ; r1,#symbol+offset  (the address of a symbol)
    sub emit_rsym(^^Chunk c, ubyte op, ubyte type, uword r1, ^^ubyte sym, long offset) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RI)
        i.r1 = r1
        i.sym = sym
        i.offset = offset
        return i
    }

    ; r1,#float
    sub emit_rf(^^Chunk c, ubyte op, uword r1, float value) -> ^^Instr {
        ^^Instr i = emit(c, op, T_FLOAT, M_RI)
        i.r1 = r1
        i.fvalue = value
        return i
    }

    ; #float,[sym+offset]
    sub emit_fm(^^Chunk c, ubyte op, float value, ^^ubyte sym, long offset) -> ^^Instr {
        ^^Instr i = emit(c, op, T_FLOAT, M_IM)
        i.fvalue = value
        i.sym = sym
        i.offset = offset
        return i
    }

    sub emit_i(^^Chunk c, ubyte op, ubyte type, quad value) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_I)
        i.value = value
        return i
    }

    ; r1,[sym+offset]
    sub emit_rm(^^Chunk c, ubyte op, ubyte type, uword r1, ^^ubyte sym, long offset) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RM)
        i.r1 = r1
        i.sym = sym
        i.offset = offset
        return i
    }

    ; r1,[sym+offset+r2*scale]
    sub emit_rmx(^^Chunk c, ubyte op, ubyte type, uword r1, ^^ubyte sym, long offset, uword r2, ubyte scale) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RM)
        i.r1 = r1
        i.sym = sym
        i.offset = offset
        i.r2 = r2
        i.scale = scale
        return i
    }

    ; [sym+offset]
    sub emit_m(^^Chunk c, ubyte op, ubyte type, ^^ubyte sym, long offset) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_M)
        i.sym = sym
        i.offset = offset
        return i
    }

    ; #value,[sym+offset]
    sub emit_im(^^Chunk c, ubyte op, ubyte type, quad value, ^^ubyte sym, long offset) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_IM)
        i.value = value
        i.sym = sym
        i.offset = offset
        return i
    }

    ; r1,[r2+offset]
    sub emit_rp(^^Chunk c, ubyte op, ubyte type, uword r1, uword r2, long offset) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RP)
        i.r1 = r1
        i.r2 = r2
        i.offset = offset
        return i
    }

    ; [r2+offset]
    sub emit_p(^^Chunk c, ubyte op, ubyte type, uword r2, long offset) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_P)
        i.r2 = r2
        i.offset = offset
        return i
    }

    sub emit_t(^^Chunk c, ubyte op, ^^ubyte label) -> ^^Instr {
        ^^Instr i = emit(c, op, T_NONE, M_T)
        i.sym = label
        return i
    }

    sub emit_rit(^^Chunk c, ubyte op, ubyte type, uword r1, quad value, ^^ubyte label) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RIT)
        i.r1 = r1
        i.value = value
        i.sym = label
        return i
    }

    sub emit_rrt(^^Chunk c, ubyte op, ubyte type, uword r1, uword r2, ^^ubyte label) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RRT)
        i.r1 = r1
        i.r2 = r2
        i.sym = label
        return i
    }

    const ubyte SLOT_FLAGS = 100        ; Arg.slot values from here on are the status flags Pc, Pz, Pv, Pn

    sub emit_call(^^Chunk c, ^^ubyte target) -> ^^Instr {
        ^^Instr i = emit(c, OP_CALL, T_NONE, M_CALL)
        i.sym = target
        return i
    }

    sub emit_syscall(^^Chunk c, ^^ubyte number) -> ^^Instr {
        ^^Instr i = emit(c, OP_SYSCALL, T_NONE, M_CALL)
        i.sym = number
        ; the value too, for the backends: decimal or $hex
        quad v = 0
        long p = 0
        if number[0] == '$' {
            p = 1
            while number[p] != 0 {
                ubyte d = number[p]
                if d >= 'a'
                    d = d - 'a' + 10
                else
                    d -= '0'
                v = (v << 4) | d
                p++
            }
        }
        else {
            while number[p] != 0 {
                v = v * 10 + (number[p] - '0')
                p++
            }
        }
        i.value = v
        return i
    }

    sub emit_rs(^^Chunk c, ubyte op, ubyte type, uword r1, ubyte slot) -> ^^Instr {
        ^^Instr i = emit(c, op, type, M_RS)
        i.r1 = r1
        i.slot = slot
        return i
    }

    sub new_arg(^^ubyte name, uword reg, ubyte type) -> ^^Arg {
        ^^Arg a = mem.alloc(sizeof(Arg))
        a.name = name
        a.reg = reg
        a.type = type
        a.slot = 255
        return a
    }

    sub add_arg(^^Instr i, ^^Arg a) {
        if i.args == 0 {
            i.args = a
            return
        }
        ^^Arg last = i.args
        while last.next != 0
            last = last.next
        last.next = a
    }

    sub add_result(^^Instr i, ^^Arg a) {
        if i.results == 0 {
            i.results = a
            return
        }
        ^^Arg last = i.results
        while last.next != 0
            last = last.next
        last.next = a
    }

    ; ---- writing ----

    ^^buf.Buf text = 0

    sub add(str s) {
        buf.add_str(text, s)
    }

    sub add_name(^^ubyte s) {
        buf.add_str(text, s)
    }

    ; text with the XML special characters escaped
    sub add_escaped(^^ubyte s, long length) {
        long i = 0
        while i < length {
            ubyte c = s[i]
            if c == '<'
                buf.add_str(text, "&lt;")
            else if c == '>'
                buf.add_str(text, "&gt;")
            else if c == '&'
                buf.add_str(text, "&amp;")
            else
                buf.add_byte(text, c)
            i++
        }
    }

    ; a number as upstream's toHex() writes it: decimal below 16, else $hex
    sub write_instance(^^Var v) {
        add_name(v.typestr)
        buf.add_byte(text, ' ')
        add_name(v.name)
        add(" size=")
        buf.add_long(text, v.size)
        if v.init != 0 {
            add(" values=")
            add_name(v.init)
        }
        buf.add_byte(text, '\n')
    }

    sub add_number(quad v) {
        if v < 0 {
            buf.add_byte(text, '-')
            v = -v
        }
        if v < 16 {
            buf.add_quad(text, v)
            return
        }
        buf.add_byte(text, '$')
        ubyte digits = 0
        quad t = v
        while t != 0 {
            digits++
            t >>= 4
        }
        ubyte shift = (digits - 1) * 4
        repeat digits {
            buf.add_byte(text, buf.hex_digit(((v >> shift) & 15) as ubyte))
            if shift >= 4
                shift -= 4
        }
    }

    sub add_reg(uword r, ubyte type) {
        if type == T_FLOAT
            buf.add_byte(text, 'f')
        buf.add_byte(text, 'r')
        buf.add_long(text, r)
        buf.add_byte(text, '.')
        buf.add_byte(text, type_suffix[type])
    }

    sub reg_t(^^Instr i, ubyte t, ubyte fallback) -> ubyte {
        if t != T_NONE
            return t
        if i.type != T_NONE
            return i.type
        return fallback
    }

    sub add_memory(^^Instr i) {
        buf.add_byte(text, '[')
        if i.sym != 0
            buf.add_str(text, i.sym)
        else
            add_number(i.offset)
        if i.sym != 0 and i.offset != 0 {
            buf.add_byte(text, '+')
            buf.add_long(text, i.offset)
        }
        if i.r2 != 0 {
            ; the index register keeps its own width
            buf.add_byte(text, '+')
            ubyte ixt = i.t2
            if ixt == T_NONE
                ixt = reg_type(i.r2)
            add_reg(i.r2, ixt)
            if i.scale != 1 {
                buf.add_byte(text, '*')
                buf.add_long(text, i.scale)
            }
        }
        buf.add_byte(text, ']')
    }

    ; a floating point number with a '.' or exponent so it reads as a float
    sub add_float(float v) {
        ^^ubyte t = float_platform.format(v)
        buf.add_str(text, t)
        long i = 0
        bool fraction = false
        while t[i] != 0 {
            if t[i] == '.' or t[i] == 'e' or t[i] == 'E' or t[i] == 'N' or t[i] == 'I'
                fraction = true
            i++
        }
        if not fraction
            buf.add_str(text, ".0")
    }

    sub add_immediate(^^Instr i) {
        buf.add_byte(text, '#')
        if i.type == T_FLOAT {
            add_float(i.fvalue)
            buf.add_str(text, ".f")
            return
        }
        if i.sym != 0 {
            buf.add_str(text, i.sym)
            if i.offset != 0 {
                buf.add_byte(text, '+')
                buf.add_long(text, i.offset)
            }
            return
        }
        add_number(i.value)
        buf.add_byte(text, '.')
        buf.add_byte(text, type_suffix[i.type])
    }

    ; a numeric immediate: #value.type
    sub add_value(^^Instr i) {
        buf.add_byte(text, '#')
        if i.type == T_FLOAT {
            add_float(i.fvalue)
            buf.add_str(text, ".f")
            return
        }
        add_number(i.value)
        buf.add_byte(text, '.')
        buf.add_byte(text, type_suffix[i.type])
    }

    sub add_arglist(^^Arg a) {
        bool first = true
        while a != 0 {
            if not first
                buf.add_byte(text, ',')
            first = false
            if a.name != 0 {
                buf.add_str(text, a.name)
                buf.add_byte(text, '=')
            }
            if a.reg != 0
                add_reg(a.reg, a.type)
            else if a.type == T_NONE {
                ; (a result that is only a place: "@s12", a hardware register the call writes)
            }
            else {
                buf.add_byte(text, '#')
                add_number(a.value)
                buf.add_byte(text, '.')
                buf.add_byte(text, type_suffix[a.type])
            }
            if a.slot >= SLOT_FLAGS and a.slot != 255 {
                ; a CPU status flag
                when a.slot - SLOT_FLAGS {
                    0 -> buf.add_str(text, "@Pc")
                    1 -> buf.add_str(text, "@Pz")
                    2 -> buf.add_str(text, "@Pv")
                    else -> buf.add_str(text, "@Pn")
                }
            }
            else if a.slot != 255 {
                buf.add_str(text, "@s")
                buf.add_long(text, a.slot)
            }
            a = a.next
        }
    }

    sub write_instr(^^Instr i) {
        if i.op == OP_CALLI or i.op == OP_JUMPI {
            ; through an address in a register: "calli (r1.p)()" and "jumpi (r1.p)"
            buf.add_str(text, opcode_names[i.op])
            buf.add_str(text, " (")
            add_reg(i.r1, T_POINTER)
            buf.add_byte(text, ')')
            if i.op == OP_CALLI
                buf.add_str(text, "()")
            buf.add_byte(text, '\n')
            return
        }
        buf.add_str(text, opcode_names[i.op])
        if i.type != T_NONE {
            buf.add_byte(text, '.')
            buf.add_byte(text, type_suffix[i.type])
        }
        if i.mode != M_NONE
            buf.add_byte(text, ' ')
        when i.mode {
            M_R -> add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
            M_RR -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_reg(i.r2, reg_t(i, i.t2, reg_type(i.r2)))
            }
            M_RRR -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_reg(i.r2, reg_t(i, i.t2, reg_type(i.r2)))
                buf.add_byte(text, ',')
                add_reg(i.r3, reg_t(i, i.t3, reg_type(i.r3)))
            }
            M_RI -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_immediate(i)
            }
            M_RRI -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_reg(i.r2, reg_t(i, i.t2, reg_type(i.r2)))
                buf.add_byte(text, ',')
                add_value(i)
            }
            M_I -> add_immediate(i)
            M_RM -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_memory(i)
            }
            M_M -> add_memory(i)
            M_IM -> {
                add_value(i)
                buf.add_byte(text, ',')
                add_memory(i)
            }
            M_RP -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_pointer(i)
            }
            M_P -> add_pointer(i)
            M_T -> buf.add_str(text, i.sym)
            M_RIT -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_value(i)
                buf.add_byte(text, ',')
                buf.add_str(text, i.sym)
            }
            M_RRT -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_byte(text, ',')
                add_reg(i.r2, reg_t(i, i.t2, reg_type(i.r2)))
                buf.add_byte(text, ',')
                buf.add_str(text, i.sym)
            }
            M_CALL -> {
                buf.add_str(text, i.sym)
                buf.add_byte(text, '(')
                add_arglist(i.args)
                buf.add_byte(text, ')')
                if i.results != 0 {
                    buf.add_byte(text, ':')
                    add_arglist(i.results)
                }
            }
            M_RS -> {
                add_reg(i.r1, reg_t(i, i.t1, reg_type(i.r1)))
                buf.add_str(text, ",s")
                buf.add_long(text, i.slot)
                buf.add_byte(text, '.')
                buf.add_byte(text, type_suffix[i.type])
            }
        }
        buf.add_byte(text, '\n')
    }

    sub add_pointer(^^Instr i) {
        buf.add_byte(text, '[')
        add_reg(i.r2, T_POINTER)
        if i.offset != 0 {
            buf.add_byte(text, '+')
            buf.add_long(text, i.offset)
        }
        buf.add_byte(text, ']')
    }

    sub write_chunk(^^Chunk c) {
        if c.kind == C_ASM {
            add("<ASM")
            if c.label != 0 {
                add(" LABEL=\"")
                add_name(c.label)
                add("\"")
            }
            if c.is_ir
                add(" IR=\"true\">\n")
            else
                add(" IR=\"false\">\n")
            add_escaped(c.text, c.textlen)
            add("\n</ASM>\n")
            return
        }
        add("<CHUNK")
        if c.label != 0 {
            add(" LABEL=\"")
            add_name(c.label)
            add("\"")
        }
        add("><REGS><![CDATA[]]></REGS><CODE>\n")
        ^^Instr i = c.first
        while i != 0 {
            write_instr(i)
            i = i.next
        }
        add("</CODE></CHUNK>\n")
    }

    sub write_var_line(^^Var v) {
        add_name(v.typestr)
        buf.add_byte(text, ' ')
        add_name(v.name)
        if v.init != 0 {
            buf.add_byte(text, '=')
            if v.split
                add_escaped(v.init, buf.cstr_len(v.init))       ; @<name and @>name
            else
                add_name(v.init)
        }
        add(" zp=")
        add_name(v.zp)
        if v.split
            add(" split=true")
        if v.align != 0 {
            add(" align=")
            buf.add_long(text, v.align)
        }
        if v.shared
            add(" shared=true")
        buf.add_byte(text, '\n')
    }

    sub write_vars(^^Program p) {
        add("<VARS>\n<NOINITCLEAN>\n")
        ^^Var v = p.vars
        while v != 0 {
            if v.kind == V_VAR and v.init == 0 and not v.dirty
                write_var_line(v)
            v = v.next
        }
        add("</NOINITCLEAN>\n<NOINITDIRTY>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_VAR and v.init == 0 and v.dirty
                write_var_line(v)
            v = v.next
        }
        add("</NOINITDIRTY>\n<INIT>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_VAR and v.init != 0
                write_var_line(v)
            v = v.next
        }
        add("</INIT>\n<STRUCTINSTANCESNOINIT>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_INSTANCE and v.init == 0
                write_instance(v)
            v = v.next
        }
        add("</STRUCTINSTANCESNOINIT>\n<STRUCTINSTANCES>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_INSTANCE and v.init != 0
                write_instance(v)
            v = v.next
        }
        add("</STRUCTINSTANCES>\n<STRUCTDEFS>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_STRUCT {
                add_name(v.name)
                add(" size=")
                buf.add_long(text, v.size)
                add(" fields=")
                add_name(v.typestr)
                buf.add_byte(text, '\n')
            }
            v = v.next
        }
        add("</STRUCTDEFS>\n<CONSTANTS>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_CONST {
                add_name(v.typestr)
                buf.add_byte(text, ' ')
                add_name(v.name)
                buf.add_byte(text, '=')
                add_name(v.init)
                if v.noprefix
                    add(" noprefix")
                buf.add_byte(text, '\n')
            }
            v = v.next
        }
        add("</CONSTANTS>\n<MEMORYMAPPED>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_MEMVAR {
                buf.add_byte(text, '@')
                add_name(v.typestr)
                buf.add_byte(text, ' ')
                add_name(v.name)
                buf.add_byte(text, '=')
                add_name(v.init)
                buf.add_byte(text, '\n')
            }
            v = v.next
        }
        add("</MEMORYMAPPED>\n<MEMORYSLABS>\n")
        v = p.vars
        while v != 0 {
            if v.kind == V_SLAB {
                add_name(v.name)
                buf.add_byte(text, ' ')
                buf.add_long(text, v.size)
                buf.add_byte(text, ' ')
                buf.add_long(text, v.align)
                buf.add_byte(text, '\n')
            }
            v = v.next
        }
        add("</MEMORYSLABS>\n</VARS>\n")
    }

    sub write_sub(^^Sub s) {
        if s.is_asm {
            add("<ASMSUB NAME=\"")
            add_name(s.name)
            add("\" ADDRESS=\"\" CLOBBERS=\"")
            if s.clobbered != 0
                add_name(s.clobbered)
            if s.clobbers_declared
                add("\" CLOBBERSDECLARED=\"true")
            add("\" RETURNS=\"")
            if s.asmreturns != 0
                add_name(s.asmreturns)
            else if s.returns[0] != 0 {
                add("-:")
                add_name(s.returns)
            }
            add("\" POS=\"")
            add_name(s.pos)
            if s.is_inline
                add("\" INLINE=\"true\"")
            else
                add("\" INLINE=\"false\"")
            if s.is_external
                add(" EXTERNAL=\"true\"")
            add(">\n<ASMPARAMS>\n")
            ^^Param ap = s.params
            while ap != 0 {
                if ap.reg != 0 {
                    add_name(ap.asmtype)
                    buf.add_byte(text, ' ')
                    add_name(ap.reg)
                    buf.add_byte(text, '\n')
                }
                else {
                    add_name(ap.typestr)
                    add(" -\n")
                }
                ap = ap.next
            }
            add("</ASMPARAMS>\n<ASM LABEL=\"")
            add_name(s.name)
            if s.asmtext != 0 {
                if s.asm_is_ir
                    add("\" IR=\"true\">\n")
                else
                    add("\" IR=\"false\">\n")
                add_escaped(s.asmtext, s.asmlen)
            }
            else
                add("\" IR=\"false\">")
            add("\n</ASM>\n</ASMSUB>\n\n")
            return
        }
        add("<SUB NAME=\"")
        add_name(s.name)
        add("\" RETURNS=\"")
        add_name(s.returns)
        add("\" POS=\"")
        add_name(s.pos)
        add("\">\n<PARAMS>\n")
        ^^Param p = s.params
        while p != 0 {
            add_name(p.typestr)
            buf.add_byte(text, ' ')
            add_name(p.name)
            buf.add_byte(text, '\n')
            p = p.next
        }
        add("</PARAMS>\n")
        ^^Chunk c = s.chunks
        while c != 0 {
            if c.kind == C_ASM or c.first != 0 or c.label != 0
                write_chunk(c)       ; (upstream's reader refuses a chunk with neither code nor label)
            c = c.next
        }
        add("</SUB>\n\n")
    }

    sub write_block(^^Block b) {
        add("<BLOCK NAME=\"")
        add_name(b.name)
        add("\" ADDRESS=\"")
        if b.address != 0
            add_name(b.address)
        add("\"")
        if b.force_output
            add(" FORCEOUTPUT=\"true\"")
        if b.no_prefixing
            add(" NOPREFIXING=\"true\"")
        if b.ignore_unused
            add(" IGNOREUNUSED=\"true\"")
        if b.chipram
            add(" AMIGACHIPRAM=\"true\"")
        if b.library
            add(" LIBRARY=\"true\"")
        else
            add(" LIBRARY=\"false\"")
        add(" POS=\"")
        add_name(b.pos)
        add("\">\n")
        ; its chunks and subroutines in the order of the source (each list is in that order)
        ^^Chunk c = b.chunks
        ^^Sub s = b.subs
        while c != 0 or s != 0 {
            if s == 0 or (c != 0 and c.order < s.order) {
                if c.kind == C_ASM or c.first != 0 or c.label != 0
                    write_chunk(c)       ; (upstream's reader refuses a chunk with neither code nor label)
                c = c.next
            }
            else {
                write_sub(s)
                s = s.next
            }
        }
        add("</BLOCK>\n\n")
    }

    ; which section of the file a variable is in, as a letter
    sub var_letter(^^Var v) -> ubyte {
        when v.kind {
            V_VAR -> {
                if v.init != 0
                    return 'i'
                if v.dirty
                    return 'd'
                return 'c'
            }
            V_INSTANCE -> {
                if v.init != 0
                    return 's'
                return 'n'
            }
            V_STRUCT -> return 't'
            V_CONST -> return 'k'
            V_MEMVAR -> return 'm'
        }
        return 'b'      ; a memory slab
    }

    ; Writes the whole program as .p8ir text into the buffer.
    sub write(^^Program p, ^^buf.Buf b) {
        text = b
        add("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<PROGRAM NAME=\"")
        add_name(p.name)
        add("\" COMPILERVERSION=\"p8p8\" IRFORMAT=\"8\"")
        ; (attributes of p8p8's own, for reading the file back as it was: upstream's reader
        ; passes them by.  The file has the variables by kind and only the registers that
        ; are left, so the order they were declared in and every register's type go here:
        ; a letter each, see var_letter and type_suffix.)
        if p.floats
            add(" FLOATS=\"true\"")
        if p.vars_address >= 0 {
            add(" VARSADDRESS=\"")
            buf.add_long(text, p.vars_address)
            add("\"")
        }
        add(" VARORDER=\"")
        ^^Var ov = p.vars
        while ov != 0 {
            buf.add_byte(text, var_letter(ov))
            ov = ov.next
        }
        add("\" REGTYPES=\"")
        uword rr = 1
        while rr <= regmax and rr != 0 {        ; (regmax: where numbers are used again regcount is not the last)
            if regtypes[rr] == T_NONE
                buf.add_byte(text, '-')
            else
                buf.add_byte(text, type_suffix[regtypes[rr]])
            rr++
        }
        add("\"")
        add(">\n<OPTIONS>\ncompTarget=")
        add_name(p.target)
        if p.options != 0 {
            buf.add_byte(text, '\n')
            add_name(p.options)
            add("outputDir=.\n</OPTIONS>\n\n<ASMSYMBOLS>\n</ASMSYMBOLS>\n")
        }
        else {
            ; no target file: the 68000 machines get what upstream's targets have built in
            if strings.compare(p.target, "qemu68k") == 0
                add("\noutput=ELF\nlauncher=NONE\nzeropage=DONTUSE\nzpAllowed=0,255\nloadAddress=$00010000\nmemtop=$00100000")
            else if strings.compare(p.target, "atarist") == 0
                add("\noutput=TOS\nlauncher=NONE\nzeropage=DONTUSE\nzpAllowed=0,255\nloadAddress=0\nmemtop=$fffffffe")
            else if strings.compare(p.target, "amiga500") == 0 or strings.compare(p.target, "amiga1200") == 0
                add("\noutput=AMIGAHUNK\nlauncher=NONE\nzeropage=DONTUSE\nzpAllowed=0,255\nloadAddress=0\nmemtop=$fffffffe")
            else
                add("\noutput=PRG\nlauncher=NONE\nzeropage=DONTUSE\nzpAllowed=0,255\nloadAddress=0\nmemtop=$ffff")
            add("\noptimize=false\nromable=false\nnoSysInit=false\noutputDir=.\n</OPTIONS>\n\n<ASMSYMBOLS>\n</ASMSYMBOLS>\n")
        }
        write_vars(p)
        add("<INITGLOBALS>\n")
        write_chunk(p.initglobals)
        add("</INITGLOBALS>\n\n")
        ^^Block bl = p.blocks
        while bl != 0 {
            write_block(bl)
            bl = bl.next
        }
        add("</PROGRAM>\n")
    }

    sub stats() {
        out.puts("ir: ")
        out.putl(instr_count)
        out.puts(" instructions, ")
        out.putl(chunk_count)
        out.puts(" chunks, ")
        out.putl(regcount)
        out.puts(" registers, ")
        out.putl(sizeof(Instr))
        out.puts(" bytes per instruction")
        out.nl()
    }
}
