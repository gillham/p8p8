; The type table.  Every type is one Type struct with a small id; the basic
; types have fixed ids equal to their base kind, and composite types (typed
; pointers, arrays, struct instances) are made once each, so two equal types
; always have the same id and compare as integers.  Nodes and symbols carry
; a type id in a uword.

%import mem
%import out
%import buf
%import token
%import symtab
%import strings

types {
    %option ignore_unused

    ; base kinds; the basic ones double as their type id
    const ubyte T_UNDEF = 0
    const ubyte T_BOOL = 1
    const ubyte T_UBYTE = 2
    const ubyte T_BYTE = 3
    const ubyte T_UWORD = 4
    const ubyte T_WORD = 5
    const ubyte T_LONG = 6
    const ubyte T_QUAD = 7
    const ubyte T_UQUAD = 8
    const ubyte T_FLOAT = 9
    const ubyte T_STR = 10
    const ubyte T_VOID = 11         ; no value (a subroutine without return value, a block)
    const ubyte T_BASIC_COUNT = 12
    const ubyte T_POINTER = 12      ; typed pointer: elem is the pointee
    const ubyte T_ARRAY = 13        ; elem is the element type, length the element count (0 = unknown)
    const ubyte T_STRUCT = 14       ; a struct instance; strct is the struct symbol

    str[] base_names = ["?", "bool", "ubyte", "byte", "uword", "word", "long", "quad", "uquad", "float", "str", "void", "pointer", "array", "struct"]

    struct Type {
        ^^Type next             ; hash chain
        pointer strct           ; the struct symbol (symtab.Sym) for T_STRUCT
        long length             ; array length
        uword elem              ; element or pointee type id
        uword id
        ubyte base
    }

    ; target properties, set by set_target()
    ubyte POINTER_SIZE = 8
    ; A machine whose CPU reaches more memory than a pointer of the language names (the
    ; 65816 with 24 bits, the MEGA65's 45GS02 with 28): how many bits an address in data
    ; can have, or 0.  A long is such an address; pointers stay words.  (The driver sets
    ; it from the target's far_address_bits when the CPU is one of the two.)
    ubyte far_bits = 0
    ubyte FLOAT_SIZE = 8
    ubyte ADDRESS_TYPE = T_UQUAD    ; what the 'pointer' keyword and & give

    ; Sets the pointer size, float size and address type for a target name.
    sub set_target(^^ubyte name) {
        ensure()
        if strings.compare(name, "llvm64") == 0 {
            POINTER_SIZE = 8
            FLOAT_SIZE = 8
            ADDRESS_TYPE = T_UQUAD
        }
        else if strings.compare(name, "llvm32") == 0 or strings.compare(name, "virtual") == 0 {
            POINTER_SIZE = 4
            FLOAT_SIZE = 8
            ADDRESS_TYPE = T_LONG
        }
        else if strings.compare(name, "amiga500") == 0 or strings.compare(name, "amiga1200") == 0 or strings.compare(name, "qemu68k") == 0
            or strings.compare(name, "atarist") == 0 or strings.compare(name, "macplus") == 0 {
            ; the 68000 machines: a float in memory is a 32 bit IEEE one, as upstream has it
            POINTER_SIZE = 4
            FLOAT_SIZE = 4
            ADDRESS_TYPE = T_LONG
        }
        else {
            ; the 6502 family and llvm16
            POINTER_SIZE = 2
            FLOAT_SIZE = 5
            if strings.compare(name, "llvm16") == 0
                FLOAT_SIZE = 4      ; a 32 bit IEEE float
            ADDRESS_TYPE = T_UWORD
        }
    }

    ^^pointer table = 0             ; ^^Type by id
    uword count = 0
    uword cap = 0
    const uword NBUCKETS = 256
    ^^pointer buckets = 0

    sub init() {
        cap = 64
        table = mem.alloc(cap * sizeof(pointer))
        buckets = mem.alloc(NBUCKETS * sizeof(pointer))
        count = 0
        ubyte b = 0
        while b < T_BASIC_COUNT {
            void add(b, 0, 0, 0)
            b++
        }
    }

    sub add(ubyte base, uword elem, pointer strct, long length) -> ^^Type {
        if count >= cap {
            uword newcap = cap * 2
            table = mem.grow(table, cap * sizeof(pointer), newcap * sizeof(pointer))
            cap = newcap
        }
        ^^Type t = mem.alloc(sizeof(Type))
        t.base = base
        t.elem = elem
        t.strct = strct
        t.length = length
        t.id = count
        table[count] = t
        count++
        return t
    }

    ; the basic types exist before anything looks a type up
    sub ensure() {
        if table == 0
            init()
    }

    sub get(uword id) -> ^^Type {
        return table[id]
    }

    sub base_of(uword id) -> ubyte {
        ^^Type t = table[id]
        return t.base
    }

    sub elem_of(uword id) -> uword {
        ^^Type t = table[id]
        return t.elem
    }

    ; The one type with these properties, made when it doesn't exist yet.
    sub make(ubyte base, uword elem, pointer strct, long length) -> uword {
        if table == 0
            init()
        if base < T_BASIC_COUNT
            return base
        uword h = ((base as uword) * 31 + elem * 7 + lsw(strct as long) + lsw(length)) & (NBUCKETS - 1)
        ^^Type t = buckets[h]
        while t != 0 {
            if t.base == base and t.elem == elem and t.strct == strct and t.length == length
                return t.id
            t = t.next
        }
        t = add(base, elem, strct, length)
        t.next = buckets[h]
        buckets[h] = t
        return t.id
    }

    sub pointer_to(uword elem) -> uword {
        return make(T_POINTER, elem, 0, 0)
    }

    sub array_of(uword elem, long length) -> uword {
        return make(T_ARRAY, elem, 0, length)
    }

    sub struct_of(pointer strct) -> uword {
        return make(T_STRUCT, 0, strct, 0)
    }

    ; the type for a base type keyword token kind
    sub from_keyword(ubyte kw) -> uword {
        when kw {
            token.T_KW_UBYTE -> return T_UBYTE
            token.T_KW_BYTE -> return T_BYTE
            token.T_KW_UWORD -> return T_UWORD
            token.T_KW_WORD -> return T_WORD
            token.T_KW_LONG -> return T_LONG
            token.T_KW_QUAD -> return T_QUAD
            token.T_KW_UQUAD -> return T_UQUAD
            token.T_KW_FLOAT -> return T_FLOAT
            token.T_KW_STR -> return T_STR
            token.T_KW_BOOL -> return T_BOOL
            token.T_KW_POINTER -> return ADDRESS_TYPE
            else -> return T_UNDEF
        }
    }

    ; ---- predicates on type ids ----

    sub is_byte(uword id) -> bool {
        return id == T_UBYTE or id == T_BYTE
    }

    sub is_byte_or_bool(uword id) -> bool {
        return id == T_UBYTE or id == T_BYTE or id == T_BOOL
    }

    sub is_word(uword id) -> bool {
        return id == T_UWORD or id == T_WORD
    }

    sub is_quad(uword id) -> bool {
        return id == T_QUAD or id == T_UQUAD
    }

    sub is_integer(uword id) -> bool {
        return id >= T_UBYTE and id <= T_UQUAD
    }

    sub is_numeric(uword id) -> bool {
        return id >= T_UBYTE and id <= T_FLOAT
    }

    sub is_numeric_or_bool(uword id) -> bool {
        return id >= T_BOOL and id <= T_FLOAT
    }

    sub is_signed(uword id) -> bool {
        return id == T_BYTE or id == T_WORD or id == T_LONG or id == T_QUAD or id == T_FLOAT
    }

    sub is_pointer(uword id) -> bool {
        return base_of(id) == T_POINTER
    }

    sub is_array(uword id) -> bool {
        return base_of(id) == T_ARRAY
    }

    sub is_struct(uword id) -> bool {
        return base_of(id) == T_STRUCT
    }

    ; anything that holds an address: the address type, or a typed pointer
    sub is_address(uword id) -> bool {
        return id == ADDRESS_TYPE or is_pointer(id)
    }

    sub is_iterable(uword id) -> bool {
        return id == T_STR or is_array(id)
    }

    ; the element type when indexing a value of this type, or 0
    sub index_elem(uword id) -> uword {
        ubyte b = base_of(id)
        if b == T_ARRAY or b == T_POINTER
            return elem_of(id)
        if id == T_STR or id == T_UWORD or id == ADDRESS_TYPE
            return T_UBYTE
        if id == T_LONG and far_bits != 0
            return T_UBYTE          ; (a long is an address on a machine with far memory)
        return 0
    }

    ; Storage size in bytes of a value of this type (arrays: all elements).
    sub size_of(uword id) -> long {
        ^^Type t = table[id]
        when t.base {
            T_BOOL, T_UBYTE, T_BYTE -> return 1
            T_UWORD, T_WORD -> return 2
            T_LONG -> return 4
            T_QUAD, T_UQUAD -> return 8
            T_FLOAT -> return FLOAT_SIZE
            T_POINTER, T_STR -> return POINTER_SIZE      ; a str as a value or element is an address
            T_ARRAY -> return size_of(t.elem) * t.length
            T_STRUCT -> return struct_size(t.strct)
            else -> return 0
        }
    }

    ; Fields are packed in declaration order, so the size is the sum of the field sizes.
    sub struct_size(pointer strct) -> long {
        ^^symtab.Sym st = strct
        if st.inner == 0
            return 0
        long total = 0
        ^^symtab.Sym f = st.inner.syms
        while f != 0 {
            if f.type != 0
                total += size_of(f.type)
            f = f.next
        }
        if st.decl.kind == ast.N_UNION {
            ; a union is as big as its largest field
            total = 0
            f = st.inner.syms
            while f != 0 {
                if f.type != 0 and size_of(f.type) > total
                    total = size_of(f.type)
                f = f.next
            }
        }
        return total
    }

    ; ---- the language's rules ----

    ; The smallest integer type that holds the value (upstream's optimalInteger).
    sub literal_type(quad value) -> uword {
        if value >= 0 and value <= 255
            return T_UBYTE
        if value >= -128 and value <= 127
            return T_BYTE
        if value >= 0 and value <= 65535
            return T_UWORD
        if value >= -32768 and value <= 32767
            return T_WORD
        if value >= -2147483648 and value <= 2147483647
            return T_LONG
        return T_QUAD
    }

    ; True when a value of type from may be assigned to a variable of type to without a cast.
    sub assignable(uword src, uword dst) -> bool {
        if src == dst
            return true
        if src == T_UNDEF or dst == T_UNDEF
            return false
        ubyte tb = base_of(dst)
        when src {
            T_BOOL -> return dst == T_BOOL
            T_UBYTE -> return dst == T_WORD or dst == T_UWORD or dst == T_LONG or dst == T_QUAD or dst == T_UQUAD or dst == T_FLOAT
            T_BYTE -> return dst == T_WORD or dst == T_LONG or dst == T_QUAD or dst == T_FLOAT
            T_UWORD -> return dst == T_LONG or dst == T_QUAD or dst == T_UQUAD or dst == T_FLOAT or tb == T_POINTER
            T_WORD -> return dst == T_LONG or dst == T_QUAD or dst == T_FLOAT
            T_LONG -> return dst == T_QUAD or dst == T_FLOAT or tb == T_POINTER
            T_QUAD -> return dst == T_FLOAT or tb == T_POINTER
            T_UQUAD -> return dst == T_FLOAT or tb == T_POINTER
            T_FLOAT -> return false
            T_STR -> return dst == T_UWORD or dst == T_LONG or dst == T_UQUAD or (tb == T_POINTER and elem_of(dst) == T_UBYTE)
        }
        ubyte fb = base_of(src)
        if fb == T_ARRAY
            return tb == T_ARRAY and elem_of(src) == elem_of(dst)
        if fb == T_POINTER {
            ; a typed pointer goes into an address variable, or the same pointer type
            return dst == ADDRESS_TYPE or dst == T_UWORD or dst == T_LONG
        }
        return false
    }

    ; The result type of a binary arithmetic operation between two types (upstream's commonDatatype
    ; without the literal special cases, which the typer handles).
    sub common(uword left, uword right) -> uword {
        if left == T_UNDEF or right == T_UNDEF
            return T_UNDEF
        if is_pointer(left)
            return left
        if is_pointer(right)
            return right
        if left == T_FLOAT or right == T_FLOAT
            return T_FLOAT
        if left == T_BOOL
            return T_BOOL
        if left == right
            return left
        if left == T_QUAD or right == T_QUAD
            return T_QUAD
        if left == T_UQUAD or right == T_UQUAD {
            if is_signed(left) or is_signed(right)
                return T_QUAD
            return T_UQUAD
        }
        if left == T_LONG or right == T_LONG
            return T_LONG
        if is_word(left) or is_word(right) {
            if is_signed(left) or is_signed(right)
                return T_WORD
            return T_UWORD
        }
        if is_byte_or_bool(left) and is_byte_or_bool(right) {
            if is_signed(left) or is_signed(right)
                return T_BYTE
            return T_UBYTE
        }
        return left
    }

    ; the unsigned type of the same size, for bitwise results
    sub signed_of(uword id) -> uword {
        when id {
            T_UBYTE -> return T_BYTE
            T_UWORD -> return T_WORD
            T_UQUAD -> return T_QUAD
            else -> return id
        }
    }

    sub unsigned_of(uword id) -> uword {
        when id {
            T_BYTE, T_BOOL -> return T_UBYTE
            T_WORD -> return T_UWORD
            T_QUAD -> return T_UQUAD
            else -> return id
        }
    }

    ; Appends the readable name of a type to a buffer.
    sub name_into(^^buf.Buf b, uword id) {
        ^^Type t = table[id]
        when t.base {
            T_POINTER -> {
                buf.add_str(b, "^^")
                name_into(b, t.elem)
            }
            T_ARRAY -> {
                name_into(b, t.elem)
                buf.add_byte(b, '[')
                if t.length != 0
                    buf.add_long(b, t.length)
                buf.add_byte(b, ']')
            }
            T_STRUCT -> {
                ^^symtab.Sym s = t.strct
                buf.add_str(b, s.name)
            }
            else -> buf.add_str(b, base_names[t.base])
        }
    }

    sub put_name(uword id) {
        buf.clear(parser.scratch)
        name_into(parser.scratch, id)
        out.puts(parser.scratch.data)
    }

    sub stats() {
        out.puts("types: ")
        out.putl(count)
        out.puts(" distinct")
        out.nl()
    }
}
