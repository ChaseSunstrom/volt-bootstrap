// std::vec and std::string index with []: v[i] is a place (read it, assign to it, += it, borrow
// it), s[i] a byte; past the end panics with at()'s message
use std::io;

struct point {
    x: i32;
    y: i32;
}

// a generic fn indexes a std::vec<T> like any other
<T: type>
fn last(v: std::vec<T>&) -> T& {
    return &v[v.len - 1];
}

<T: type>
fn total(v: std::vec<T>&) -> T {
    var sum = v[0];
    for (k) in 1..v.len {
        sum += v[k];
    }
    return sum;
}

fn main() -> void {
    var v: std::vec<i32> = {};
    for (k) in 0..4 {
        v.push(k * 10) catch @panic("out of memory");
    }
    v[1] = 11;
    v[2] += 5;
    val p = &v[3];
    *p += 1;
    *last(&v) *= 2;
    std::println("{} {} {} {} {}", v[0], v[1], v[2], v[3], total(&v));

    var pts: std::vec<point> = {};
    pts.push({ x: 1, y: 2 }) catch @panic("out of memory");
    pts.push({ x: 3, y: 4 }) catch @panic("out of memory");
    pts[0].x += 10;
    pts[1] = { x: pts[0].y, y: pts[0].x };
    val q = &pts[1];
    q.y -= 1;
    std::println("{} {} {} {} {}", pts[0].x, pts[0].y, pts[1].x, pts[1].y, last(&pts).y);

    var words: std::vec<std::string> = {};
    words.push(std::string::from("red")) catch @panic("out of memory");
    words.push(std::string::from("green")) catch @panic("out of memory");
    words[0].append("dish");
    words[1] = std::string::from("blue");
    val w = &words[1];
    w.append("s");
    std::println("{} {} {} {}", words[0], words[1], words[0].len(), *last(&words));

    var s = std::string::from("volt");
    std::println("{} {} {}", s[0], s[3], s.len());
    s[0] = 86;
    s[3] += 1;
    std::println("{}", s);

    std::println("{}", v[4]);
}
// expect: 0 11 25 62 98
// expect: 11 2 2 10 10
// expect: reddish blues 7 blues
// expect: 118 116 4
// expect: Volu
// exit: 101
// expect-stderr: index 4 out of bounds (len 4)
