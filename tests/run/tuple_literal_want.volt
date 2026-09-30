use std::io;
// a tuple literal takes its element types from a tuple wanted inside an optional or error union

error pick_error { NONE }

fn first(xs: u8[..]) -> (u32, usize)? {
    if (xs.len == 0) {
        return null;
    }
    return (xs[0] as u32, 1);
}

fn pair(ok: bool) -> pick_error!(u64, i8) {
    if (!ok) {
        return pick_error::NONE;
    }
    return (7, -1);
}

fn main() -> void {
    val bytes: u8[] = { 65, 66 };
    val p = pair(true) catch (0, 0);
    std::println("{} {} {}", first(bytes[..]), first(bytes[0..0]), p);
}
// expect: (65, 1) null (7, -1)
