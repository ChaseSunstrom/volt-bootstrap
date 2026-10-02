// Volt calling Zig: the use names a .zig file, so bolt reads its public API and builds a small shim
// with zig build-lib; a struct comes by value with its methods, an error union as an error. Run: sh
// run.sh
use std::io;
use { "stats.zig" } as stats;

fn main() -> !void {
    val p: stats::Point = { x: 3.0, y: 4.0 };
    std::println("norm {}", p.norm());
    val xs: f64[3] = { 1.0, 2.0, 6.0 };
    std::println("mean {}", stats::mean(xs[..]));
    std::println("divide {}", try stats::divide(7, 2));
    std::println("by zero {}", stats::divide(1, 0).err);
}
