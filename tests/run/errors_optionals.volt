use std::io;

error parse_error { EMPTY, BAD_DIGIT, }
error io_error { CLOSED }

fn parse(s: str) -> parse_error!i32 {
    if (s.len == 0) { return parse_error::EMPTY; }
    var n = 0;
    for (ch) in s {
        if (ch < '0' || ch > '9') { return .BAD_DIGIT; }
        n = n * 10 + (ch - '0') as i32;
    }
    return n;
}

fn double(s: str) -> !i32 {
    defer std::println("  double done");
    errdefer std::println("  double failed");
    val n = try parse(s);
    return n * 2;
}

fn check(flag: bool) -> io_error!void {
    if (flag) { return io_error::CLOSED; }
}

fn find(xs: i32[..], want: i32) -> usize? {
    for (x, i) in xs {
        if (x == want) { return i; }
    }
    return null;
}

fn main() -> !i32 {
    std::println(parse("123"));
    std::println(parse(""));
    std::println(parse("12x"));
    std::println(double("21"));
    std::println(double("?"));
    val fallback = parse("x") catch 7;
    val handled = parse("") catch |e| {
        std::println("caught {}", e);
        return 3;
    };
    std::println("unreached {} {}", fallback, handled);
    return 0;
}
// expect: 123
// expect: error.EMPTY
// expect: error.BAD_DIGIT
// expect:   double done
// expect: 42
// expect:   double failed
// expect:   double done
// expect: error.BAD_DIGIT
// expect: caught EMPTY
// exit: 3
