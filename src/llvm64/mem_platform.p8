; Memory platform layer for llvm64: raw memory comes from the C library.
; Only mem.p8 calls this; everything else allocates through mem.alloc().

mem_platform {
    %option ignore_unused

    extsub calloc(uquad count, uquad size) -> pointer
    extsub memcpy(pointer dst, pointer src, uquad count) -> pointer

    ; A zero-filled block of raw memory, or 0 when the host has none left.
    sub chunk(long size) -> pointer {
        return calloc(1, size as uquad)
    }

    ; Copies count bytes; the areas must not overlap.
    sub copy(pointer src, pointer dst, long count) {
        void memcpy(dst, src, count as uquad)
    }
}
