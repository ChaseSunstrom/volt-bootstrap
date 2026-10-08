// plainlib: the plain shapes beyond mathlib's that Node and Ruby take (tests/interop.rs,
// bindings_plain_shapes): structs with text, arrays, structs and pointers in them, E!T as a
// parameter, a callback giving a struct

public struct vec2 {
    x: f64;
    y: f64;
}

public error plain_error {
    NEGATIVE,
}

// a struct with text, an array and a struct in it: other languages pass and get it as any struct
// (the text lent for the call)
public struct label {
    name: str;
    sizes: i32[3];
    at: vec2;
}

// a struct with a pointer in it
public struct holder {
    p: i64*;
    k: i32;
}

export fn pl_label_len(l: label) -> i64 {
    return @cast<i64>(l.name.len) + @cast<i64>(l.sizes[0] + l.sizes[1] + l.sizes[2]) + @cast<i64>(l.at.x);
}

// a label naming what it was given (its text is the parameter's: read it before the call is back)
export fn pl_label_of(name: str, k: i32) -> label {
    return { name: name, sizes: { k, k * 2, k * 3 }, at: { x: 1.5, y: 2.5 } };
}

export fn pl_labels_len(ls: label[..]) -> i64 {
    var t: i64 = 0;
    for (l) in ls {
        t += pl_label_len(l);
    }
    return t;
}

export fn pl_holder_k(h: holder) -> i32 {
    return h.k;
}

// E!T as a parameter: its value, or d when it's an error
export fn pl_or(got: plain_error!f64, d: f64) -> f64 {
    return got catch d;
}

// a callback giving a struct with text
export fn pl_ask(f: fn(i32) -> label) -> i64 {
    return pl_label_len(f(4));
}
