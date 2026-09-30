// copying an error union that holds an error copies the error too (with its copy hook), so the
// copy and the original each delete their own
use std::io;

struct res { n: i32; }
attach fn delete(this: res&) -> void { std::println("delete {}", this.n); }
attach fn copy(this: res&) -> res {
    std::println("copy {}", this.n);
    return { n: this.n + 10 };
}

error oops { BAD: res }

fn fail() -> oops!i32 {
    return oops::BAD({ n: 1 });
}

fn main() -> void {
    val a = fail();
    val b = copy a;
    std::println("copied");
}
// expect: copy 1
// expect: copied
// expect: delete 11
// expect: delete 1
