// a trait nothing attaches is a type with no values: code written against it checks (calls through
// it type-check against the trait's fns) and lowers to unreachable; trait_empty_attached.volt is the
// same code once a type attaches it
use std::io;

trait plugin {
    fn run(this, x: i32) -> i32;
    fn label(static this) -> str;
}

struct host {
    p: plugin?;
    n: i32;
}

fn run_it(p: plugin&) -> i32 {
    return p.run(1) + 1;
}

fn label_of(p: plugin*) -> str {
    return p->label();
}

fn first(ps: plugin[..]) -> plugin? {
    if (ps.len == 0) {
        return null;
    }
    return ps[0];
}

fn which(p: plugin) -> i32 {
    match (p) {}
    return 0;
}

fn id_of(p: plugin&) -> u64 {
    return @typeid(p);
}

fn main() -> void {
    val h: host = { p: null, n: 3 };
    if (h.p == null) {
        std::println("no plugin, n = {}", h.n);
    }
    std::println("{} {}", @sizeof(plugin), @alignof(plugin));
    val none: plugin[] = {};
    std::println(first(none[..]) == null);
}
// expect: no plugin, n = 3
// expect: 2 2
// expect: true
