// a reference through a local's slice or reference field points where that field does, not into
// the local: returning it is fine (the escape check follows only what the local holds in place)
use std::io;

struct viewer { xs: i32[..]; }
struct point { x: i32; y: i32; }
struct wrap { r: point&; }

fn first(ys: i32[..]) -> i32& {
    val v: viewer = { xs: ys };
    return &v.xs[0];
}

fn x_of(p: point&) -> i32& {
    val w: wrap = { r: p };
    return &w.r.x;
}

var nums: i32[3] = { 7, 8, 9 };
var pt: point = { x: 3, y: 4 };

fn main() -> void {
    *first(nums[..]) += 1;
    *x_of(&pt) += 10;
    std::println("{} {}", nums[0], pt.x);
}
// expect: 8 13
