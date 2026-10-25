use std::io;
// a type that isn't Send (a Canvas holds Box<dyn Shape>) given to a generic Rust fn bound by Send:
// Volt warns at the call (Canvas's handle is @not_send, as rustdoc says), and rustc's error stops it
use { "geom" } as geom;

fn main() -> void {
    val c = geom::Canvas::new();
    std::println("{}", geom::on_thread(c));
}
