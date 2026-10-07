// strings: build a long text of numbered words, split it on spaces, count and join the long words
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: u64 = if (args.next()) |a| try std.fmt.parseInt(u64, a, 10) else 10000000;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..n) |i| try text.print(gpa, "word{d} ", .{i * 7 % 1000003});
    // split on spaces; join the words longer than 9 bytes with commas
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var words: u64 = 0;
    var long_words: u64 = 0;
    var it = std.mem.tokenizeScalar(u8, text.items, ' ');
    while (it.next()) |w| {
        words += 1;
        if (w.len > 9) {
            if (long_words > 0) try joined.append(gpa, ',');
            try joined.appendSlice(gpa, w);
            long_words += 1;
        }
    }
    var buf: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.print("{d} {d} {d} {d}\n", .{ text.items.len, words, long_words, joined.items.len });
    try out.interface.flush();
}
