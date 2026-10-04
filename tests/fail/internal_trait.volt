// flags: --pkg hidden=tests/pkgs/hidden
// another package's internal trait can't be attached (or named) here

struct mine {}

attach hidden::secret -> mine {
    fn code(this) -> i32 { return 1; }
}

fn main() -> void {}
// error: 'secret' is internal to package hidden
