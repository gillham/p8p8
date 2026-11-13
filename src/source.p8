; Source files: each one is loaded whole into memory and kept for the rest
; of the compilation, so tokens and AST nodes can point into its text.

%import mem
%import io_platform

source {
    %option ignore_unused

    struct File {
        ^^ubyte text        ; the whole file, zero terminated
        ^^ubyte name        ; path as given
        long len
        uword index         ; position in the files table
        uword lines         ; counted while lexing; 0 until then
    }

    ^^pointer files = 0         ; ^^File by index
    uword count = 0
    uword cap = 0
    long total_bytes = 0

    ; Loads the file, or returns 0 when it can't be read.
    sub load(str path) -> ^^File {
        long size = io_platform.file_size(path)
        if size < 0
            return 0
        ^^File f = mem.alloc(sizeof(File))
        ^^ubyte text = mem.alloc(size + 1)
        long got = io_platform.read_file(path, text, size)
        if got < 0
            return 0
        text[got] = 0           ; through a local pointer: see the note in buf.p8
        f.text = text
        f.len = got
        f.name = path
        if count >= cap {
            uword newcap = cap * 2
            if newcap < 64
                newcap = 64
            files = mem.grow(files, cap * sizeof(pointer), newcap * sizeof(pointer))
            cap = newcap
        }
        f.index = count
        files[count] = f
        count++
        total_bytes += got
        return f
    }

    sub get(uword index) -> ^^File {
        return files[index]
    }

    sub stats() {
        out.puts("sources: ")
        out.putl(count)
        out.puts(" files, ")
        out.putl(total_bytes)
        out.puts(" bytes")
        out.nl()
    }
}
