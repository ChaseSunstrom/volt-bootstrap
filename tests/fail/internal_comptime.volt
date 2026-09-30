// flags: --pkg hidden=tests/pkgs/hidden
// compile-time code checks internal too: a comptime read of an internal global, and a call to an
// internal comptime fn

fn read_global() -> i32 {
    comptime val x = hidden::LIMIT;
    return x;
}

fn call_comptime() -> i32 {
    return hidden::twice(2);
}

fn main() -> void {}
// error: 'LIMIT' is internal to package hidden
// error: 'twice' is internal to package hidden
