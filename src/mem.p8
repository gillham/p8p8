; Memory allocation for the compiler: a bump allocator over chunks from the platform.
; Nothing is ever freed: a compiler is a batch process, and the chunks are zero
; filled once, so every allocation comes back zeroed with no per-allocation
; bookkeeping.  Allocations are rounded up to 8 bytes so pointers, quads and
; floats inside structs stay aligned.
;
; mem.grow() extends the most recent allocation in place when it still fits
; in the chunk, which makes an append-only buffer that grows while nothing
; else is allocated cost nothing in copies.

%import mem_platform

mem {
    %option ignore_unused

    const long CHUNK_SIZE = 65536       ; raw memory is requested in blocks this big
    const long ALIGN = 8

    pointer chunk_next = 0              ; next free byte in the current chunk
    long chunk_left = 0                 ; bytes left in the current chunk
    pointer last_alloc = 0              ; most recent allocation, for grow()
    long last_size = 0                  ; its rounded size

    ; statistics
    long total_requested = 0            ; bytes asked for
    long total_allocated = 0            ; bytes handed out, after rounding
    long total_chunks = 0               ; bytes obtained from the platform
    long count_allocs = 0
    long count_chunks = 0
    long count_grow_inplace = 0
    long count_grow_copy = 0

    sub round_up(long size) -> long {
        return (size + ALIGN - 1) & ~(ALIGN - 1)
    }

    ; Returns size bytes of zeroed memory.  Stops the program when the platform has none.
    sub alloc(long size) -> pointer {
        if size <= 0
            size = 1
        long rounded = round_up(size)
        if rounded > chunk_left
            new_chunk(rounded)
        pointer result = chunk_next
        chunk_next += rounded
        chunk_left -= rounded
        last_alloc = result
        last_size = rounded
        total_requested += size
        total_allocated += rounded
        count_allocs++
        return result
    }

    sub new_chunk(long atleast) {
        long size = CHUNK_SIZE
        if atleast > size
            size = atleast
        pointer chunk = mem_platform.chunk(size)
        if chunk == 0
            sys.die(2, "out of memory")
        chunk_next = chunk
        chunk_left = size
        total_chunks += size
        count_chunks++
    }

    ; Returns memory of newsize bytes holding the first oldsize bytes of old.
    ; The old block must not be used afterwards.
    sub grow(pointer old, long oldsize, long newsize) -> pointer {
        if old == last_alloc and old != 0 {
            long rounded = round_up(newsize)
            long extra = rounded - last_size
            if extra <= chunk_left {
                chunk_next += extra
                chunk_left -= extra
                total_allocated += extra
                total_requested += newsize - oldsize
                last_size = rounded
                count_grow_inplace++
                return old
            }
        }
        pointer result = alloc(newsize)
        if oldsize > 0
            mem_platform.copy(old, result, oldsize)
        count_grow_copy++
        return result
    }

    ; Copies count bytes between non-overlapping areas of any size.
    sub copy(pointer src, pointer dst, long count) {
        mem_platform.copy(src, dst, count)
    }

    ; Prints the allocation statistics on the current output stream.
    sub stats() {
        out.puts("memory: ")
        out.putl(count_allocs)
        out.puts(" allocations, ")
        out.putl(total_requested)
        out.puts(" bytes requested, ")
        out.putl(total_allocated)
        out.puts(" allocated, ")
        out.putl(total_chunks)
        out.puts(" in ")
        out.putl(count_chunks)
        out.puts(" chunks; grow in place ")
        out.putl(count_grow_inplace)
        out.puts(", by copy ")
        out.putl(count_grow_copy)
        out.nl()
    }
}
