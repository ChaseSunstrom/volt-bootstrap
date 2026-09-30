use std::io;

extern "C" fn printf(fmt: cstr, ...) -> i32;

struct point {
    x: i32;
    y: i32 = 10;
}

fn add(a: i32, b: i32) -> i32 {
    return a + b;
}

fn add(a: f64, b: f64) -> f64 {
    return a + b;
}

fn main() -> i32 {
    var x = 0;
    x++;
    x += 41;
    std::println(x);
    std::println("sum {} and {}", add(1, 2), add(1.5, 2.25));
    val p: point = { x: 3 };
    std::println(p);
    std::println("p.y = {}", p.y);
    printf("from C: %d %s\n", p.x, "hi");
    val arr: i32[] = { 5, 10, 15 };
    for (v, i) in arr => v * 2 {
        std::println("{}: {}", i, v);
    }
    val total = for (v) in 0..5 [ var acc: i32 = 0 ] {
        acc += v;
    };
    std::println("total {}", total);
    :outer for (i) in 0..10 {
        for (j) in 0..=3 {
            if (j == 2) { continue :outer; }
            if (i == 2) { break :outer; }
            std::println("{} {}", i, j);
        }
    }
    val found = loop {
        if (x > 45) { break x; }
        x += 1;
    };
    val clamped = :blk {
        if (found > 100) { break :blk 100; }
        break :blk found;
    };
    std::println("found {} clamped {}", found, clamped);
    val middle: i32[..] = arr[1..3];
    std::println(middle);
    val (a, b) = (1, "two");
    std::println("{} {}", a, b);
    return 3;
}
// expect: 42
// expect: sum 3 and 3.75
// expect: point { x: 3, y: 10 }
// expect: p.y = 10
// expect: from C: 3 hi
// expect: 0: 10
// expect: 1: 20
// expect: 2: 30
// expect: total 10
// expect: 0 0
// expect: 0 1
// expect: 1 0
// expect: 1 1
// expect: found 46 clamped 46
// expect: { 10, 15 }
// expect: 1 two
// exit: 3
