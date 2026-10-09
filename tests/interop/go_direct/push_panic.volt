use std::io;
// a Go panic while a Volt callback's slice result goes to Go (here a handle Go never made, from a
// goroutine) stops the program with Go's message
use { "geom.go" } as geom;

fn main() -> void {
    val n = geom::Gather(|| () -> std::vec<geom::Shape> {
        var out: std::vec<geom::Shape> = {};
        out.push({ h: @cast<void*>(12345) }) catch @panic("out of memory");
        return out;
    });
    std::println("{}", n);
}
