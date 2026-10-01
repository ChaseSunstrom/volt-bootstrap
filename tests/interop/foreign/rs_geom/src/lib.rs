//! A Rust crate a Volt package uses through [foreign]: bolt builds it as a staticlib and writes
//! rs_geom.h from what follows

/// a point, laid out as C does
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[repr(i32)]
pub enum Quadrant {
    First = 1,
    Second,
    Third,
    Fourth,
}

#[no_mangle]
pub extern "C" fn rg_dist(a: Point, b: Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

#[no_mangle]
pub extern "C" fn rg_quadrant(p: &Point) -> Quadrant {
    match (p.x >= 0.0, p.y >= 0.0) {
        (true, true) => Quadrant::First,
        (false, true) => Quadrant::Second,
        (false, false) => Quadrant::Third,
        (true, false) => Quadrant::Fourth,
    }
}

#[no_mangle]
pub extern "C" fn rg_scale(p: *mut Point, k: f64) {
    if let Some(p) = unsafe { p.as_mut() } {
        p.x *= k;
        p.y *= k;
    }
}

/// a Rust String's length, from Volt's text
#[no_mangle]
pub unsafe extern "C" fn rg_count_chars(s: *const u8, len: usize) -> usize {
    let bytes = unsafe { std::slice::from_raw_parts(s, len) };
    std::str::from_utf8(bytes).map(|s| s.chars().count()).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn rg_apply(f: extern "C" fn(i32) -> i32, x: i32) -> i32 {
    f(x)
}

pub fn not_for_c(v: Vec<i32>) -> usize {
    v.len()
}
