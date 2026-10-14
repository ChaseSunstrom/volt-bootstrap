// flags: --leak-check
// an owned local as a ?? fallback moves only when the optional is empty: it's deleted once either way
// (returned, bound or dropped at its scope's end), never used after it's gone
use std::io;

fn find(ok: bool) -> std::string? {
    if (ok) {
        return std::string::from("found, a string long enough to live on the heap");
    }
    return null;
}

fn pick(ok: bool) -> std::string {
    var full = std::string::from("the fallback, a string long enough to live on the heap");
    return find(ok) ?? full;
}

fn main() -> void {
    std::println("{}", pick(true));
    std::println("{}", pick(false));
    var total: usize = 0;
    for (i) in 0..4 {
        val spare = std::string::from("spare text, long enough to live on the heap");
        val s = find(i % 2 == 0) ?? spare;
        total += s.len();
    }
    std::println("{}", total);
}
// expect: found, a string long enough to live on the heap
// expect: the fallback, a string long enough to live on the heap
// expect: 180
