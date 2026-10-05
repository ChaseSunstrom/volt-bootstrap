// std::platform: what std's OS code shares: the number a constant has on this system, and the C
// library's errno. Internal: fs, time, random, process and net pick their system with @cfg("os").
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace platform {
    extern "C" fn __errno_location() -> i32&; // Linux
    extern "C" fn __error() -> i32&;          // macOS, FreeBSD
    extern "C" fn _errno() -> i32&;           // Windows (the CRT)

    // the number for this system: Linux, macOS, FreeBSD or Windows
    fn by_os(linux: i32, macos: i32, freebsd: i32, windows: i32) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return windows;
        } else if (@cfg("os", "macos")) {
            return macos;
        } else if (@cfg("os", "freebsd")) {
            return freebsd;
        } else {
            return linux;
        }
    }

    // the C library's errno: why its last call failed
    fn errno() -> i32 {
        comptime if (@cfg("os", "windows")) {
            return *_errno();
        } else if (@cfg("os", "linux")) {
            return *__errno_location();
        } else {
            return *__error();
        }
    }

    // errno says a call stopped only because a signal handler ran (EINTR, 4 everywhere): try again
    fn interrupted() -> bool {
        return errno() == 4;
    }
}
