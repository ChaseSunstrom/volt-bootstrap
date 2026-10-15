// trait_empty.volt's code once a type attaches plugin: the same fns now run with values
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
    match (p) {
        echo(e) => { return e.k; },
    }
}

fn id_of(p: plugin&) -> u64 {
    return @typeid(p);
}

struct echo { k: i32; }

attach plugin -> echo {
    fn run(this, x: i32) -> i32 { return this.k + x; }
    fn label(static this) -> str { return "echo"; }
}

fn main() -> void {
    val e: echo = { k: 40 };
    val p: plugin = e;
    std::println(run_it(&p));
    std::println(label_of(&p));
    std::println(which(p));
    std::println(id_of(&p) == @typeid(echo));
    val h: host = { p: p, n: 3 };
    std::println(h.p != null);
    val ps: plugin[] = { e };
    std::println(first(ps[..]) != null);
}
// expect: 42
// expect: echo
// expect: 40
// expect: true
// expect: true
// expect: true
