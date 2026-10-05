// a test block takes no attributes: a platform check goes inside it
@attributes([@cfg("os", "linux")])
test "only on linux" {
}
fn main() -> void {}
// error: a test block takes no attributes or generics; for a platform check put comptime if (@cfg(...)) { ... } in it
