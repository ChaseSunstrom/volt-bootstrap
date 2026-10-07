// vm_interp: a stack-machine bytecode interpreter counting the primes below n by trial division; Zig's instruction is a tagged union, run by a switch
const std = @import("std");

const Instr = union(enum) {
    push: i64,
    load: usize,
    store: usize,
    add,
    mul,
    mod,
    lt,
    jmp: usize,
    jz: usize,
    jnz: usize,
    halt,
};

fn run(code: []const Instr) i64 {
    var stack: [256]i64 = undefined;
    var locals: [8]i64 = @splat(0);
    var sp: usize = 0;
    var pc: usize = 0;
    while (true) {
        const instr = code[pc];
        pc += 1;
        switch (instr) {
            .push => |v| {
                stack[sp] = v;
                sp += 1;
            },
            .load => |slot| {
                stack[sp] = locals[slot];
                sp += 1;
            },
            .store => |slot| {
                sp -= 1;
                locals[slot] = stack[sp];
            },
            .add => {
                sp -= 1;
                stack[sp - 1] += stack[sp];
            },
            .mul => {
                sp -= 1;
                stack[sp - 1] *= stack[sp];
            },
            .mod => {
                sp -= 1;
                stack[sp - 1] = @rem(stack[sp - 1], stack[sp]);
            },
            .lt => {
                sp -= 1;
                stack[sp - 1] = @intFromBool(stack[sp - 1] < stack[sp]);
            },
            .jmp => |target| pc = target,
            .jz => |target| {
                sp -= 1;
                if (stack[sp] == 0) pc = target;
            },
            .jnz => |target| {
                sp -= 1;
                if (stack[sp] != 0) pc = target;
            },
            .halt => return stack[sp - 1],
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const n: i64 = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 1000000;
    // locals: 0 n, 1 d, 2 count, 3 limit, 4 prime
    const program = [_]Instr{
        .{ .push = n }, .{ .store = 3 },
        .{ .push = 0 }, .{ .store = 2 },
        .{ .push = 2 }, .{ .store = 0 },
        // 6: while n < limit
        .{ .load = 0 }, .{ .load = 3 }, .lt, .{ .jz = 41 },
        .{ .push = 1 }, .{ .store = 4 },
        .{ .push = 2 }, .{ .store = 1 },
        // 14: while !(n < d * d)
        .{ .load = 0 }, .{ .load = 1 }, .{ .load = 1 }, .mul, .lt, .{ .jnz = 32 },
        // 20: if n % d == 0 { prime = 0; break }
        .{ .load = 0 }, .{ .load = 1 }, .mod, .{ .jnz = 27 },
        .{ .push = 0 }, .{ .store = 4 }, .{ .jmp = 32 },
        // 27: d += 1
        .{ .load = 1 }, .{ .push = 1 }, .add, .{ .store = 1 }, .{ .jmp = 14 },
        // 32: count += prime; n += 1
        .{ .load = 2 }, .{ .load = 4 }, .add, .{ .store = 2 },
        .{ .load = 0 }, .{ .push = 1 }, .add, .{ .store = 0 }, .{ .jmp = 6 },
        // 41
        .{ .load = 2 }, .halt,
    };
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.print("{d}\n", .{run(&program)});
    try w.interface.flush();
}
