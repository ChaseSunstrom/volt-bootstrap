// flags: --pkg plat=tests/pkgs/plat
use std::io;
// the target's keys, set for every package: os, arch and pointer_bits (here: the host, x86-64 Linux)

fn os_name() -> str {
    comptime if (@cfg("os", "windows")) {
        return "windows";
    }
    comptime if (@cfg("os", "linux")) {
        return "linux";
    }
    return "other";
}

fn main() -> void {
    std::println("{} {} {} {}", os_name(), @cfg("arch", "x86_64"), @cfg("pointer_bits", "64"), @cfg("os", "macos"));
    std::println("{} {} {}", @cfg("os"), @cfg("arch"), @cfg("nonsense"));
    std::println("{} {} {} {}", std::process::os(), std::process::arch(), plat::target_os(), plat::keys_set());
}
// expect: linux true true false
// expect: true true false
// expect: linux x86_64 linux true
