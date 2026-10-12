// flags: --pkg plat=tests/pkgs/plat
use std::io;
// the target's keys, set for every package: os, arch and pointer_bits (here: the host, 64-bit Linux,
// whose arch std::process::arch() reports the same), and unix (a POSIX system) and hosted (an OS at
// all) from os. target (the --target name) is only set on bare metal

fn os_name() -> str {
    comptime if (@cfg("os", "windows")) {
        return "windows";
    }
    comptime if (@cfg("os", "linux")) {
        return "linux";
    }
    return "other";
}

fn arch_name() -> str {
    comptime if (@cfg("arch", "x86_64")) {
        return "x86_64";
    }
    comptime if (@cfg("arch", "aarch64")) {
        return "aarch64";
    }
    return "other";
}

fn main() -> void {
    std::println("{} {} {} {}", os_name(), arch_name() == std::process::arch(), @cfg("pointer_bits", "64"), @cfg("os", "macos"));
    std::println("{} {} {} {} {} {}", @cfg("os"), @cfg("arch"), @cfg("nonsense"), @cfg("unix"), @cfg("hosted"), @cfg("target"));
    std::println("{} {} {} {}", std::process::os(), arch_name() != "other", plat::target_os(), plat::keys_set());
}
// expect: linux true true false
// expect: true true false true true false
// expect: linux true linux true
