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
    val fs = async field_sliced();
    val fs2 = fs;
    val lp = async looped(&counter);
    val lp2 = lp;
    val q = async quiet(&counter, quiet_ys[..]);
    val q2 = q;
    std::println("{}", await f);
}

struct holder { arr: i32[3]; }

// a slice of a field array of a local points into the frame too
async fn field_sliced() -> i32 {
    var h: holder = { arr: { 1, 2, 3 } };
    val s = h.arr[..];
    suspend;
    return s[0];
}

var counter: i32 = 0;
var quiet_ys: i32[2] = { 1, 2 };

// p = &n after the suspend: the loop goes around, and at the suspend p holds it
async fn looped(q: i32&) -> i32 {
    var n = 5;
    var p = q;
    for (i) in 0..2 {
        suspend;
        p = &n;
    }
    return *p;
}

struct viewer { xs: i32[..]; }

// moves silently: a slice field's slice points where the field does, and a local of the loop's
// own body is made again on each pass
async fn quiet(q: i32&, ys: i32[..]) -> i32 {
    val v: viewer = { xs: ys };
    val s = v.xs[..];
    var total = 0;
    for (i) in 0..2 {
        var p = q;
        suspend;
        var n = 5;
        p = &n;
        total += *p;
    }
    return total + s[0];
}
