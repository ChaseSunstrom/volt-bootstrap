// sudoku: backtracking over hard sudoku puzzles, each solved with its digits relabelled at random in
// every round so the search differs: a bit mask of the digits used per row, column and box, and the
// empty cell with the fewest candidates tried next; the search goes on past the first solution to
// show it's the only one. Prints the puzzles solved, the guesses made and a checksum of the solutions
const std = @import("std");

const PUZZLES = [_]*const [81]u8{
    "4.....8.5.3..........7......2.....6.....8.4......1.......6.3.7.5..2.....1.4......",
    "52...6.........7.13...........4..8..6......5...........418.........3..2...87.....",
    "6.....8.3.4.7.................5.4.7.3..2.....1.6.......2.....5.....8.6......1....",
    "48.3............71.2.......7.5....6....2..8.............1.76...3.....4......5....",
    "....14....3....2...7..........9...3.6.1.............8.2.....1.4....5.6.....7.8...",
    "8..........36......7..9.2...5...7.......457.....1...3...1....68..85...1..9....4..",
    "..53.....8......2..7..1.5..4....53...1..7...6..32...8..6.5....9..4....3......97..",
    "..............3.85..1.2.......5.7.....4...1...9.......5......73..2.1........4...9",
    "1....7.9..3..2...8..96..5....53..9...1..8...26....4...3......1..4......7..7...3..",
    ".2.4.37.........32........4.4.2...7.8...5.........1...5.....9...3.9....7..1..86..",
    "..3......4...8..36..8...1...4..6..73...9..........2..5..4.7..686........7..6..5..",
    "12.3....435....1....4........54..2..6...7.........8.9...31..5.......9.7.....6...8",
    ".......1.4.........2...........5.4.7..8...3....1.9....3..4..2...5.1........8.6...",
};

// the number of bits set in each 9-bit mask
const BITS = blk: {
    var bits: [512]u8 = @splat(0);
    for (1..512) |m| bits[m] = @as(u8, m & 1) + bits[m >> 1];
    break :blk bits;
};

fn boxOf(i: usize) usize {
    return i / 27 * 3 + i % 9 / 3;
}

const Board = struct {
    cell: [81]u8 = @splat(0), // 0 for empty, else 1 to 9
    row: [9]u16 = @splat(0), // bit d - 1: digit d is used
    col: [9]u16 = @splat(0),
    box: [9]u16 = @splat(0),
    first: [81]u8 = @splat(0), // the first solution found
    solutions: u32 = 0,
    guesses: u64 = 0,

    fn set(b: *Board, i: usize, d: u8) void {
        const bit = @as(u16, 1) << @intCast(d - 1);
        b.cell[i] = d;
        b.row[i / 9] |= bit;
        b.col[i % 9] |= bit;
        b.box[boxOf(i)] |= bit;
    }

    fn unset(b: *Board, i: usize, d: u8) void {
        const bit = ~(@as(u16, 1) << @intCast(d - 1));
        b.cell[i] = 0;
        b.row[i / 9] &= bit;
        b.col[i % 9] &= bit;
        b.box[boxOf(i)] &= bit;
    }

    fn search(b: *Board) void {
        var best: ?usize = null;
        var fewest: u8 = 10;
        var options: u16 = 0;
        for (0..81) |i| {
            if (b.cell[i] != 0) continue;
            const free = ~(b.row[i / 9] | b.col[i % 9] | b.box[boxOf(i)]) & 0x1FF;
            if (BITS[free] < fewest) {
                best = i;
                fewest = BITS[free];
                options = free;
                if (fewest <= 1) break;
            }
        }
        const at = best orelse {
            if (b.solutions == 0) b.first = b.cell;
            b.solutions += 1;
            return;
        };
        var d: u8 = 1;
        while (d <= 9 and b.solutions < 2) : (d += 1) {
            if (options & (@as(u16, 1) << @intCast(d - 1)) == 0) continue;
            b.guesses += 1;
            b.set(at, d);
            b.search();
            b.unset(at, d);
        }
    }
};

var x: u64 = 88172645463325252;

fn next() u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return x;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const rounds: usize = if (args.next()) |s| try std.fmt.parseInt(usize, s, 10) else 25;
    var solved: u32 = 0;
    var unique: u32 = 0;
    var guesses: u64 = 0;
    var check: u64 = 14695981039346656037;
    for (0..rounds) |_| {
        for (PUZZLES) |puzzle| {
            // a random relabelling of the digits
            var perm = [10]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
            var d: usize = 9;
            while (d > 1) : (d -= 1) std.mem.swap(u8, &perm[d], &perm[1 + next() % d]);
            var b: Board = .{};
            for (puzzle, 0..) |c, i| {
                if (c != '.') b.set(i, perm[c - '0']);
            }
            b.search();
            guesses += b.guesses;
            if (b.solutions > 0) solved += 1;
            if (b.solutions == 1) unique += 1;
            for (b.first) |c| check = (check ^ c) *% 1099511628211;
        }
    }
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try w.print("{d} puzzles solved, {d} with one solution\n", .{ solved, unique });
    try w.print("{d} guesses, checksum {d}\n", .{ guesses, check });
    try w.flush();
}
