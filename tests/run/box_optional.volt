use std::io;
// box<T>? is the box itself, null meaning none: as small as a pointer, and every optional operation
// works on it

struct node {
    left: std::mem::box<node>?;
    right: std::mem::box<node>?;
    v: i32 = 0;
}

fn sum(n: node&) -> i32 {
    var s = n.v;
    if (n.left) {
        s += sum(n.left);
    }
    if (n.right) {
        s += sum(n.right);
    }
    return s;
}

fn main() -> !void {
    std::println("{} {}", @sizeof(std::mem::box<i32>?), @sizeof(node));
    var a: std::mem::box<i32>? = null;
    std::println("{} {}", a == null, a);
    a = try i32::new(5);
    std::println("{} {} {}", a != null, a, a.value);
    val b = a ?? (try i32::new(9));
    std::println("{}", b);
    var c: std::mem::box<i32>? = null;
    std::println("{}", c.none);
    val d = c ?? (try i32::new(9));
    std::println("{}", d);
    val t = try node::new({ left: try node::new({ left: null, right: null, v: 2 }), right: null, v: 1 });
    std::println("{}", sum(t));
    var arr: std::mem::box<i32>?[3] = { null, try i32::new(1), null };
    arr[0] = try i32::new(7);
    std::println("{} {}", arr[0], arr[2]);
}
// flags: --leak-check
// expect: 8 24
// expect: true null
// expect: true 5 5
// expect: 5
// expect: true
// expect: 9
// expect: 3
// expect: 7 null
