// std::process::run_status: how a program ended, its exit code and the signal that ended it (0 if none)
// os: linux macos freebsd
// (Windows has no signals: MSYS's sh -c 'kill -ABRT $$' exits 6 << 8)
use std::io;

fn show(script: str) -> void {
    val args: str[3] = { "sh", "-c", script };
    val s = std::process::run_status(args) catch |e| {
        std::println("spawn failed");
        return;
    };
    std::println("code={} signal={}", s.code, s.signal);
}

fn main() -> i32 {
    show("exit 3");
    show("exit 139");
    show("kill -ABRT $$");
    show("kill -SEGV $$");
    val none: str[1] = { "voltc-surely-not-a-program" };
    val m = std::process::run_status(none) catch |e| {
        std::println("missing: can't run it");
        return 0;
    };
    return 1;
}
// expect: code=3 signal=0
// expect: code=139 signal=0
// expect: code=134 signal=6
// expect: code=139 signal=11
// expect: missing: can't run it
