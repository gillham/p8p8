%import textio
%import math
%option romable
main {
    uword counter = 1000
    ubyte[8] scratch
    ubyte[] table = [1, 2, 3, 4]
    str name = "rom"
    sub start() {
        ubyte k
        for k in 0 to 3 {
            scratch[k] = table[k] * 2
            counter += scratch[k]
        }
        txt.print(name)
        counter += math.rnd_rom()
        txt.print_uw(counter)
        uword w = counter * 19
        word s = w as word
        if s < 0
            w = (w << 1) | (w >> 15)
        txt.print_uw(w)
    }
}
