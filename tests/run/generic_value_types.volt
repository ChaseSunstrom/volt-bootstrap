// a generic value parameter used as a value is one of its declared type: <B: bool> a bool,
// <N: usize> a usize, <K: u8> a u8, <M: i8> an i8; a type parameter and a str parameter as before
use std::io;

<B: bool>
fn pick() -> str {
    val b = B;
    if (B && b) {
        return "yes";
    }
    return "no";
}

<N: usize>
fn big() -> usize {
    val x = N;
    return x * 4000000000;
}

<K: u8>
fn byte() -> u8 {
    var k: u8 = K;
    k += 1;
    return k;
}

<M: i8>
fn small() -> i8 {
    return M;
}

<N: usize>
fn whole() -> usize {
    return N;
}

<T: type, S: str>
fn named(x: T) -> T {
    std::println("{}", S);
    return x;
}

fn main() -> void {
    std::println("{} {}", pick<true>(), pick<false>());
    std::println("{}", big<3>());
    std::println("{}", byte<254>());
    std::println("{}", small<-128>());
    std::println("{}", whole<18446744073709551615>());
    std::println("{}", named<i32, "hi">(5));
}
// expect: yes no
// expect: 12000000000
// expect: 255
// expect: -128
// expect: 18446744073709551615
// expect: hi
// expect: 5
