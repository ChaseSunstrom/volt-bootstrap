use std::io;

<F: type>
fn apply(f: F, v: i32) -> i32 { return f(v); }

fn apply_any(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }

fn twice(n: i32) -> i32 { return n * 2; }

extern "C" fn qsort(base: void*, n: usize, size: usize, cmp: extern "C" fn(void*, void*) -> i32) -> void;

fn cmp_i32(a: void*, b: void*) -> i32 {
    return *@cast<i32&>(a) - *@cast<i32&>(b);
}

struct res { n: i32; }
attach fn delete(this: res&) -> void { std::println("del {}", this.n); }

fn main() -> void {
    var x = 0;
    val bump = |x&| () { x++; };
    bump();
    bump();
    std::println(x);

    val add = |x| (a: i32) -> i32 { return a + x; };
    x = 100;
    std::println("{} {}", add(1), apply(add, 5));
    std::println(apply_any(add, 10));
    std::println(apply_any(twice, 21));
    std::println(apply_any(|| (a) { return a * a; }, 9));

    var arr: i32[] = { 5, 3, 9, 1 };
    qsort(@cast<void*>(&arr), 4, 4, cmp_i32);
    std::println(arr);

    val r: res = { n: 7 };
    val own = |move r| () -> i32 { return r.n; };
    std::println("own {}", own());
    std::println("end");
}
// expect: 2
// expect: 3 7
// expect: 12
// expect: 42
// expect: 81
// expect: { 1, 3, 5, 9 }
// expect: own 7
// expect: end
// expect: del 7
