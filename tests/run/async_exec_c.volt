// flags: --leak-check --backend c
// @done says whether a frame has finished, and std::exec::run_all resumes frames in rounds until all
// have (sleeping only while every one is waiting on a waker: never, for frames that suspend themselves)
use std::io;
use std::exec;

async fn count(name: str, n: i32) -> void {
    for (i) in 0..n {
        std::println("{} {}", name, i);
        suspend;
    }
}

fn main() -> void {
    val a = async count("a", 2);
    std::println("done {}", @done(a));
    var frames: std::vec<@typeof(a)> = {};
    frames.push(a);
    val b = async count("b", 1);
    frames.push(b);
    std::exec::run_all(&frames);
    std::println("done {} {}", @done(frames[0]), @done(frames[1]));
}
// expect: a 0
// expect: done false
// expect: b 0
// expect: a 1
// expect: done true true
