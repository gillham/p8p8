; I/O platform layer for WebAssembly with WASI (llvm32, wasm32-wasip1): files and
; the standard streams through the C library.  WASI has no processes and no
; signals, so the compiler cannot run an assembler or clang from here: it
; checks programs and writes their assembly, IR or LLVM IR.  The other modules
; of the host layer are those of llvm64 (the source directories are
; src:src/wasi32:src/llvm64).

%import fileio

io_platform {
    %option ignore_unused

    extsub write(long fd, pointer data, long count) -> long
    extsub getenv(str name) -> pointer
    extsub rename(str oldname, str newname) -> long
    extsub remove(str path) -> long

    sub is_windows() -> bool {
        return false
    }

    ; (no signals: a fault ends the program with the runtime's own message)
    sub catch_crashes(pointer handler) {
    }

    ; Gives a file another name, in place of a file of that name if there is one.
    sub move_file(str oldname, str newname) -> bool {
        void remove(newname)
        return rename(oldname, newname) == 0
    }

    ; The value of an environment variable, or 0 when it is not set.
    sub env(str name) -> ^^ubyte {
        return getenv(name)
    }

    ; (the runtime shows the program only the directories it was given)
    sub real_path(str path) -> ^^ubyte {
        return path
    }

    ; There is no machine to ask: programs for the host need -triple.
    sub host_triple() -> ^^ubyte {
        return 0
    }

    ; No command can be run here: 255, "could not be run".
    sub run_command(str command) -> ubyte {
        return 255
    }

    const ubyte STDOUT = 1
    const ubyte STDERR = 2

    ; Writes count bytes to a standard stream.
    sub write_fd(ubyte fd, pointer data, long count) {
        void write(fd, data, count)
    }

    ; Size of a file in bytes, or -1 when it can't be opened.
    sub file_size(str path) -> long {
        pointer fh = fileio.open(path, "rb")
        if fh == 0
            return -1
        void fileio.seek(fh, 0, fileio.SEEK_END)
        long size = fileio.tell(fh) as long
        void fileio.close(fh)
        return size
    }

    ; Writes count bytes to a new file. Returns false when it can't be written.
    sub write_file(str path, pointer data, long count) -> bool {
        pointer fh = fileio.open(path, "wb")
        if fh == 0
            return false
        long done = 0
        while done < count {
            long want = count - done
            if want > 32000
                want = 32000
            uword written = fileio.write(fh, data + done, want as uword)
            if written == 0
                break
            done += written
        }
        void fileio.close(fh)
        return done == count
    }

    ; Reads the whole file into the buffer, which must hold size bytes. Returns the bytes read, or -1.
    sub read_file(str path, pointer buffer, long size) -> long {
        pointer fh = fileio.open(path, "rb")
        if fh == 0
            return -1
        long total = 0
        while total < size {
            long want = size - total
            if want > 32768
                want = 32768
            uword got = fileio.read(fh, buffer + total, want as uword)
            if got == 0
                break
            total += got
        }
        void fileio.close(fh)
        return total
    }
}
