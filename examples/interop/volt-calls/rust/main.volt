// Volt calling Rust: the use names a .rs file, so bolt reads its public API and builds a small shim
// with cargo; a plain struct comes by value, String as std::string, Result as an error. Run: sh
// run.sh
use std::io;
use { "stats.rs" } as stats;

fn main() -> !void {
    val xs: f64[4] = { 1.0, 2.0, 3.0, 6.0 };
    val s = stats::summarize(xs[..]);
    std::println("count {} mean {}", s.count, s.mean);
    std::println("{}", stats::label("volt", 3));
    std::println("parsed {}", try stats::parse(" 42 "));
    val bad = stats::parse("x");
    std::println("bad {}", bad.err != null);
}
