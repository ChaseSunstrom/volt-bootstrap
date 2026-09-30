use std::io;

struct node {
    value: i32;
    next: std::mem::box<node>?;
}

attach fn delete(this: node&) -> void {
    std::println("free node {}", this.value);
}

fn sum(n: node&) -> i32 {
    var total = n.value;
    if (n.next) {
        total += sum(n.next);
    }
    return total;
}

fn main() -> !void {
    val b = try i32::new(41);
    *b += 1;
    std::println(b);
    val list = try node::new({ value: 1, next: try node::new({ value: 2, next: try node::new({ value: 3, next: null }) }) });
    std::println("sum {}", sum(list));
    std::println(list.value);
    val c = copy b;
    *c = 7;
    std::println("{} {}", b, c);
}
// flags: --leak-check
// expect: 42
// expect: sum 6
// expect: 1
// expect: 42 7
// expect: free node 1
// expect: free node 2
// expect: free node 3
