// @location(): where it's written, as FILE:LINE:COL; as a parameter's default, where the call is (each
// call its own line), as std::testing's assertions use it
use std::io;

fn here(at: str = @location()) -> str {
    return at;
}

// the file's name without its directory (the harness passes the path either way)
fn base(p: str) -> str {
    var i = p.len;
    while (i > 0 && p[i - 1] != '/' && p[i - 1] != '\\') {
        i -= 1;
    }
    return p[i..p.len];
}

fn main() -> void {
    val own = @location();
    std::println("{}", base(own));
    std::println("{}", base(here()));
    std::println("{}", base(here()));
    std::println("{}", here("given"));
}
// expect: location_builtin.volt:19:15
// expect: location_builtin.volt:21:29
// expect: location_builtin.volt:22:29
// expect: given
