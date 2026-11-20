; %overlay: where it may stand and what it takes.
%overlay 1                      ; error: a list needs names
%overlay 2, one, 3              ; error: a name

main {
    sub start() {
        one.nothing()
    }
}

one {
    %overlay 0                  ; error: 1 to 255
    sub nothing() {
        %overlay 300            ; error: 1 to 255
    }
}

two {
    %overlay first              ; error: a number
}
