; A block at an address on a machine whose target file has fixed_blocks_apart (the
; GameTank): the block is placed there out of line, and what comes after it in the
; program (the variables with values, the strings) goes on where the program was.
%import textio

main {
    ubyte[4] numbers = [11, 22, 33, 44]

    sub start() {
        txt.print("fixed")
        txt.print_ub(numbers[1])
        txt.print_uw(&fixed.bytes)
        repeat {
        }
    }
}

fixed $fdfe {
    %option force_output
    bytes:
    %asm {{
        .text "P8FIXEDBLOCK"
        .fill 496, $5a
    }}
}
