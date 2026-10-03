use std::io;
// References stored in structs, arrays and tuples to what can change: writing through them works,
// even when the struct itself is a val (a val is shallow).

struct holder {
    r: i32&;
}

fn poke(h: holder) -> void {
    *h.r += 10;
}

fn wrap(r: i32&) -> holder {
    return { r: r };
}

fn main() -> void {
    var a = 1;
    var b = 2;
    val h: holder = { r: &a };
    *h.r += 1;
    poke(h);
    val rs: i32&[2] = { &a, &b };
    *rs[1] += 1;
    val t = (&b, 0);
    *t.0 += 1;
    *wrap(&a).r += 100;
    val c = 5;
    val ro: holder = { r: &c };
    std::println("{} {} {}", a, b, *ro.r);
}
// expect: 112 4 5
