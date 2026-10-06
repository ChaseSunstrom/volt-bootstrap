// a by-value this is a local like any other: it can be returned (moved out), and a moved this can't
// be used after
use std::io;
struct big { x: std::string; }
attach fn keep(this: big) -> big {
    return this;
}
attach fn scale(this: big, s: str) -> big {
    var out = this;
    out.x.append(s);
    return out;
}
fn main() -> void {
    var t: std::string = {};
    t.append("hi");
    val b: big = { x: t };
    val r = b.keep().scale("!");
    std::println(r.x);
}
// expect: hi!
