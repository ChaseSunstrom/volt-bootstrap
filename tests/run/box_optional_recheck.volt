use std::io;
// a debug build re-checks a narrowed box? on each read: the branch may have set it to null

struct node {
    left: std::mem::box<node>?;
    v: i32 = 0;
}

fn main() -> !void {
    var n: node = { left: try node::new({ left: null, v: 1 }) };
    if (n.left) {
        std::println("{}", n.left.v);
        n.left = null;
        std::println("{}", n.left.v);
    }
}
// expect: 1
// exit: 101
// expect-stderr: null pointer dereference
