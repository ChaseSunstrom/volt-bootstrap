use std::io;
struct node { v: i32; next: std::mem::box<node>?; }

fn push(var head: std::mem::box<node>?, v: i32) -> std::mem::mem_error!std::mem::box<node> {
    return try node::new({ v: v, next: move head });
}

fn main() -> !void {
    var list: std::mem::box<node>? = null;
    for (i) in 0..4 {
        list = try push(move list, i);
    }
    var total = 0;
    if (list) {
        total += list.v;
        list.v = 100;
    }
    std::println("{} {}", total, list.value.v);
    val head = list ?? return;
    std::println(head.v);
    if (head.next) {
        head.next = null;
    }
    std::println(head.next == null);
}
// flags: --leak-check
// expect: 3 100
// expect: 100
// expect: true
