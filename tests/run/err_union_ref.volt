// suffixes after E!T apply to the whole error union: E!T& is a reference to one, E!T? an optional
// one; the payload takes suffixes only in parentheses, E!(T*)
use std::io;

error oops {
    BAD,
}

fn failed(r: oops!i32&) -> bool {
    return r.err != null;
}

fn first(xs: i32[..]) -> oops!(i32*) {
    if (xs.len == 0) {
        return oops::BAD;
    }
    return @cast<i32*>(&xs[0]);
}

fn main() -> void {
    var good: oops!i32 = 5;
    val bad: oops!i32 = oops::BAD;
    std::println("{} {}", failed(&good), failed(&bad));
    var maybe: oops!i32? = null;
    std::println("{}", maybe == null);
    maybe = good;
    std::println("{}", maybe != null);
    val xs: i32[2] = { 7, 8 };
    val p = first(xs) catch |e| null;
    std::println("{}", *(p ?? return));
    val grouped: (i32) = 3;
    std::println("{}", grouped + 1);
}
// expect: false true
// expect: true
// expect: true
// expect: 7
// expect: 4
