// stats.rs: ordinary Rust, nothing written for Volt; main.volt imports this one file as a crate
pub struct Summary {
    pub count: usize,
    pub mean: f64,
}

pub fn summarize(xs: &[f64]) -> Summary {
    let count = xs.len();
    let mean = if count == 0 { 0.0 } else { xs.iter().sum::<f64>() / count as f64 };
    Summary { count, mean }
}

pub fn label(name: &str, n: usize) -> String {
    format!("{name} x{n}")
}

pub fn parse(text: &str) -> Result<i64, std::num::ParseIntError> {
    text.trim().parse()
}
