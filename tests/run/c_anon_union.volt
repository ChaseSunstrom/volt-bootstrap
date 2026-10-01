use std::io;
// an anonymous union member: its fields are the struct's, sharing memory (the LLVM backend places
// them where libclang says C does)
use { "c_union.h" } as c;

fn main() -> void {
    var e: c::event = { type: 1, key: 65 };
    std::println("{} {}", e.type, e.key);
    e.x = 1.0;
    std::println("{}", e.key);
}

// expect: 1 65
// expect: 1065353216
