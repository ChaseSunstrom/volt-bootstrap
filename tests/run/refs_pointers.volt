// T& references (never null, `.` reaches through) and T* raw pointers (may be null, -> and arithmetic)
use std::io;

struct node {
    key: i32;
    next: node*; // null ends the list (a pointer left out of a literal is null)
}

attach fn twice(this: node&) -> i32 {
    return this.key * 2;
}

fn find(head: node*, key: i32) -> node* {
    var cur = head;
    while (cur) { // narrows: cur is a node& inside
        if (cur.key == key) {
            return cur;
        }
        cur = cur->next;
    }
    return null;
}

fn bump(r: i32&) -> void {
    *r += 1;
}

fn sum(p: i32*, n: usize) -> i32 {
    var t = 0;
    for (i) in 0..n {
        t += p[i]; // unchecked, like C
    }
    return t;
}

fn main() -> void {
    var c: node = { key: 3 };
    var b: node = { key: 2, next: &c };
    var a: node = { key: 1, next: &b };
    val hit = find(&a, 3);
    std::println("found {} {}", hit->key, hit->twice());
    std::println("missing {}", find(&a, 9) == null);
    val r: node& = find(&a, 2) ?? return; // ?? turns a T* into a T&
    std::println("ref {}", r.key);
    var x = 41;
    bump(&x);
    std::println("bumped {}", x);
    var arr: i32[4] = { 1, 2, 3, 4 };
    val p: i32* = &arr[0];
    std::println("sum {}", sum(p, 4));
    val q = p + 2;
    std::println("q {} {} diff {} commuted {}", *q, q[1], q - p, *(1 + p));
    var w = p;
    w += 3;
    w--;
    std::println("w {} before {}", *w, w > p);
    val big = 3 as i64 * 2; // a cast, then a multiply
    std::println("cast {}", big);
    val nothing: node* = null;
    std::println("null prints {}", nothing);
    for (e&) in arr {
        *e *= 10;
    }
    std::println("arr {}", arr);
    val v: void* = p;
    std::println("void {}", v != null);
}

// expect: found 3 6
// expect: missing true
// expect: ref 2
// expect: bumped 42
// expect: sum 10
// expect: q 3 4 diff 2 commuted 2
// expect: w 3 before true
// expect: cast 6
// expect: null prints null
// expect: arr { 10, 20, 30, 40 }
// expect: void true
