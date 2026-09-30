use std::io;
use std::fmt;
// format specifiers: {:[[fill]align][sign][#][0][width][.precision][type]}, in println, std::format
// and std::write alike

fn main() -> void {
    // width, alignment and fill: numbers go right, text and bool left, ^ centres (extra on the right)
    std::println("[{:5}] [{:<5}] [{:>5}] [{:^5}] [{:*^7}]", 42, 42, "ab", "ab", "mid");
    // sign, zero padding (after the sign), radixes with and without the # prefix
    std::println("{:+} {:+} {:05} {:05} {:x} {:X} {:#x} {:b} {:#b} {:o} {:#o} {:08b}", 7, -7, 42, -42, 255, 255, 255, 5, 5, 8, 8, 5);
    // a negative integer in hex, binary or octal is its two's complement at its own width
    val m: i8 = -1;
    val big: i32 = -2;
    val u: u32 = 3000000000;
    std::println("{:x} {:x} {:#06x} {:X}", m, big, 10, u);
    // floats: fixed precision, width, sign, zero padding, and exponents
    std::println("{:.2} {:8.3} {:<8.1}| {:+.1} {:08.2} {:e} {:.2e} {:E} {:.0}", 3.14159, 2.5, 1.26, 2.0, -3.5, 1500.0, 1234.5, 0.00012, 2.7);
    // text: precision truncates (by characters), width counts characters; bool; {:c} is a character
    std::println("[{:.3}] [{:6}] [{:>6}] [{:<4}] {:c}{:c}{:c}", "volt!", true, false, "é", 'h', 105, 0x263A);
    // braces still escape, and a plain {} is unchanged
    std::println("{{{:>3}}} {} {}", 1, 2.5, -0.5);
    // {:c} of something that isn't a character (a surrogate, past U+10FFFF) is U+FFFD
    std::println("{:c}{:c}", 0xD800, 0x110000);
}
// expect: [   42] [42   ] [   ab] [ ab  ] [**mid**]
// expect: +7 -7 00042 -0042 ff FF 0xff 101 0b101 10 0o10 00000101
// expect: ff fffffffe 0x000a B2D05E00
// expect: 3.14    2.500 1.3     | +2.0 -0003.50 1.5e3 1.23e3 1.2E-4 3
// expect: [vol] [true  ] [ false] [é   ] hi☺
// expect: {  1} 2.5 -0.5
// expect: ��
