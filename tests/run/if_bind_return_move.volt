// a return inside an if-binding's block moves only on that path: after the if, the value is still
// there (and a loop that only leaves through return keeps what its breaks kept)
use std::io;
fn pick(value: std::string, opt: i32?) -> std::string {
    if (val x = opt) {
        return value;
    }
    return value;
}
fn text(s: str) -> std::string {
    var t: std::string = {};
    t.append(s);
    return t;
}
fn main() -> void {
    std::println(pick(text("a"), 1));
    std::println(pick(text("b"), null));
}
// expect: a
// expect: b
