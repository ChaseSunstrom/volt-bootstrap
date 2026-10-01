// Zig a Volt package uses through [foreign]: bolt builds it with zig build-lib and writes
// zig_math.h from its export fns and extern structs
pub const Range = extern struct {
    lo: i32,
    hi: i32,
};

export fn zm_clamp(x: i32, r: Range) i32 {
    return @max(r.lo, @min(r.hi, x));
}

export fn zm_sum(xs: [*]const i64, n: usize) i64 {
    var total: i64 = 0;
    for (xs[0..n]) |x| total += x;
    return total;
}

export fn zm_widen(r: *Range, by: i32) void {
    r.lo -= by;
    r.hi += by;
}
