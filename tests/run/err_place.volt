// flags: --leak-check
// .err on an error union variable is a view of the error in place, like .value: reading and
// comparing it borrows, and keeping it needs an explicit copy. On a temporary it takes the error
// and deletes the value.
use std::io;

error oops {
    MSG: std::string,
    PLAIN,
}

fn f(n: i32) -> oops!std::string {
    if (n > 0) {
        return oops::MSG(std::string::from("long enough to allocate a buffer"));
    }
    return std::string::from("fine, and long enough to allocate too");
}

fn main() -> i32 {
    val r = f(1);
    std::println("{} {}", r.err != null, r.err == null);
    val kept = copy r.err;
    std::println("{}", kept != null);
    std::println("{}", f(0).err == null);
    val gone = f(1).err;
    std::println("{}", gone != null);
    return 0;
}
// expect: true false
// expect: true
// expect: true
// expect: true
