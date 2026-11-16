; I/O platform layer for a 32-bit hosted platform (llvm32 on Linux): files, the
; standard streams, commands and signals through the C library, whose sizes are
; 32 bits wide here.  The rest of the host layer is llvm64's (the source
; directories are src:src/llvm32:src/llvm64).

%import fileio

io_platform {
    %option ignore_unused

    extsub write(long fd, pointer data, long count) -> long
    extsub system(str command) -> long
    extsub popen(str command, str mode) -> pointer
    extsub pclose(pointer stream) -> long
    extsub fgets(pointer buffer, long size, pointer stream) -> pointer
    extsub getenv(str name) -> pointer
    extsub realpath(str path, pointer resolved) -> pointer
    extsub rename(str oldname, str newname) -> long
    extsub remove(str path) -> long
    extsub signal(long number, pointer handler) -> pointer

    sub is_windows() -> bool {
        return false
    }

    ; The handler is called when the program itself goes wrong: a bad address, an
    ; illegal instruction, an arithmetic fault.  (Windows knows fewer signals, and
    ; ends the program when it is asked for one it does not know.)
    sub catch_crashes(pointer handler) {
        void signal(11, handler)
        void signal(4, handler)
        void signal(8, handler)
        if not is_windows() {
            void signal(10, handler)
            void signal(7, handler)
        }
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

    ; A path with its symbolic links followed and made absolute, or the path as it is
    ; when that cannot be done.
    sub real_path(str path) -> ^^ubyte {
        ^^ubyte resolved = mem.alloc(4200)
        if realpath(path, resolved) == 0
            return path
        return resolved
    }

    ubyte[64] host_text

    ; The triple profile of the machine this runs on, from "uname -sm", or 0 when
    ; it is not one of the 32-bit platforms that have one.
    sub host_triple() -> ^^ubyte {
        pointer stream = popen("uname -sm", "r")
        if stream == 0
            return 0
        host_text[0] = 0
        void fgets(&host_text, 64, stream)
        void pclose(stream)
        if host_text[0] != 'L'
            return 0
        ubyte i = 0
        while host_text[i] != 0 {
            ; (armv7l, and armv8l: a 64-bit processor with a 32-bit system)
            if host_text[i] == 'a' and host_text[i + 1] == 'r' and host_text[i + 2] == 'm' and host_text[i + 3] == 'v'
                return "armv7-unknown-linux-gnueabihf"
            if host_text[i] == 'r' and host_text[i + 1] == 'i' and host_text[i + 2] == 's' and host_text[i + 3] == 'c'
                return "riscv32-unknown-linux-gnu"
            i++
        }
        return 0
    }

    ; Runs a shell command and waits for it.  Gives its exit status (0 for success),
    ; or 255 when it could not be run or was stopped by a signal.
    sub run_command(str command) -> ubyte {
        long status = system(command)
        if is_windows() {
            ; (there it is the exit status itself)
            if status < 0 or status > 255
                return 255
            return status as ubyte
        }
        if status < 0 or (status & 127) != 0
            return 255
        return ((status >> 8) & 255) as ubyte
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
