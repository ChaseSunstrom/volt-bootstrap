// voltc run of a program a signal ends says which signal, and exits 128 + its number as the shell does
// os: linux macos freebsd
// (abort on Windows is a fail-fast exit, 0xC0000409)
extern "C" fn abort() -> never;

fn main() -> i32 {
    abort();
}
// exit: 134
// expect-stderr: voltc: the program was ended by SIGABRT (signal 6)
