// csv: format n records (an int, a float with two decimals, a quoted string holding a comma) as CSV text, then parse them back field by field and sum them; Zig formats with ArrayList.print and parses with std.fmt.parseInt and parseFloat, a bad line giving an error
const std = @import("std");

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

const names = [8][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel" };

const Record = struct { id: i64, price: f64, name: []const u8 };

/// one line (without its newline) as a record
fn parseRecord(line: []const u8) !Record {
    var fields = std.mem.splitScalar(u8, line, ',');
    const id = try std.fmt.parseInt(i64, fields.first(), 10);
    const price = try std.fmt.parseFloat(f64, fields.next() orelse return error.BadRecord);
    const quoted = fields.rest();
    if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return error.BadRecord;
    return .{ .id = id, .price = price, .name = quoted[1 .. quoted.len - 1] };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: u64 = if (args.next()) |a| try std.fmt.parseInt(u64, a, 10) else 3000000;
    var text: std.ArrayList(u8) = try .initCapacity(gpa, 1 << 16);
    defer text.deinit(gpa);
    for (0..n) |_| {
        const id = @as(i64, @intCast(next() % 2000000001)) - 1000000000;
        const price = @as(f64, @floatFromInt(next() % 10000000)) / 100.0;
        const a = names[next() % 8];
        const b = names[next() % 8];
        try text.print(gpa, "{d},{d:.2},\"{s}, {s}\"\n", .{ id, price, a, b });
    }
    var ids: i64 = 0;
    var cents: i64 = 0;
    var records: u64 = 0;
    var name_bytes: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        const r = parseRecord(line) catch {
            std.debug.print("bad record {d}\n", .{records});
            std.process.exit(1);
        };
        ids += r.id;
        cents += @intFromFloat(r.price * 100.0 + 0.5);
        name_bytes += r.name.len;
        records += 1;
    }
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} bytes, {d} records\n{d} {d} {d}\n", .{ text.items.len, records, ids, cents, name_bytes });
    try w.interface.flush();
}
