// @typeinfo's optional fields (size, align, stride) as runtime values: they're usize? like the
// declaration says, so ?? and narrowing work on them
use std::io;

struct pair { a: i32; b: u8; }

fn main() -> void {
    val size = @typeinfo(pair).size;
    val align = @typeinfo(pair).align;
    std::println("{} {}", size ?? 0, align ?? 0);
    if (@typeinfo(pair).stride) {
        std::println("stride known");
    }
}
// expect: 8 4
// expect: stride known
