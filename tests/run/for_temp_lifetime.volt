// a for loop over a view into a temporary (the vec returned by make(), through .items()) keeps the
// temporary alive until the loop is done, and deletes it then (or when the loop is left early)
use std::io;

struct res { n: i32; }
attach fn delete(this: res&) -> void { std::println("delete {}", this.n); }

fn make(base: i32) -> std::vec<res> {
    var v: std::vec<res> = {};
    v.push({ n: base }) catch @panic("oom");
    v.push({ n: base + 1 }) catch @panic("oom");
    return move v;
}

fn first_big() -> i32 {
    for (r&) in make(20).items() {
        if (r.n > 20) {
            return r.n; // leaving early deletes the temporary too
        }
    }
    return 0;
}

fn main() -> void {
    for (r&) in make(10).items() {
        std::println("see {}", r.n);
    }
    std::println("after");
    std::println("big {}", first_big());
}
// expect: see 10
// expect: see 11
// expect: delete 11
// expect: delete 10
// expect: after
// expect: delete 21
// expect: delete 20
// expect: big 21
