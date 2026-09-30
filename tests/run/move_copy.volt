use std::io;
struct r { n: i32; }
attach fn delete(this: r&) -> void { std::println("del {}", this.n); }
attach fn copy(this: r&) -> r { return { n: this.n + 100 }; }

fn give(n: i32) -> r { return { n: n }; }

fn main() -> void {
    val a = give(1);
    val b = copy a;
    std::println("{} {}", a.n, b.n);
    var c = give(2);
    for (i) in 0..2 {
        val t = give(10 + i);
        if (i == 1) { break; }
    }
    c = move b;
    std::println(c.n);
}
// expect: 1 101
// expect: del 10
// expect: del 11
// expect: del 2
// expect: 101
// expect: del 101
// expect: del 1
