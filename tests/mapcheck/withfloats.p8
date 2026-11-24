; For tests/mapcheck.sh: a program with floats (on the Z80 machines it is linked
; with z88dk's library, whose routines are in the map too).

%import textio
%import floats

main {
    float[10] values
    ubyte @shared small = 3

    sub start() {
        values[2] = 3.5 * small
        txt.print_f(values[2])
        txt.nl()
    }
}
