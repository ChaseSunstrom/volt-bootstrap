// flags: --pkg plat=tests/pkgs/plat
use std::io;
// the target's keys, set for every package: os, arch and pointer_bits (here: the host, which
// std::process::os() and arch() report the same), and unix (a POSIX system) and hosted (an OS at
// all) from os. target (the --target name) is only set on bare metal

fn os_name() -> str {
    comptime if (@cfg("os", "windows")) {
        return "windows";
    }
    comptime if (@cfg("os", "linux")) {
        return "linux";
    }
    comptime if (@cfg("os", "macos")) {
        return "macos";
    }
    comptime if (@cfg("os", "freebsd")) {
        return "freebsd";
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
    val os = os_name();
    std::println("{} {} {} {}", os == std::process::os(), arch_name() == std::process::arch(), @cfg("pointer_bits", "64"), @cfg("os", "macos") == (os == "macos"));
    std::println("{} {} {} {} {} {}", @cfg("os"), @cfg("arch"), @cfg("nonsense"), @cfg("unix") == (os != "windows"), @cfg("hosted"), @cfg("target"));
    val pkg_os = plat::target_os();
    std::println("{} {} {} {}", os != "other", arch_name() != "other", pkg_os == os || (pkg_os == "elsewhere" && os != "linux" && os != "macos"), plat::keys_set());
}
// expect: true true true true
// expect: true true false true true false
// expect: true true true true
