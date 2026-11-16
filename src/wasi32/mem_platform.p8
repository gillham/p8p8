; Memory platform layer for a 32-bit host (llvm32): raw memory comes from the
; C library, whose sizes are 32 bits wide here.
; Only mem.p8 calls this; everything else allocates through mem.alloc().

mem_platform {
    %option ignore_unused

    extsub calloc(long count, long size) -> pointer
    extsub memcpy(pointer dst, pointer src, long count) -> pointer

    ; A zero-filled block of raw memory, or 0 when the host has none left.
    sub chunk(long size) -> pointer {
        return calloc(1, size)
    }

    ; Copies count bytes; the areas must not overlap.
    sub copy(pointer src, pointer dst, long count) {
        void memcpy(dst, src, count)
    }
}
