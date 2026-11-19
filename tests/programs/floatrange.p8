; a range of whole numbers written as floats fills an array of floats
%import floats
%import textio
main {
  sub start() {
    float[] @shared f = 1.0 to 3.0
    float[] @shared g = 1 to 4
    floats.print(f[2])
    floats.print(g[3])
    txt.print_uw(len(f))
  }
}
