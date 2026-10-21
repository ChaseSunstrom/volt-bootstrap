// a header that declares five_set_w itself: that one is p::five_set_w (it stores v + 1), and the
// accessors the header doesn't declare (five_get_w, five_set_k, five_get_k) are voltc's
use std::io;
use { "c_bitfield_clash.h" } as p;

fn main() -> void {
    var s: p::five = {};
    p::five_set_w(&s, 3);
    p::five_set_k(&s, 5);
    std::println("{} {}", p::five_get_w(&s), p::five_get_k(&s));
}
// expect: 4 5
