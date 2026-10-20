// the borrow warnings follow views a fn gives out of a reference parameter: str_views(&names) has a
// loan on names, so a view held past the block that deletes names warns (T-0382's cppimport class()
// shape), and so does one held across a change; names outliving the views, a fn giving back owned
// strings, and a fn giving back its generic T (a value, whatever it holds) don't
use std::io;
fn str_views(xs: std::vec<std::string>&) -> std::vec<str> {
    var out: std::vec<str> = {};
    for (s&) in xs.items() {
        out.push(s.as_str()) catch @panic("out of memory");
    }
    return out;
}
fn copies(xs: std::vec<std::string>&) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    for (s&) in xs.items() {
        out.push(copy *s) catch @panic("out of memory");
    }
    return out;
}
<T: type>
fn first(xs: std::vec<T>&) -> T {
    return *xs.at(0);
}
fn names_of(n: usize) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    for (i) in 0..n {
        out.push(std::string::from("t")) catch @panic("out of memory");
    }
    return out;
}
fn main() -> void {
    run(true);
}
fn run(on: bool) -> void {
    // the owner's block ends before the views are read
    var tp: std::vec<str> = {};
    if (on) {
        val names = names_of(2);
        tp = str_views(&names);
        std::println(tp.len);
    }
    std::println(tp.len);
    // the owner outlives the views
    val kept = names_of(2);
    var tq: std::vec<str> = {};
    if (on) {
        tq = str_views(&kept);
    }
    std::println(tq.len);
    val v = str_views(&kept);
    std::println(v.len);
    // owned copies look into nothing
    var tc: std::vec<std::string> = {};
    if (on) {
        val names = names_of(2);
        tc = copies(&names);
    }
    std::println(tc.len);
    // a generic T is a value, whatever it holds
    var s = "";
    if (on) {
        var strs: std::vec<str> = {};
        strs.push("a") catch @panic("out of memory");
        s = first(&strs);
    }
    std::println(s);
    // a change at the owner
    var grow = names_of(1);
    val w = str_views(&grow);
    grow.push(std::string::from("u")) catch @panic("out of memory");
    std::println(w.len);
    // the owner given away (moved) isn't deleted at the block's end
    var tm: std::vec<str> = {};
    var keep: std::vec<std::vec<std::string>> = {};
    if (on) {
        val names = names_of(2);
        tm = str_views(&names);
        keep.push(names) catch @panic("out of memory");
    }
    std::println(tm.len);
    // a closure using a view whose owner's block ended
    val first_kept = names_of(1);
    var tg = str_views(&first_kept);
    val count = |tg&| () -> usize { return tg.len; };
    if (on) {
        val names = names_of(2);
        tg = str_views(&names);
    }
    std::println(count());
    // the owner a loop's body holds, deleted at the end of each pass
    var tl: std::vec<str> = {};
    var n: usize = 0;
    while (n < 2) {
        val names = names_of(n);
        tl = str_views(&names);
        n += 1;
    }
    std::println(tl.len);
    // a result that may fail, unwrapped by catch
    var te: std::vec<str> = {};
    if (on) {
        val names = names_of(2);
        te = try_views(&names) catch @panic("out of memory");
    }
    std::println(te.len);
    // only the first reference parameter lends the result: when its argument isn't a local, a
    // later one isn't followed instead
    var lists: std::vec<std::vec<std::string>> = {};
    lists.push(names_of(1)) catch @panic("out of memory");
    var t2: std::vec<str> = {};
    if (on) {
        val names = names_of(2);
        t2 = views_of_second(first_list(&lists), &names);
    }
    std::println(t2.len);
}
fn try_views(xs: std::vec<std::string>&) -> std::mem::mem_error!std::vec<str> {
    var out: std::vec<str> = {};
    for (s&) in xs.items() {
        try out.push(s.as_str());
    }
    return out;
}
fn first_list(ls: std::vec<std::vec<std::string>>&) -> std::vec<std::string>& {
    return ls.at(0);
}
fn views_of_second(a: std::vec<std::string>&, b: std::vec<std::string>&) -> std::vec<str> {
    return str_views(b);
}
