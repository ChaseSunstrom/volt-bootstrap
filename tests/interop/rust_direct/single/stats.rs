// One Rust file with no Cargo.toml: `use { "single/stats.rs" } as stats;` makes it a crate of its own
mod scale;

pub fn mean(xs: &[f64]) -> f64 {
    if xs.is_empty() {
        return 0.0;
    }
    xs.iter().sum::<f64>() / xs.len() as f64
}

pub fn label(n: i64) -> String {
    format!("n={}", scale::times_ten(n))
}

// rustdoc's own cfg: this one is only in the documentation (bolt builds without it), and the
// real one only in the build (the documentation's stands in for it)
#[cfg(doc)]
pub fn doc_note() -> i32 {
    0
}
#[cfg(doc)]
pub fn scaled(n: i64) -> i64 {
    n
}
#[cfg(not(doc))]
pub fn scaled(n: i64) -> i64 {
    scale::times_ten(n)
}

// the crate re-exported inside itself: walked once
pub mod prelude {
    pub use super::*;
}
