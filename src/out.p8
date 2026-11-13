; Buffered text output on the standard output and error streams.
; Routines write to the selected stream; stdout is flushed when its buffer
; fills and at exit, stderr at every line end.

%import buf
%import io_platform

out {
    %option ignore_unused

    const long FLUSH_AT = 8192

    ^^buf.Buf stdout_buf = 0
    ^^buf.Buf stderr_buf = 0
    ^^buf.Buf current = 0
    bool on_stderr = false

    sub init() {
        stdout_buf = buf.new(FLUSH_AT)
        stderr_buf = buf.new(256)
        current = stdout_buf
    }

    ; Selects stderr for the following output.
    sub err() {
        current = stderr_buf
        on_stderr = true
    }

    ; Selects stdout for the following output.
    sub std() {
        current = stdout_buf
        on_stderr = false
    }

    sub puts(^^ubyte text) {
        buf.add_str(current, text)
        check_flush()
    }

    sub put_bytes(pointer data, long count) {
        buf.add_bytes(current, data, count)
        check_flush()
    }

    sub putc(ubyte value) {
        buf.add_byte(current, value)
    }

    sub putl(long value) {
        buf.add_long(current, value)
    }

    sub putq(quad value) {
        buf.add_quad(current, value)
    }

    sub putuq(uquad value) {
        buf.add_uquad(current, value)
    }

    sub nl() {
        buf.add_byte(current, '\n')
        if on_stderr
            flush()
        else
            check_flush()
    }

    sub check_flush() {
        if current.len >= FLUSH_AT
            flush()
    }

    ; Writes out whatever both streams hold.
    sub flush() {
        if stdout_buf.len > 0 {
            io_platform.write_fd(io_platform.STDOUT, stdout_buf.data, stdout_buf.len)
            buf.clear(stdout_buf)
        }
        if stderr_buf.len > 0 {
            io_platform.write_fd(io_platform.STDERR, stderr_buf.data, stderr_buf.len)
            buf.clear(stderr_buf)
        }
    }

    ; Flushes and ends the program with the status.
    sub exit(ubyte status) {
        flush()
        sys.exit(status)
    }
}
