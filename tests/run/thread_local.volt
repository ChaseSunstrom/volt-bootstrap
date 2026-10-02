use std::io;
use std::thread;
// @thread_local: each thread has its own copy of a global var, starting at its initial value

@attributes([@thread_local])
var count: i64 = 100;

var total: std::thread::atomic_i64 = {};

fn bump(times: i64) -> void {
    for (i) in 0..times {
        count += 1;
    }
    total.add(count);
}

fn main() -> !void {
    count = 5;
    var ts: std::vec<std::thread::thread> = {};
    for (k) in 1..4 {
        try ts.push(try std::thread::spawn(|k| () { bump(@cast<i64>(k) * 10); }));
    }
    ts.clear(); // joins them
    // each thread started from 100: 110 + 120 + 130; this one's count is still its own
    std::println("{} {}", total.load(), count);
}
// expect: 360 5
