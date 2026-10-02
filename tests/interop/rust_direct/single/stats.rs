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
