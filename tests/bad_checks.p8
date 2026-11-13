; Programs the checker must reject: each marked line has one error that
; upstream's AstChecker also reports (the messages follow upstream's).

%import textio
%encoding iso
%encoding iso                   ; directive can just occur once

main {
    %option enable_floats       ; using an option that is not valid for blocks
    const ubyte bad = txt.width()   ; const declaration needs a compile-time constant initializer value
    str s                       ; string var must be initialized with a string literal
    ubyte[] nosize              ; array variable is missing a size specification
    ubyte[70000] big            ; string and byte array length must be 1-65535
    ubyte[3] three = [1,2]      ; array size mismatch (expecting 3, got 2)
    &ubyte mapped = cells       ; value of memory mapped variable can only be a constant number
    ubyte[10] cells
    ubyte _under

    sub start() {
        ubyte x
        when x {
            1 -> x++
            1 -> x--            ; choice value already occurs elsewhere
            else -> x = 0
        }
        s = "abc"               ; cannot assign to string by value
        bad = 5                 ; cannot assign new value to a constant
        x = cells[10]           ; index out of bounds
        x = x / 0               ; division by zero
        x = -x                  ; can only take negative of a signed number type
        _under = 1              ; identifiers cannot start with an underscore
        void = x                ; cannot assign to 'void'
        goto twice              ; can't jump to a subroutine that takes parameters
    }

    sub twice(ubyte a) -> ubyte {
        a++                     ; no return statement at all
    }

    sub noreturn() -> ubyte {
        ubyte q = 0
        if q == 0
            return 1
        q++                     ; doesn't end with a return statement
    }
}

directives {
    %bogus 1                    ; invalid directive %bogus
}

morechecks {
    ubyte plain
    str text = "x"

    sub two() -> ubyte, ubyte {
        return 1, 2
    }

    sub abs(ubyte x) -> ubyte {     ; builtin function cannot be redefined
        return x
    }

    sub deferring() {
        defer {
            return                  ; defer cannot contain jumps or returns
        }
    }

    sub calls() {
        ubyte a
        ubyte b
        ubyte c
        a = two()                   ; call returns too many values: expected 1 got 2
        a, b, c = two()             ; call returns too few values: expected 3 got 2
        plain(1)                    ; cannot call that: plain
        a = plain[2]                ; indexing requires an iterable, address uword, or pointer variable
        if text == 3                ; left and right operands aren't the same type: str vs ubyte
            a++
        %asm {{
            nop
        }}                          ; %asm with native assembly code can't be used on the llvm targets, use %ir instead
    }
}

declarations $2000 {                ; specific block addresses are not available on the hosted llvm64 target
    struct Point {
        ubyte x
    }

    &Point mapped = $4000           ; struct instances cannot be declared as memory-mapped currently, ...
    &^^ubyte[4] pointers = $5000    ; pointer arrays cannot be memory-mapped (codegen limitation)
    ubyte[4] @alignword @zp aligned ; zeropage variables can't have alignment

    sub registers(ubyte value @A) { ; can only use R0-R15 as register param for normal subroutines
        value++
    }

    sub nested() {
        repeat 2 {
            sub inner() {           ; subroutines can only be defined in the scope of a block or within another subroutine
            }
        }
        %asminclude "file.asm"      ; %asminclude with native code can't be used on the llvm targets, use %ir instead
        goto $123456789abcdef0      ; (fine on llvm64: the address fits)
    }
}

values {
    struct Pair {
        ubyte first
        ubyte second
    }

    sub builtins() {
        ubyte a = abs(1, 2)         ; invalid number of arguments: expected 1 but got 2
        uword w = mkword(1)         ; invalid number of arguments: expected 2 but got 1
        w = sqrt("x")               ; expected numeric argument
        a = peek(true)              ; invalid address type for memory access
    }

    sub aggregates() {
        ^^Pair p = [1, 2, 3]        ; invalid number of arguments: expected 2 or 0 but got 3
        ubyte[3] three
        ubyte[4] four
        three = four                ; array size mismatch (expecting 3, got 4)
        three = [1, 2, 3, 4]        ; array size mismatch (expecting 3, got 4)
        str first = "x"
        str second = first + "y"    ; string var must be initialized with a string literal
        ubyte v = 3
        ubyte[] made = [1, v, 3]    ; (no error: v is never written, so it counts as a constant; tests/programs/neverwritten.p8)
    }
}

operators {
    sub updates() {
        bool flag = true
        flag += 1                   ; left and right operands aren't the same type: bool vs ubyte
        ^^uword p = 2000
        p *= 2                      ; pointer arithmetic only supported for + and - operators, maybe cast to uword?
        ubyte[3] a
        ubyte[3] b
        if a == b                   ; invalid left operand type
            flag = false
    }
}
