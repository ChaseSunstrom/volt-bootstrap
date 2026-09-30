use std::io;
use std::fmt;
// format specs that can't apply; std::write to something that isn't a writer

struct point {
    x: i32;
}

struct nowriter {}

fn unknown_type() -> void {
    std::println("{:q}", 1);
}

fn spec_on_struct() -> void {
    val p: point = { x: 1 };
    std::println("{:5}", p);
}

fn precision_on_int() -> void {
    std::println("{:.2}", 5);
}

fn hex_float() -> void {
    std::println("{:x}", 1.5);
}

fn not_a_writer() -> void {
    var w: nowriter = {};
    std::write(&w, "{}", 1);
}

fn not_a_reference() -> void {
    var s: std::string = {};
    std::write(s, "{}", 1);
}

fn main() -> void {}
// error: unknown format type 'q' (x, X, b, o, e, E or c)
// error: a format spec needs a number, bool, character or text, not point
// error: precision applies to floats and text, not i32
// error: {:x} formats integers, not f64
// error: std::write needs a writer: nowriter doesn't attach write_str(this: nowriter&, s: str) -> void
// error: std::write takes a reference to the writer: std::write(&out, ...)
