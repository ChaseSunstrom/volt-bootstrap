// @derive attaches traits to a struct or an enum, nothing else
@attributes([@derive(eq)])
fn f() -> void {}

fn main() -> void {}
// error: @derive goes on a struct or an enum
