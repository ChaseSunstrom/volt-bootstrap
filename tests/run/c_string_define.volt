// a string #define imports as a str constant: adjacent literals joined, escapes decoded, a define
// naming another one (T-0678); a wide one (L"...") isn't bytes and stays out
use std::io;
use { "c_string_define.h" } as h;

fn main() -> void {
    std::println("{} {} {} {}", h::GREETING, h::JOINED, h::ALIAS, h::NUMBER);
    std::println("{}", h::ESCAPED);
    val n: usize = h::GREETING.len;
    std::println("{}", n);
    // a define's name among the literals (inttypes.h's PRId64), GNU's \e, a long \x run's low byte
    std::println("{} {} {}", h::FORMAT_D, h::ESC.ptr[0], h::LONGX);
}
// expect: hello concat hello 7
// expect: line
// expect: "q" \ AB
// expect: 5
// expect: ld 27 A
