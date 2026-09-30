// flags: --pkg hidden=tests/pkgs/hidden
// another package's internal trait can't be attached (or named) here

struct mine {}

attach hidden::t_secret -> mine {
    fn code(this) -> i32 { return 1; }
}

fn main() -> void {}
// error: 't_secret' is internal to package hidden
