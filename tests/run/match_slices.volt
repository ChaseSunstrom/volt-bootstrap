// slice patterns in match: [] [x] [first, ..rest] [.., last] [a, b, ..] over slices, arrays and str;
// elements are any pattern (x& binds in place), ..rest binds the middle as a slice, and a match over
// a slice is exhaustive when its arms cover every length
use std::io;

fn describe(xs: i32[..]) -> void {
    match (xs) {
        [] => std::println("empty"),
        [x] => std::println("one {}", x),
        [0, ..rest] => std::println("0 then {} more", rest.len),
        [first, .., last] => std::println("{} .. {}", first, last),
    }
}

fn sum(xs: i32[..]) -> i32 {
    match (xs) {
        [] => return 0,
        [x, ..rest] => return x + sum(rest),
    }
}

fn pairs(xs: i32[..]) -> str {
    return match (xs) {
        [a, b, ..] if a == b => "starts with a pair",
        [_, _, ..] => "two or more",
        default => "short",
    };
}

fn bump_first(xs: i32[..]) -> void {
    match (xs) {
        [x&, ..] => { *x += 100; },
        [] => {},
    }
}

fn middle(xs: i32[..]) -> usize {
    match (xs) {
        [_, ..mid, _] => return mid.len,
        default => return 0,
    }
}

// at compile time over an array
comptime fn head_or(xs: i32[3]) -> i32 {
    return match (xs) {
        [0, ..] => -1,
        [h, ..rest] => h * 10 + rest[0],
    };
}

fn main() -> void {
    comptime val hd = head_or({ 4, 5, 6 });
    std::println("comptime {}", hd);
    val none: i32[0] = {};
    val data: i32[] = { 0, 4, 5 };
    val more: i32[] = { 7, 8, 9, 10 };
    describe(none[..]);
    describe(data[0..1]);
    describe(data[..]);
    describe(more[..]);
    std::println("sum {}", sum(more[..]));
    val twins: i32[] = { 3, 3, 1 };
    std::println("{} | {} | {}", pairs(data[1..2]), pairs(more[..]), pairs(twins[..]));
    var m: i32[] = { 1, 2 };
    bump_first(m[..]);
    std::println("{} {}", m[0], middle(more[..]));
    // arrays: their length is known, so one arm can cover them
    val trio: i32[3] = { 1, 2, 3 };
    match (trio) {
        [a, b, c] => std::println("trio {}", a + b + c),
    }
    // str matches its bytes; nested patterns and tuples
    val word = "hey";
    match (word) {
        ['h', ..tail] => std::println("h then {}", tail),
        default => std::println("no h"),
    }
    val kv: (str, i32)[] = { ("a", 1), ("b", 2) };
    match (kv[..]) {
        [("a", n), ..] => std::println("a is {}", n),
        default => std::println("no a"),
    }
}
// expect: comptime 45
// expect: empty
// expect: one 0
// expect: 0 then 2 more
// expect: 7 .. 10
// expect: sum 34
// expect: short | two or more | starts with a pair
// expect: 101 2
// expect: trio 6
// expect: h then ey
// expect: a is 1
