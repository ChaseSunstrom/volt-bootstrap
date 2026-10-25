use std::io;
use std::exec;
// a Rust future's waker wakes the Volt frame waiting on it: await sleeps until then (two polls, not
// one a millisecond), resume returns at once while it's pending, and std::exec::run_all drives
// several frames, sleeping while all of them wait
use { "geom" } as geom;

fn main() -> void {
    std::println("await polls {}", geom::woken_after(30) <= 3);
    var f = async geom::woken_after(30);
    std::println("started {}", @done(f));
    resume f;
    std::println("resumed {}", @done(f));
    std::println("then {}", await f <= 4);
    var a = async geom::woken_after(20);
    var frames: std::vec<@typeof(a)> = {};
    frames.push(a);
    val b = async geom::woken_after(10);
    frames.push(b);
    std::exec::run_all(&frames);
    std::println("all {} {}", @done(frames[0]), @done(frames[1]));
    // (each frame moved into the vec after it started: its value lands in it, not where it began)
    std::println("values {} {}", await frames[0] >= 2, await frames[1] >= 2);
}
// expect: await polls true
// expect: started false
// expect: resumed false
// expect: then true
// expect: all true true
// expect: values true true
