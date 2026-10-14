// a field as a ?? fallback would move out of its struct: it takes copy, as a let does
use std::io;

struct box {
    name: std::string;
}

fn find() -> std::string? {
    return null;
}

fn main() -> void {
    val b: box = { name: std::string::from("held by a struct") };
    val c = find() ?? b.name;
}
// error: can't move a std::string<std::mem::default_allocator> out of a field, element or reference; copy it instead: copy x
