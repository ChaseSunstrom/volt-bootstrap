// greet: a small Volt library that every client in examples/interop/calls-volt calls. bolt builds
// it as a shared library and writes its bindings for each language (bolt.toml's [lib])
use std::string;

// numbers in and out
export fn add(a: i64, b: i64) -> i64 {
    return a + b;
}

// text in, owned text out (the caller's language frees it)
export fn hello(name: str) -> std::string {
    var s = std::string::from("hello, ");
    s.append(name);
    return move s;
}

// a class: other languages hold a tally by a handle, call its methods, and free it
export struct tally {
    name: std::string;
    count: i64;
}

export fn tally_new(name: str) -> tally {
    return { name: std::string::from(name), count: 0 };
}

export fn tally_add(t: tally&, by: i64) -> i64 {
    t.count += by;
    return t.count;
}

export fn tally_name(t: tally&) -> str {
    return t.name.as_str();
}
