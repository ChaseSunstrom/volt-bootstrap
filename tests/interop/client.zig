// Zig calls the Volt library through voltc bindings --lang zig: errors come back as Error, owned
// text as VoltText (deinit frees it), an export struct is a type with deinit
const std = @import("std");
const m = @import("mathlib.zig");
const print = std.debug.print;

const Sum = struct { total: i32 = 0 };

fn add_up(s: *Sum, x: i32) void {
    s.total += x;
    print(" {d}", .{x});
}

pub fn main() void {
    print("add {d}\n", .{m.ml_add(2, 3)});
    var a = m.vec2{ .x = 1, .y = 2 };
    const b = m.vec2{ .x = 3, .y = 4 };
    print("dot {d}\n", .{m.ml_dot(a, b)});
    m.ml_scale(&a, 2);
    print("scale {d} {d}\n", .{ a.x, a.y });
    print("len {d}\n", .{m.ml_len("hello")});
    print("clash {d}\n", .{m.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14)});
    var tg = m.ml_tags_make();
    const head = .{ tg.from, tg.@"type", tg.self, tg.int };
    tg.int = 5;
    print("tags {d} {d} {d} {d} {d}\n", .{ head[0], head[1], head[2], head[3], m.ml_tags_sum(tg) });
    var bp: i32 = 7;
    var bq: f64 = 2.5;
    m.ml_bump(&bp, &bq);
    print("bump {d} {d}\n", .{ bp, bq });
    print("next {d}\n", .{@intFromEnum(m.ml_next(m.color.GREEN))});
    print("sqrt {d} 1\n", .{m.ml_sqrt(9) catch unreachable});
    if (m.ml_sqrt(-1)) |_| {} else |e| print("error {s}\n", .{if (e == error.NEGATIVE) "negative" else "?"});
    const g = m.ml_greet("volt");
    defer g.deinit();
    print("greet {s}\n", .{g.bytes()});
    const rp = m.ml_repeat("ab", 2) catch unreachable;
    defer rp.deinit();
    print("repeat {s}\n", .{rp.bytes()});
    if (m.ml_repeat("ab", -1)) |t| t.deinit() else |e| print("repeat {s}\n", .{if (e == error.NEGATIVE) "negative" else "?"});
    var xs = [_]f64{ 1, 2, 3.5 };
    print("sum {d}\n", .{m.ml_sum(&xs)});
    var ys = [_]i32{ 4, 5, 6 };
    print("find {d} {s}\n", .{ m.ml_find(&ys, 6).?, if (m.ml_find(&ys, 9) == null) "none" else "?" });
    var s = Sum{};
    print("each", .{});
    m.ml_each(&ys, &s, add_up);
    print(" = {d}\n", .{s.total});
    const c = m.counter.new("clicks");
    defer c.deinit();
    _ = c.add(2);
    print("counter {s} {d}\n", .{ c.name(), c.add(3) });
    if (c.take(9)) |_| {} else |e| print("take {s}\n", .{if (e == error.NEGATIVE) "negative" else "?"});
    // structs with text, an array and a struct in them (in, out, in a slice, from a function), one
    // with a pointer, E!T as a parameter (an error union)
    const la = m.ml_label{ .name = m.VoltStr.from("ab"), .sizes = .{ 1, 2, 3 }, .at = .{ .x = 7, .y = 0 } };
    print("label {d}\n", .{m.ml_label_len(la)});
    var lb = m.ml_label_of("ab", 3);
    print("label_of {s} {d} {d} {d} {d}\n", .{ lb.name.slice(), lb.sizes[0], lb.sizes[1], lb.sizes[2], lb.at.x });
    var ls = [_]m.ml_label{ la, lb };
    print("labels {d}\n", .{m.ml_labels_len(&ls)});
    print("holder {d}\n", .{m.ml_holder_k(.{ .p = null, .k = 3 })});
    print("or {d} {d}\n", .{ m.ml_or(4.5, 9.5), m.ml_or(error.NEGATIVE, 9.5) });
    print("ask {d}\n", .{m.ml_ask({}, give_label)});
    m.ml_relabel(&lb, 4);
    print("relabel {s} {d} {d} {d}\n", .{ lb.name.slice(), lb.sizes[0], lb.sizes[1], lb.sizes[2] });
    print("count {d}\n", .{m.ml_labels_count(&[_]m.ml_label{ la, lb })});
    print("note {d}\n", .{m.ml_note_len(.{ .str = m.VoltStr.from("abc"), .c = 1, .k = 3 })});
    print("or_label {d} {d}\n", .{ m.ml_or_label(la), m.ml_or_label(error.NEGATIVE) });
    print("given {d} {d}\n", .{ m.ml_sum_given(3, {}, give_pair), m.ml_area_given({}, give_points) });
    var d00 = [_]i64{ 1, 2 };
    var d01 = [_]i64{3};
    var d10 = [_]i64{4};
    var d0 = [_]m.VoltSlice(i64){ m.VoltSlice(i64).from(&d00), m.VoltSlice(i64).from(&d01) };
    var d1 = [_]m.VoltSlice(i64){m.VoltSlice(i64).from(&d10)};
    var dd = [_]m.VoltSlice(m.VoltSlice(i64)){ m.VoltSlice(m.VoltSlice(i64)).from(&d0), m.VoltSlice(m.VoltSlice(i64)).from(&d1) };
    const deep = m.ml_deep(&dd);
    var w0 = [_]m.VoltStr{ m.VoltStr.from("ab"), m.VoltStr.from("c") };
    var w1 = [_]m.VoltStr{};
    var w2 = [_]m.VoltStr{m.VoltStr.from("def")};
    var ws = [_]m.VoltSlice(m.VoltStr){ m.VoltSlice(m.VoltStr).from(&w0), m.VoltSlice(m.VoltStr).from(&w1), m.VoltSlice(m.VoltStr).from(&w2) };
    print("deep {d} {d} {d} words {d}\n", .{ deep, d00[1], d10[0], m.ml_words(&ws) });
    print("text_given {d} {d}\n", .{ m.ml_text_given({}, give_texts), m.ml_labels_given({}, give_labels) });
    print("turn {d}\n", .{m.ml_turn({}, turn)});
    volt_flip = m.ml_flipper();
    var tr = Turner{};
    print("turner {d} flipped {d}\n", .{ m.ml_turned(&tr), m.ml_flipped(flip) });
    const po = m.ml_pair_of("ab", "cd");
    var shelf = m.ml_shelf{ .labels = .{ give_label({}, 2), .{ .name = m.VoltStr.from("de"), .sizes = .{ 1, 1, 1 }, .at = .{ .x = 0, .y = 0 } } }, .k = 1 };
    const bk = m.ml_labels_back(&shelf.labels);
    print("pair {d} {s} {s} shelf {d} back {d} {s}\n", .{ m.ml_pair_len(.{ .names = .{ m.VoltStr.from("ab"), m.VoltStr.from("cde") }, .n = 1 }), po.names[0].slice(), po.names[1].slice(), m.ml_shelf_len(shelf), bk.len, bk.ptr[0].name.slice() });
}

// callbacks giving a slice (in memory of the client's: Volt reads it before calling again)
var given: [2]i64 = undefined;
var points: [2]m.vec2 = undefined;

fn give_pair(_: void, k: i32) m.VoltSlice(i64) {
    given = .{ k, 10 * @as(i64, k) };
    return m.VoltSlice(i64).from(&given);
}

fn give_points(_: void, k: i32) m.VoltSlice(m.vec2) {
    points = .{ .{ .x = 1.5, .y = @floatFromInt(k) }, .{ .x = 2, .y = 3.25 } };
    return m.VoltSlice(m.vec2).from(&points);
}

// a callback taking and giving an array by value
fn turn(_: void, a: [3]i32) [3]i32 {
    return .{ a[2], a[1], a[0] };
}

// callbacks giving a slice of text and of structs with text
var texts: [2]m.VoltStr = undefined;
var labels: [2]m.ml_label = undefined;

fn give_texts(_: void, _: i32) m.VoltSlice(m.VoltStr) {
    texts = .{ m.VoltStr.from("ab"), m.VoltStr.from("cde") };
    return m.VoltSlice(m.VoltStr).from(&texts);
}

fn give_labels(_: void, k: i32) m.VoltSlice(m.ml_label) {
    labels = .{ give_label({}, k), .{ .name = m.VoltStr.from("de"), .sizes = .{ 1, 1, 1 }, .at = .{ .x = 0, .y = 0 } } };
    return m.VoltSlice(m.ml_label).from(&labels);
}

fn give_label(_: void, k: i32) m.ml_label {
    return .{ .name = m.VoltStr.from("abc"), .sizes = .{ k, k, k }, .at = .{ .x = 3, .y = 0 } };
}

const Turner = struct {
    pub fn turn(self: *@This(), a: [3]i32) [3]i32 {
        _ = self;
        return .{ a[2], a[1], a[0] };
    }
};

// an extern "C" fn Volt calls: it calls the one Volt gave out
var volt_flip: ?*const fn (m.VoltArray(i32, 3)) callconv(.c) m.VoltArray(i32, 3) = null;

fn flip(a: m.VoltArray(i32, 3)) callconv(.c) m.VoltArray(i32, 3) {
    return volt_flip.?(a);
}
