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
    val qv: viewer = { xs: quiet_ys[..] };
    val q = async quiet(&counter, quiet_ys[..], &qv);
    val q2 = q;
    val cb = async cont_before(&counter);
    val cb2 = cb;
    val ca = async cont_after(&counter);
    val ca2 = ca;
    val qc = async quiet_cont(&counter);
    val qc2 = qc;
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

// p = &n before a continue that comes before the suspend: held at it on the next pass
async fn cont_before(q: i32&) -> i32 {
    var n = 5;
    var p = q;
    for (i) in 0..2 {
        if (i == 0) {
            p = &n;
            continue;
        }
        suspend;
    }
    return *p;
}

// p = &n before a continue after the suspend: the continue goes around holding it, though the
// body's end gives p another value
async fn cont_after(q: i32&) -> i32 {
    var n = 5;
    var p = q;
    for (i) in 0..2 {
        suspend;
        if (i == 0) {
            p = &n;
            continue;
        }
        p = q;
    }
    return *p;
}

struct viewer { xs: i32[..]; }
struct wrap { r: viewer&; }

// moves silently: a slice field's slice points where the field does (so does an element of it),
// a reference field's field is where the reference points, and a local of the loop's own body is
// made again on each pass
async fn quiet(q: i32&, ys: i32[..], vr: viewer&) -> i32 {
    val v: viewer = { xs: ys };
    val s = v.xs[..];
    val e = &v.xs[0];
    val w: wrap = { r: vr };
    val x = &w.r.xs;
    var total = 0;
    for (i) in 0..2 {
        var p = q;
        suspend;
        var n = 5;
        p = &n;
        total += *p;
    }
    return total + s[0] + *e + @cast<i32>(x.len);
}

// a continue from inside the body, holding a body local's reference: made again next pass
async fn quiet_cont(q: i32&) -> i32 {
    var n = 5;
    for (i) in 0..2 {
        var p = q;
        suspend;
        if (i == 0) {
            p = &n;
            continue;
        }
    }
    return n;
}
