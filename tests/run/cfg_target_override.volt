// flags: --pkg plat=tests/pkgs/plat --cfg os=windows --cfg arch=aarch64
use std::io;
// --cfg os=... (or arch, pointer_bits) replaces the host's value for every package, so code for
// another platform can be checked here; the host's own value is then off

fn main() -> void {
    std::println("{} {} {} {}", @cfg("os", "windows"), @cfg("os", "linux"), @cfg("arch", "aarch64"), @cfg("arch", "x86_64"));
    std::println("{} {}", plat::built_for(), @cfg("pointer_bits", "64"));
}
// expect: true false true false
// expect: windows true
