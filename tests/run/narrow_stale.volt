// a pointer narrowed by if/while can be assigned inside; reading it again re-checks for null
use std::io;

struct node {
    key: i32;
    next: node*;
}

fn main() -> void {
    var b: node = { key: 2 };
    var a: node = { key: 1, next: &b };
    var cur: node* = &a;
    if (cur) {
        cur = cur->next;
        std::println("second {}", cur.key); // still fine: b
        cur = cur->next;                    // null now
        std::println("third {}", cur.key);  // traps instead of reading through null
    }
}
// expect: second 2
// exit: 101
