// crc32: the table-driven CRC-32 of a pseudo-random buffer, a byte at a time
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 256 << 20;
    var table: [256]u32 = undefined;
    for (&table, 0..) |*t, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        t.* = c;
    }
    const buf = try init.gpa.alloc(u8, n);
    defer init.gpa.free(buf);
    var s: u64 = 1;
    for (buf) |*b| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        b.* = @intCast(s >> 56);
    }
    var crc: u32 = 0xFFFFFFFF;
    for (buf) |b| crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    var out: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out);
    try w.interface.print("{x:0>8}\n", .{crc ^ 0xFFFFFFFF});
    try w.interface.flush();
}
