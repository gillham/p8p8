; Floating point text conversion for llvm64, through the floats library.

%import floats
%import strings

float_platform {
    %option ignore_unused

    ; The value of a float literal's text.
    sub parse(^^ubyte text) -> float {
        return floats.parse(text)
    }

    ; The value of a floats library function applied to constants, in result;
    ; false when the function is not one the compiler evaluates.
    float result
    sub evaluate(^^ubyte name, float a, float b, float c) -> bool {
        if strings.compare(name, "sin") == 0
            result = floats.sin(a)
        else if strings.compare(name, "cos") == 0
            result = floats.cos(a)
        else if strings.compare(name, "tan") == 0
            result = floats.tan(a)
        else if strings.compare(name, "atan") == 0
            result = floats.atan(a)
        else if strings.compare(name, "pow") == 0
            result = floats.pow(a, b)
        else if strings.compare(name, "ln") == 0
            result = floats.ln(a)
        else if strings.compare(name, "log2") == 0
            result = floats.log2(a)
        else if strings.compare(name, "rad") == 0
            result = floats.rad(a)
        else if strings.compare(name, "deg") == 0
            result = floats.deg(a)
        else if strings.compare(name, "round") == 0
            result = floats.round(a)
        else if strings.compare(name, "floor") == 0
            result = floats.floor(a)
        else if strings.compare(name, "ceil") == 0
            result = floats.ceil(a)
        else if strings.compare(name, "sqrt") == 0
            result = sqrt(a)
        else if strings.compare(name, "abs") == 0
            result = abs(a)
        else if strings.compare(name, "minf") == 0 or strings.compare(name, "min") == 0
            result = floats.minf(a, b)
        else if strings.compare(name, "maxf") == 0 or strings.compare(name, "max") == 0
            result = floats.maxf(a, b)
        else if strings.compare(name, "clampf") == 0 or strings.compare(name, "clamp") == 0
            result = floats.clampf(a, b, c)
        else
            return false
        return true
    }

    ; The shortest text that reads back as the same value (a static buffer).
    sub format(float value) -> ^^ubyte {
        return floats.tostr(value)
    }
}
