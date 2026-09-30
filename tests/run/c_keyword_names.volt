use std::io;

// field and capture names that are C keywords still work (they're renamed in the C output)
struct flags {
    unsigned: bool;
    long: i32 = 7;
    inline: str = "in";
    register: i32[2] = { 1, 2 };
}

enum kw {
    int: i32,
    char,
}

fn main() -> void {
    var f: flags = { unsigned: true };
    f.long += 1;
    std::println(f);
    val double = 2;
    val scale = |double| () -> i32 { return double * 10; };
    std::println(scale());
    val k = kw::int(3);
    match (k) {
        .int(x) => { std::println("int {}", x); },
        .char => {},
    }
}
// expect: flags { unsigned: true, long: 8, inline: in, register: { 1, 2 } }
// expect: 20
// expect: int 3
