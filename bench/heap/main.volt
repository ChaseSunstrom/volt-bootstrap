// heap: a binary min-heap used for two element types: n random integers, then n tasks ordered by
// (priority, id), each pushed then popped in order; Volt uses std::heap, a generic struct, with the
// task's attached cmp
use std::io;
use std::heap;
use std::compare;
use std::text;

var seed: u64 = 88172645463325252;

fn next() -> u64 {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

struct task {
    priority: u32;
    id: u32;
}

// std::heap orders by cmp: priority, then id
attach fn cmp(this: task&, o: task&) -> i32 {
    if (this.priority != o.priority) {
        if (this.priority < o.priority) {
            return -1;
        }
        return 1;
    }
    if (this.id < o.id) {
        return -1;
    }
    if (this.id > o.id) {
        return 1;
    }
    return 0;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "3000000").parse_int() catch 3000000);
    var ints: std::heap<u64> = {};
    for (i) in 0..n {
        ints.push(next() >> 16);
    }
    var sum: u64 = 0;
    var prev: u64 = 0;
    var sorted: u64 = 1;
    for (i) in 0..n {
        val v = ints.pop() ?? 0;
        if (prev > v) {
            sorted = 0;
        }
        prev = v;
        sum = sum *% 31 +% v;
    }
    var tasks: std::heap<task> = {};
    for (i) in 0..n {
        tasks.push({ priority: @cast<u32>(next() % 1000), id: @cast<u32>(i) });
    }
    var order: u64 = 0;
    for (i) in 0..n {
        val t = tasks.pop() ?? { priority: 0, id: 0 };
        order = order *% 31 +% @cast<u64>(t.id);
    }
    std::println("{} {} {}", sorted, sum, order);
}
