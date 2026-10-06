// a release build checks a payload is read from a value holding that variant, as one compare and a
// trap instruction (132: SIGILL on x86-64, 133: SIGTRAP on arm64); reading another variant's bytes
// would be the wrong type
use std::io;
enum shape {
    CIRCLE: i32,
    SQUARE: i32,
}
fn pick(arg: str?) -> shape {
    if (arg != null) {
        return shape::CIRCLE(2);
    }
    return shape::SQUARE(3);
}
fn main() -> void {
    val s = pick(std::process::arg(1));
    if (s.SQUARE != 3) {
        std::process::exit(3);
    }
    std::println(s.CIRCLE);
}
// flags: --release
// exit: 132|133
