// flags: --backend c
// an async fn's generated helpers (x_step, x_await, x_run, x_entry, x_frame, x_tramp in C) take
// names no fn of the program has: a user fn named like one is its own function. Also a generic
// async fn as a fn value, and an extern "C" async fn called by its C name from another declaration
use std::io;

async fn x(n: i32) -> i32 {
    suspend;
    return n + 1;
}

fn x_entry(n: i32) -> i32 { return n * 100; }
fn x_step(n: i32) -> i32 { return n * 200; }
fn x_await(n: i32) -> i32 { return n * 300; }
fn x_run(n: i32) -> i32 { return n * 400; }
fn x_tramp(n: i32) -> i32 { return n * 500; }

export async fn ex(n: i32) -> i32 {
    suspend;
    return n + 2;
}

// exported: C names them ex_frame and ex_step, like ex's builder and step function
export fn ex_frame(n: i32) -> i32 { return n * 600; }
export fn ex_step(n: i32) -> i32 { return n * 700; }
// exported under the very name x's step function would take: the helper takes another
export fn v_x_step(n: i32) -> i32 { return n * 800; }

<T: type>
async fn doubled(v: T) -> T {
    suspend;
    return v + v;
}

fn apply(f: fn(i32) -> i32, v: i32) -> i32 {
    return f(v);
}

// defined here, its C symbol is tripled_c; the namespace's declaration names the same symbol
extern "C" async fn tripled_c(n: i32) -> i32 {
    suspend;
    return 3 * n;
}

// an attach fn exported under the name y's step function would take (struct v's y_step is
// v_y_step in C), declared after y: the helper takes another
async fn y(n: i32) -> i32 {
    suspend;
    return n + 3;
}

struct v { k: i32; }
export attach fn y_step(this: v&) -> i32 { return this.k * 900; }

namespace c_side {
    extern "C" fn tripled_c(n: i32) -> i32;
}

fn main() -> void {
    val vf: fn(i32) -> i32 = x;
    std::println("{} {} {} {} {} {}", vf(1), x_entry(1), x_step(1), x_await(1), x_run(1), x_tramp(1));
    std::println("{} {} {}", x(5), apply(x_entry, 2), apply(x_tramp, 2));
    std::println("{} {} {} {}", ex(1), ex_frame(1), ex_step(1), v_x_step(1));
    val d = doubled<i32>;
    std::println("{} {} {}", d(21), apply(doubled<i32>, 4), doubled(1.5));
    std::println("{}", c_side::tripled_c(7));
    val vv: v = { k: 1 };
    std::println("{} {}", y(1), vv.y_step());
}
// expect: 2 100 200 300 400 500
// expect: 6 200 1000
// expect: 3 600 700 800
// expect: 42 8 3
// expect: 21
// expect: 4 900
