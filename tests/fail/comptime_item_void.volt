// a top-level comptime item runs a fn for what it declares: one that returns void

comptime fn gives() -> i32 {
    return 1;
}

comptime gives();

fn main() -> void {}
// error: comptime runs 'gives' for the fns it declares, so it returns void, not i32
