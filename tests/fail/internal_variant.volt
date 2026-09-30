// flags: --pkg hidden=tests/pkgs/hidden
// a variant of another package's internal enum names the enum: the error says it's internal

fn pick() -> void {
    val m = hidden::mode::FAST;
}

fn main() -> void {}
// error: 'mode' is internal to package hidden
