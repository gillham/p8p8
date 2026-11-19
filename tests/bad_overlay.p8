; %overlay: where it may stand and what it takes.
%overlay 1                      ; error: in a block only

main {
    sub start() {
        %overlay 1              ; error: in a block only
        one.nothing()
    }
}

one {
    %overlay 0                  ; error: 1 to 255
    sub nothing() {
    }
}

two {
    %overlay first              ; error: a number
}
