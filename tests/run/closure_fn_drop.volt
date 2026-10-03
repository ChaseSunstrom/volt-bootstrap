// A closure literal made into a fn(...) value is a temporary: the fn value borrows it, and it is
// deleted (its move captures with it) with the variable it initializes, or at the end of the
// statement it's in
use std::io;

struct noisy {
    n: i32;
}

attach fn delete(this: noisy&) -> void {
    std::println("noisy {} gone", this.n);
}

struct holder {
    f: fn(i32) -> i32;
}

fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x);
}

// in an async fn the closure lives in the frame, across the suspend
async fn later(e: noisy) -> i32 {
    val f: fn(i32) -> i32 = |move e| (x: i32) -> i32 { return x + e.n; };
    suspend;
    return f(100);
}

fn twice(d: noisy) -> i32 {
    return apply(|move d| (x: i32) -> i32 { return x * 2 + d.n; }, 20);
}

fn main() -> void {
    {
        val a: noisy = { n: 1 };
        val f: fn(i32) -> i32 = |move a| (x: i32) -> i32 { return x + a.n; };
        std::println("val {}", f(1));
        std::println("still {}", f(2));
    }
    val b: noisy = { n: 2 };
    std::println("arg {}", apply(|move b| (x: i32) -> i32 { return x * b.n; }, 5));
    std::println("after arg");
    {
        val c: noisy = { n: 3 };
        val h: holder = { f: |move c| (x: i32) -> i32 { return x - c.n; } };
        val g = h.f;
        std::println("field {}", g(10));
    }
    std::println("returned {}", twice({ n: 4 }));
    std::println("async {}", later({ n: 5 }));
    std::println("end");
}
// expect: val 2
// expect: still 3
// expect: noisy 1 gone
// expect: arg 10
// expect: noisy 2 gone
// expect: after arg
// expect: field 7
// expect: noisy 3 gone
// expect: noisy 4 gone
// expect: returned 44
// expect: noisy 5 gone
// expect: async 105
// expect: end
