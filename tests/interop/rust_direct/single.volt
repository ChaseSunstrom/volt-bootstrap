use std::io;
// one Rust file, with no Cargo.toml of its own: the .rs makes it Rust, and bolt makes it a crate
use { "single/stats.rs" } as stats;

fn main() -> void {
    val xs: f64[3] = { 1.0, 2.0, 6.0 };
    std::println("{} {} {} {}", stats::mean(xs[..]), stats::label(7), stats::scaled(2), stats::prelude::mean(xs[..]));
}
