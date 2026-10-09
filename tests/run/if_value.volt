// if as a value: if (c) a else b, else-if chains, the binding forms, narrowing in the arms, the
// type from where the value goes, owned values, and an arm that leaves
use std::io;
use std::text;

fn sign(x: i32) -> str {
    return if (x < 0) "negative" else if (x == 0) "zero" else "positive";
}

fn len_or_zero(s: str?) -> usize {
    return if (val t = s) t.len else 0;
}

error odd { ODD }

fn half(x: i32) -> odd!i32 {
    if (x % 2 != 0) {
        return .ODD;
    }
    return x / 2;
}

fn name_of(i: i32) -> odd!std::string {
    if (i % 2 != 0) {
        return .ODD;
    }
    return std::string::from("even");
}

fn describe(x: i32) -> std::string {
    return if (val h = half(x)) std::fmt::format("half {}", h) else |e| std::fmt::format("{}", e);
}

// the else arm leaves, so the if's value is the then arm's
fn first(xs: i32[..]) -> i32 {
    val x = if (xs.len > 0) xs[0] else return -1;
    return x * 10;
}

// an arm that leaves gives the if no value: the other arm's decides
fn odd_sum(n: i32) -> i32 {
    var total = 0;
    for (i) in 0..n {
        val y = if (i % 2 == 0) continue else if (i > 7) break else i;
        total += y;
    }
    return if (total > 0) total else return -1;
}

<T: type> fn larger(a: T, b: T) -> T {
    return if (b > a) b else a;
}

fn main() -> void {
    std::println("{} {} {}", sign(-3), sign(0), sign(8));
    std::println("{} {}", len_or_zero("four"), len_or_zero(null));
    std::println("{} {}", describe(10).as_str(), describe(7).as_str());
    val xs: i32[] = { 4, 5 };
    std::println("{} {}", first(xs[..]), first(xs[0..0]));
    std::println("{} {}", larger(3, 9), larger(2.5, -1.0));
    // an if value as an arm: the inner if takes the first else
    val nested = if (xs.len > 1) if (xs.len > 5) 1 else 2 else 3;
    std::println("{} {} {}", odd_sum(20), odd_sum(1), nested);
    // the arms take their type from where the value goes
    val small: u8 = if (xs.len > 1) 200 else 7;
    // an optional narrows in the arm as in a statement if
    val maybe: i32? = 21;
    val doubled = if (maybe) maybe * 2 else 0;
    // each arm builds a string; only the taken one is made (and deleted once)
    val s = if (small > 100) std::string::from("big") else std::string::from("small");
    std::println("{} {} {}", small, doubled, s.as_str());
    // an operand: the else arm reaches as far as an expression does
    std::println("{} {}", 1 + if (small > 100) 10 else 20 + 5, if (doubled == 42) "yes" else "no");
    // the select a carry wants
    val base: u32 = 1000000000;
    var x: u32 = 1300000000;
    val carry: u32 = if (x >= base) 1 else 0;
    x = if (x >= base) x - base else x;
    // `if (c) 1 else 0` is c as a number (0 too, and signed)
    val none: u32 = if (x >= base) 1 else 0;
    val wide: i64 = if (x < base) 1 else 0;
    std::println("{} {} {} {}", carry, x, none, wide);
    // the then arm's value decides the type (usize here, not the else's i32 literal); a binding
    // moves an owned value out, and else |e| gets the error
    val name: str? = "volt";
    val len = if (val n = name) n.len else 0;
    val got = if (val t = name_of(2)) t else |e| std::string::from("none");
    val failed = if (val t = name_of(3)) t else |e| std::fmt::format("failed {}", e);
    std::println("{} {} {}", len, got.as_str(), failed.as_str());
    // a var binding; an arm that's a block leaves (a block has no value)
    val w = if (var t = half(8)) t * 3 else 0;
    val y = if (val t = half(9)) t else {
        std::println("{} and 9 is odd", w);
        return;
    };
    std::println("not reached {}", y);
}
// expect: negative zero positive
// expect: 4 0
// expect: half 5 ODD
// expect: 40 -1
// expect: 9 2.5
// expect: 16 -1 2
// expect: 200 42 big
// expect: 11 yes
// expect: 1 300000000 0 1
// expect: 4 even failed ODD
// expect: 12 and 9 is odd
