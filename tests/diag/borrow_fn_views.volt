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
}
