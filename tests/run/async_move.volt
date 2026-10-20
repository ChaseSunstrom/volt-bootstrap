// flags: --leak-check
// a frame moves like any owned value: into another variable or a vec, resumed and awaited where it
// went, and cancelled (its defers running once) where it ends up (a vec deletes its last first)
use std::io;

async fn ticker(name: str, n: i32) -> i32 {
    defer { std::println("{} cleaned up", name); }
    var k = 0;
    while (k < n) {
        std::println("{} tick {}", name, k);
        k += 1;
        suspend;
    }
    return k * 10;
}

fn main() -> void {
    val a = async ticker("a", 3);
    val b = a;
    resume b;
    std::println("b gives {}", await b);
    val e = async ticker("e", 5);
    {
        val inner = e;
        std::println("inner ends");
    }
    val c = async ticker("c", 5);
    var frames: std::vec<@typeof(c)> = {};
    frames.push(c);
    val d = async ticker("d", 5);
    frames.push(d);
    for (f&) in frames.items() {
        resume f;
    }
    std::println("{} frames", frames.len);
}
// expect: a tick 0
// expect: a tick 1
// expect: a tick 2
// expect: a cleaned up
// expect: b gives 30
// expect: e tick 0
// expect: inner ends
// expect: e cleaned up
// expect: c tick 0
// expect: d tick 0
// expect: c tick 1
// expect: d tick 1
// expect: 2 frames
// expect: d cleaned up
// expect: c cleaned up
