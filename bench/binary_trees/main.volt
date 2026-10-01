// binary-trees (the Benchmarks Game): allocate and walk many perfect binary trees, then free them
use std::io;
use std::text;

struct node {
    left: std::mem::box<node>?;
    right: std::mem::box<node>?;
}

fn make(depth: i32) -> std::mem::box<node> {
    if (depth > 0) {
        return node::new({ left: make(depth - 1), right: make(depth - 1) }) catch @panic("out of memory");
    }
    return node::new({ left: null, right: null }) catch @panic("out of memory");
}

fn check(n: node&) -> i32 {
    var c = 1;
    if (n.left) {
        c += check(n.left);
    }
    if (n.right) {
        c += check(n.right);
    }
    return c;
}

fn main() -> void {
    var max = @cast<i32>((std::process::arg(1) ?? "18").parse_int() catch 18);
    if (max < 6) {
        max = 6;
    }
    {
        val stretch = make(max + 1);
        std::println("stretch tree of depth {}\t check: {}", max + 1, check(stretch));
    }
    val long_lived = make(max);
    var d = 4;
    while (d <= max) {
        val iters = 1 << (max - d + 4);
        var sum = 0;
        for (i) in 0..iters {
            val t = make(d);
            sum += check(t);
        }
        std::println("{}\t trees of depth {}\t check: {}", iters, d, sum);
        d += 2;
    }
    std::println("long lived tree of depth {}\t check: {}", max, check(long_lived));
}
