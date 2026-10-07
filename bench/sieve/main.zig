// sieve: the primes below n with the sieve of Eratosthenes over a byte array
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 200000000;
    const prime = try init.gpa.alloc(bool, n);
    defer init.gpa.free(prime);
    @memset(prime, true);
    prime[0] = false;
    prime[1] = false;
    var i: usize = 2;
    while (i * i < n) : (i += 1) {
        if (prime[i]) {
            var j = i * i;
            while (j < n) : (j += i) prime[j] = false;
        }
    }
    var count: usize = 0;
    var last: usize = 0;
    for (prime, 0..) |p, k| {
        if (p) {
            count += 1;
            last = k;
        }
    }
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} {d}\n", .{ count, last });
    try w.interface.flush();
}
