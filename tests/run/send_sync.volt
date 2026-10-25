// send and sync when a program runs: a closure given to std::thread::spawn must be send. One holding
// a raw pointer warns (and still builds and runs); one borrowing an i32 (sync) or owning a vec
// (std's containers are send when their items are) doesn't
use std::io;
use std::thread;

fn main() -> void {
    var n = 5;
    var t = std::thread::spawn(|n&| () { std::println("borrowed {}", n); }) catch @panic("no thread");
    t.join();
    val q: i32* = &n;
    var u = std::thread::spawn(|q| () { std::println("pointer {}", *q); }) catch @panic("no thread");
    u.join();
    var v: std::vec<i32> = {};
    v.push(3) catch @panic("out of memory");
    var w = std::thread::spawn(|move v| () { std::println("moved {}", v.len); }) catch @panic("no thread");
    w.join();
}
// expect: borrowed 5
// expect: pointer 5
// expect: moved 1
// expect-stderr: warning: the closure isn't send, but spawn's F must be: q is a raw pointer (i32*)
// reject-stderr: must be: n is
// reject-stderr: must be: v
