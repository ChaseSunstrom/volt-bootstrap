use std::io;
// a function pointer type that takes one, named first inside a cast (both C backends once defined
// the outer typedef before the inner one)

extern "C" fn twice(x: i32) -> i32 {
    return x * 2;
}

fn nothing() -> void* {
    return null;
}

fn main() -> void {
    val a = @cast<extern "C" fn(extern "C" fn(i32) -> i32, i32) -> i32>(nothing());
    if (@cast<void*>(a) != null) {
        std::println("apply {}", a(twice, 20));
    }
    std::println("null {}", @cast<void*>(a) == null);
}
// expect: null true
