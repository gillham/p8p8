; I/O platform layer for llvm64: files and the standard streams through the C library.

%import fileio

io_platform {
    %option ignore_unused

    extsub write(long fd, pointer data, uquad count) -> quad
    extsub system(str command) -> long
    extsub popen(str command, str mode) -> pointer
    extsub pclose(pointer stream) -> long
    extsub fgets(pointer buffer, long size, pointer stream) -> pointer
    extsub getenv(str name) -> pointer
    extsub realpath(str path, pointer resolved) -> pointer
    extsub rename(str oldname, str newname) -> long
    extsub remove(str path) -> long

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

    ; The LLVM triple profile of the machine this runs on, from "uname -sm", or 0 when
    ; it is none of the four that are known.
    sub host_triple() -> ^^ubyte {
        ; (Windows sets OS; it has no uname to ask)
        ^^ubyte os = getenv("OS")
        if os != 0 and os[0] == 'W' and os[1] == 'i' and os[2] == 'n'
            return "x86_64-pc-windows-msvc"
        pointer stream = popen("uname -sm", "r")
        if stream == 0
            return 0
        host_text[0] = 0
        void fgets(&host_text, 64, stream)
        void pclose(stream)
        bool linux = host_text[0] == 'L'
        bool intel = false
        ubyte i = 0
        while host_text[i] != 0 {
            if host_text[i] == 'x' and host_text[i + 1] == '8' and host_text[i + 2] == '6'
                intel = true
            i++
        }
        if host_text[0] == 'D' {
            if intel
                return "x86_64-apple-macosx"
            return "arm64-apple-macosx"
        }
        if linux {
            if intel
                return "x86_64-unknown-linux-gnu"
            return "aarch64-unknown-linux-gnu"
        }
        return 0
    }

    ; Runs a shell command and waits for it.  Gives its exit status (0 for success),
    ; or 255 when it could not be run or was stopped by a signal.
    sub run_command(str command) -> ubyte {
        long status = system(command)
        if status < 0 or (status & 127) != 0
            return 255
        return ((status >> 8) & 255) as ubyte
    }

    const ubyte STDOUT = 1
    const ubyte STDERR = 2

    ; Writes count bytes to a standard stream.
    sub write_fd(ubyte fd, pointer data, long count) {
        void write(fd, data, count as uquad)
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
