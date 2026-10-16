// the C symbols kinds.zig declares (pub extern "c" fn): Volt links them from this file
const kinds = @import("kinds.zig");

export fn zig_ext_add(a: i32, b: i32) i32 {
    return a + b;
}

export fn zig_ext_total(c: *const kinds.Ctx) i32 {
    return kinds.ctxTotal(c) * 10;
}

pub fn twice(x: i32) i32 {
    return x * 2;
}
