; Things upstream's parser refuses, with its messages.
main {
    private public ubyte both = 1               ; error
    ubyte[5,20] matrix                          ; error: [5][20]
    struct Node {
        ubyte[] data                            ; error: how many?
        ubyte[4][2] grid                        ; error: one dimension in a struct
    }
    sub start() {
    }
}
