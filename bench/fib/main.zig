// fib: the naive doubly recursive Fibonacci, which is all function calls
const std = @import("std");

fn fib(n: i32) i64 {
    return if (n < 2) n else fib(n - 1) + fib(n - 2);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(i32, a, 10) else 42;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d}\n", .{fib(n)});
    try w.interface.flush();
}
