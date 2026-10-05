// a name in a format string has to be in scope
use std::io;
fn main() -> void {
    std::println("{nope}");
}
// error: unknown name 'nope'
