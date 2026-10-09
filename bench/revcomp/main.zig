// revcomp (the Benchmarks Game): the reverse complement of a 64 MiB DNA sequence in FASTA lines of
// 60 bases, done nine times between two byte buffers; prints the size, the first line and an FNV-1a
// checksum of the result
const std = @import("std");

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

// out gets in's bases from last to first, each complemented, 60 a line
fn revcomp(in: []const u8, out: []u8, comp: *const [256]u8) void {
    var o: usize = 0;
    var col: usize = 0;
    var i = in.len;
    while (i > 0) {
        i -= 1;
        const c = in[i];
        if (c == '\n') continue;
        out[o] = comp[c];
        o += 1;
        col += 1;
        if (col == 60) {
            out[o] = '\n';
            o += 1;
            col = 0;
        }
    }
    if (col > 0) out[o] = '\n';
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 67108864;
    const gpa = init.gpa;
    // each IUPAC code and its complement, upper and lower case
    const from = "ACGTUMRWSYKVHDBNacgtumrwsykvhdbn";
    const to = "TGCAAKYWSRMBDHVNTGCAAKYWSRMBDHVN";
    var comp: [256]u8 = undefined;
    for (&comp, 0..) |*c, i| c.* = @intCast(i);
    for (from, to) |f, t| comp[f] = t;
    // the bases: mostly ACGT, some lower case and other codes
    const alphabet = "ACGTACGTACGTacgtNRYKMSWBDHVnACGT";
    const len = n + (n + 59) / 60;
    var a = try gpa.alloc(u8, len);
    defer gpa.free(a);
    var b = try gpa.alloc(u8, len);
    defer gpa.free(b);
    var p: usize = 0;
    for (0..n) |i| {
        a[p] = alphabet[next() >> 59];
        p += 1;
        if (i % 60 == 59 or i == n - 1) {
            a[p] = '\n';
            p += 1;
        }
    }
    for (0..9) |_| {
        revcomp(a, b, &comp);
        std.mem.swap([]u8, &a, &b);
    }
    var check: u64 = 14695981039346656037;
    for (a) |c| check = (check ^ c) *% 1099511628211;
    const first = if (len < 60) len - 1 else 60;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d} bases, {d} bytes\n{s}\n{d}\n", .{ n, len, a[0..first], check });
    try w.interface.flush();
}
