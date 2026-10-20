// flags: --leak-check
// a function returns a closure as a std::func<fn(...)>: the closure moves to memory of its own with
// what it captured, the func calls as the fn it holds (through a reference too) and passes where
// one is wanted, and what it captured is deleted once, when the func goes (moved around in a vec,
// or never called)
use std::io;

var drops: i32 = 0;
struct res { id: i32; }
attach fn delete(this: res&) -> void { drops += 1; }

fn make_adder(n: i32) -> std::func<fn(i32) -> i32> {
    return |n| (x) { return x + n; };
}

fn make_tagged(id: i32) -> std::func<fn(i32) -> i32> {
    val r: res = { id: id };
    return |move r| (x) { return x * r.id; };
}

fn named(text: str) -> std::func<fn() -> usize> {
    val s = std::string::from(text);
    return std::func<fn() -> usize>::of(|move s| () -> usize { return s.len(); });
}

fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x);
}

fn main() -> void {
    val add5 = make_adder(5);
    std::println("{} {}", add5(1), apply(add5, 10));
    {
        val t = make_tagged(3);
        std::println("{} {} drops {}", t(2), t(4), drops);
    }
    std::println("drops {}", drops);
    var fs: std::vec<std::func<fn(i32) -> i32>> = {};
    fs.push(make_adder(1));
    fs.push(make_tagged(10));
    fs.push(make_adder(100));
    var total = 0;
    for (f&) in fs.items() {
        total += f(1);
    }
    std::println("total {}", total);
    {
        val unused = make_tagged(7);
    }
    std::println("drops {}", drops);
    val n = named("hello");
    std::println("len {}", n());
}
// expect: 6 15
// expect: 6 12 drops 0
// expect: drops 1
// expect: total 113
// expect: drops 2
// expect: len 5
