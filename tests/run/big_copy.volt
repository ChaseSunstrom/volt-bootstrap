use std::io;
// copying big aggregates: the LLVM backend copies them with memcpy (a first-class load and store
// of 64 KB crashed LLVM's instruction selection)

struct page {
    data: u8[65536];
    used: usize;
}

fn fill(p: page&) -> void {
    p.data[65535] = 7;
    p.used = 1;
}

enum slot {
    EMPTY,
    FULL: page,
}

fn main() -> void {
    var a: u8[65536];
    a[65535] = 9;
    var b = a;
    a[65535] = 1;             // b is a copy
    var p: page;
    fill(&p);
    val q = p;
    p = q;                    // assignment, not just a declaration
    std::println("{} {} {} {}", b[65535], q.data[65535], q.used, p.data[65535]);
    // stores built after more code than the load: an element's address, an enum's payload
    var pages: page[2];
    var i: usize = 1;
    pages[i] = q;
    val s = slot::FULL(q);
    val n = match (s) {
        .FULL(x) => x.data[65535],
        .EMPTY => 0,
    };
    std::println("{} {}", pages[1].data[65535], n);
}
// expect: 9 7 1 7
// expect: 7 7
