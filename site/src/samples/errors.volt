use std::io;

error parse_error { EMPTY, BAD_DIGIT }

// E!T: an error from set E, or a T. No exceptions, no hidden control flow
fn parse(s: str) -> parse_error!i32 {
    if (s.len == 0) {
        return parse_error::EMPTY;
    }
    var n = 0;
    for (ch) in s {
        if (ch < '0' || ch > '9') {
            return parse_error::BAD_DIGIT;
        }
        n = n * 10 + @cast<i32>(ch - '0');
    }
    return n;
}

fn main() -> !void {
    val a = try parse("42");            // try passes an error up
    val b = parse("4x") catch -1;       // catch handles it
    val c: i32? = null;                 // T?: a value, or null
    std::println("{} {} {}", a, b, c ?? 7);
    val d = parse("") catch |e| {
        std::println("failed: {}", e);
        return;                         // leave, or give a value
    };
    std::println("{}", d);
}
// expect: 42 -1 7
// expect: failed: EMPTY
