//! An ordinary Rust library: nothing in it is written for Volt. main.volt next to it calls it
//! with `use rust { "geom" } as geom;`.

pub mod shapes;

pub const LIMIT: i32 = 10;
pub const NAME: &str = "geom";

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub fn new(x: f64, y: f64) -> Point {
        Point { x, y }
    }

    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    pub fn scale(&mut self, k: f64) {
        self.x *= k;
        self.y *= k;
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Color {
    Red,
    Green = 5,
    Blue,
}

impl Color {
    pub fn name(&self) -> &'static str {
        match self {
            Color::Red => "red",
            Color::Green => "green",
            Color::Blue => "blue",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Pixel {
    pub at: Point,
    pub color: Color,
    pub mark: char,
}

pub fn dist(a: Point, b: Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

pub fn greet(who: &str) -> String {
    format!("hello, {who}")
}

pub fn shout(s: String) -> String {
    s.to_uppercase()
}

pub fn first_word(s: &str) -> &str {
    s.split_whitespace().next().unwrap_or("")
}

pub fn sum(xs: &[f64]) -> f64 {
    xs.iter().sum()
}

pub fn double_all(xs: &mut [i32]) {
    for x in xs {
        *x *= 2;
    }
}

pub fn squares(n: u32) -> Vec<u64> {
    (1..=n as u64).map(|i| i * i).collect()
}

pub fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(String::from).collect()
}

pub fn join(parts: &[&str], sep: &str) -> String {
    parts.join(sep)
}

pub fn find(xs: &[i32], x: i32) -> Option<usize> {
    xs.iter().position(|&y| y == x)
}

pub fn nickname(id: u32) -> Option<String> {
    (id == 7).then(|| "lucky".to_string())
}

pub fn or_default(x: Option<i64>) -> i64 {
    x.unwrap_or(-1)
}

pub fn parse_num(s: &str) -> Result<i64, std::num::ParseIntError> {
    s.trim().parse()
}

pub fn checked_div(a: i32, b: i32) -> Result<i32, String> {
    if b == 0 {
        Err(format!("{a} / 0"))
    } else {
        Ok(a / b)
    }
}

pub fn next_color(c: Color) -> Color {
    match c {
        Color::Red => Color::Green,
        Color::Green => Color::Blue,
        Color::Blue => Color::Red,
    }
}

pub fn brighten(p: &mut Pixel) {
    p.color = next_color(p.color);
    p.at.scale(2.0);
}

pub fn initial(c: char) -> char {
    c.to_ascii_uppercase()
}

// not callable from Volt: generic, and a closure
pub fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T {
    let mut m = xs[0];
    for &x in xs {
        if x > m {
            m = x;
        }
    }
    m
}

pub fn apply(f: impl Fn(i32) -> i32, x: i32) -> i32 {
    f(x)
}

/// a module whose name is a Volt keyword: Volt sees it as error_
pub mod error {
    #[derive(Clone, Copy, Debug)]
    pub struct Problem {
        pub code: i32,
    }

    pub fn make(code: i32) -> Problem {
        Problem { code }
    }
}

/// parameters named like the glue's own locals
pub fn clash(o: i32, e: i32, a0: i32) -> i32 {
    o * 100 + e * 10 + a0
}

/// can't be built or matched outside this crate: Volt holds it as a handle
#[non_exhaustive]
pub struct Settings {
    pub level: i32,
}

impl Settings {
    pub fn new(level: i32) -> Settings {
        Settings { level }
    }

    pub fn level(&self) -> i32 {
        self.level
    }
}

#[non_exhaustive]
#[derive(Clone, Copy, Debug)]
pub enum Mode {
    Fast,
    Slow,
}

pub fn mode_name(m: Mode) -> String {
    format!("{m:?}")
}

// what only rustdoc sees: a fn a macro makes, the branch of a #[cfg] that holds, an item re-exported
// under another name from a private module, a glob re-export, and consts rustc works out
macro_rules! constant_fn {
    ($name:ident, $v:expr) => {
        pub fn $name() -> i32 {
            $v
        }
    };
}
constant_fn!(answer, 42);

#[cfg(target_pointer_width = "64")]
pub fn word_bits() -> u32 {
    64
}
#[cfg(not(target_pointer_width = "64"))]
pub fn word_bits() -> u32 {
    32
}

mod hidden {
    pub fn twice(x: i32) -> i32 {
        x * 2
    }
    pub struct Pair {
        pub a: i32,
        pub b: i32,
    }
}
pub use hidden::twice as doubled;
pub use hidden::Pair;

pub mod extra {
    pub fn plus_one(x: i32) -> i32 {
        x + 1
    }
}
pub use extra::*;

pub fn pair_sum(p: Pair) -> i32 {
    p.a + p.b
}

pub const AREA: u32 = (LIMIT * LIMIT) as u32;
pub const RATIO: f64 = 1.0 / 4.0;
pub const BIG: bool = AREA > 50;
