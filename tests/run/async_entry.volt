// async main, an export async fn and an extern "C" async fn with a body run to the end when called
// from outside Volt: the start code runs main's frame, and a C fn pointer to one runs its frame.
// Volt code still starts them with async, and an async fn taken as a fn value runs to its end too
use std::io;

async fn count(n: i32) -> i32 {
    var total = 0;
    for (i) in 0..n {
        total += i;
        suspend;
    }
    return total;
}

export async fn twice(n: i32) -> i32 {
    val c = async count(n);
    return 2 * await c;
}

extern "C" async fn thrice(n: i32) -> i32 {
    suspend;
    return 3 * n;
}

// C calls it through a pointer it was given (as qsort calls its comparator)
fn call_c(p: void*, n: i32) -> i32 {
    val f = @cast<extern "C" fn(i32) -> i32>(p);
    return f(n);
}

async fn main() -> void {
    std::println("{} {}", call_c(@cast<void*>(twice), 4), call_c(@cast<void*>(thrice), 5));
    val t: extern "C" fn(i32) -> i32 = twice;
    std::println("{}", t(5));
    val f = async twice(3);
    resume f;
    std::println("{}", await f);
    val v: fn(i32) -> i32 = count;
    std::println("{}", v(5));
    suspend;
    std::println("main ran to the end");
}
// expect: 12 15
// expect: 20
// expect: 6
// expect: 10
// expect: main ran to the end
