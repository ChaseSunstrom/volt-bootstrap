// flags: --leak-check
// a match on a temporary that owns memory deletes it on every way out of an arm: return, break,
// continue, and falling out the bottom
use std::io;

enum shape {
    NAME: std::string,
    NONE,
}

fn make(n: i32) -> shape {
    if (n > 0) {
        return shape::NAME(std::string::from("long enough that the string allocates"));
    }
    return shape::NONE;
}

fn early(n: i32) -> i32 {
    match (make(n)) {
        .NAME(s) => return @cast<i32>(s.len()),
        .NONE => return 0,
    }
}

fn loops() -> i32 {
    var k = 0;
    var i = 0;
    loop {
        i += 1;
        match (make(i % 2)) {
            .NAME(s&) => {
                if (i > 4) {
                    break;
                }
                continue;
            },
            .NONE => {},
        }
        k += 1;
    }
    return k;
}

fn falls(n: i32) -> i32 {
    val v = match (make(n)) {
        .NAME(s&) => 1,
        .NONE => 2,
    };
    return v;
}

fn main() -> i32 {
    std::println("{} {} {} {}", early(1), early(0), loops(), falls(1));
    return 0;
}
// expect: 37 0 2 1
