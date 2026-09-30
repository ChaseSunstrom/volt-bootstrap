use std::io;
struct res {
    name: str;
}

attach fn delete(this: res&) -> void {
    std::println("delete {}", this.name);
}

struct pair {
    a: res;
    b: res;
}

attach fn delete(this: pair&) -> void {
    std::println("delete pair");
}

fn make(n: str) -> res { return { name: n }; }

fn consume(r: res) -> void {
    std::println("consume {}", r.name);
}

fn pick(flag: bool) -> void {
    val x = make("x");
    if (flag) {
        consume(move x);
    }
    std::println("end pick {}", flag);
}

fn main() -> void {
    val a = make("a");
    {
        val b = make("b");
        val c = make("c");
    }
    val p: pair = { a: make("pa"), b: make("pb") };
    consume(make("tmp"));
    val moved = a;
    pick(true);
    pick(false);
    var r = make("r1");
    r = make("r2");
    make("discarded");
    for (i) in 0..2 {
        val l = make("loop");
    }
    std::println("end main");
}
// expect: delete c
// expect: delete b
// expect: consume tmp
// expect: delete tmp
// expect: consume x
// expect: delete x
// expect: end pick true
// expect: end pick false
// expect: delete x
// expect: delete r1
// expect: delete discarded
// expect: delete loop
// expect: delete loop
// expect: end main
// expect: delete r2
// expect: delete a
// expect: delete pair
// expect: delete pb
// expect: delete pa
