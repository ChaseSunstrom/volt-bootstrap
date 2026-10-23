// a string #define imports as a str constant: adjacent literals joined, escapes decoded, a define
// naming another one (T-0678); a wide one (L"...") isn't bytes and stays out
use std::io;
use { "c_string_define.h" } as h;

fn main() -> void {
    std::println("{} {} {} {}", h::GREETING, h::JOINED, h::ALIAS, h::NUMBER);
    std::println("{}", h::ESCAPED);
    val n: usize = h::GREETING.len;
    std::println("{}", n);
}
// expect: hello concat hello 7
// expect: line
// expect: "q" \ AB
// expect: 5
