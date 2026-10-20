// the borrow warnings: moving a frame that may point into itself (a local of its async fn holds a
// reference to another of its locals, or into a local array, across a suspend) warns, and the
// program still builds; a frame whose references point elsewhere (a string's text) moves silently
use std::io;

async fn pointing() -> i32 {
    var n = 5;
    val p = &n;
    suspend;
    return *p;
}

async fn sliced() -> i32 {
    var xs: i32[3] = { 1, 2, 3 };
    val s = xs[..];
    suspend;
    return s[0];
}

async fn walking() -> i32 {
    var xs: i32[3] = { 1, 2, 3 };
    var total = 0;
    for (x&) in xs {
        suspend;
        total += *x;
    }
    return total;
}

async fn texts() -> usize {
    var s = std::string::from("hi");
    val v = s.as_str();
    suspend;
    return v.len;
}

async fn outer() -> i32 {
    val inner = async pointing();
    suspend;
    return await inner;
}

fn main() -> void {
    val a = async pointing();
    val b = a;
    val c = async sliced();
    val d = c;
    val e = async texts();
    val f = e;
    val g = async outer();
    val h = g;
    val w = async walking();
    val w2 = w;
    std::println("{}", await f);
}
