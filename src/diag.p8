; Diagnostics: errors and warnings with a source position, on stderr.

%import out
%import source

diag {
    %option ignore_unused

    uword errors = 0
    uword warnings = 0

    sub error_at(^^source.File f, uword line, uword col, str message) {
        report(f, line, col, "error", message)
        errors++
    }

    sub warning_at(^^source.File f, uword line, uword col, str message) {
        report(f, line, col, "warning", message)
        warnings++
    }

    sub report(^^source.File f, uword line, uword col, str severity, str message) {
        out.err()
        if f != 0 {
            out.puts(f.name)
            out.putc(':')
            out.putl(line)
            out.putc(':')
            out.putl(col)
            out.puts(": ")
        }
        out.puts(severity)
        out.puts(": ")
        out.puts(message)
        out.nl()
        out.std()
    }
}
