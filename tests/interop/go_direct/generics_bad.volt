use std::io;
// an instance Go's constraint rejects is an error at the call, with go's reason
use { "geom.go" } as geom;

fn main() -> void {
    val bs: bool[2] = { true, false };
    std::println("{}", geom::Max(bs[..]));
}
