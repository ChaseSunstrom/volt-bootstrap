// a plain fn and a static fn of one name in one scope: the bare name calls the plain fn, T::name
// the static one (a C++ class's static f beside its namespace's free f comes in this way)
use std::io;

struct rgb {
    r: u8;
    g: u8;
    b: u8;
}

attach fn gray(static this: rgb, level: u8) -> rgb {
    return { r: level, g: level, b: level };
}

fn gray(level: u8) -> u8 {
    return level / 2;
}

fn main() -> void {
    val c = rgb::gray(128);
    std::println("{} {} {} {}", c.r, c.g, c.b, gray(128));
}
// expect: 128 128 128 64
