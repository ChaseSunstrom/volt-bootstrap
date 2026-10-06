// a fn is declared inside another only by a comptime fn, when it runs

fn runtime() -> void {
    fn helper() -> void {}
}

fn main() -> void {
    runtime();
}
// error: a fn is declared inside another only by a comptime fn
