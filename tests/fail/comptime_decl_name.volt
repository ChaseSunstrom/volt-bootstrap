// a worked-out fn name has to be a name

comptime fn spaced() -> void {
    fn ("not a name")() -> void {}
}

comptime spaced();

fn main() -> void {}
// error: 'not a name' isn't a name
