// What voltc asks of the system itself, where std has no call for it: a private build directory, a
// file's canonical path, whether input is waiting on stdin, the language server's raw reads and
// writes, whether stderr is a terminal, and the process's id. POSIX's calls on Unix; on Windows the C
// runtime's and kernel32's (64-bit only, where they're plain C calls)

namespace sys {
    extern "C" fn mkdtemp(template: u8*) -> cstr?;
    extern "C" fn realpath(path: cstr, resolved: void*) -> cstr?;
    extern "C" fn read(fd: i32, buf: void*, n: usize) -> isize;
    extern "C" fn write(fd: i32, buf: void*, n: usize) -> isize;
    extern "C" fn isatty(fd: i32) -> i32;
    extern "C" fn getpid() -> i32;
    extern "C" fn poll(fds: pollfd*, n: u64, timeout: i32) -> i32;

    // struct pollfd
    struct pollfd {
        fd: i32;
        events: i16;
        revents: i16;
    }

    namespace win {
        extern "C" fn GetStdHandle(which: u32) -> void*;
        extern "C" fn ReadFile(h: void*, buf: void*, n: u32, got: u32*, overlapped: void*) -> i32;
        extern "C" fn WriteFile(h: void*, buf: void*, n: u32, put: u32*, overlapped: void*) -> i32;
        extern "C" fn PeekNamedPipe(h: void*, buf: void*, size: u32, got: u32*, avail: u32*, left: u32*) -> i32;
        extern "C" fn GetFullPathNameA(path: cstr, size: u32, buf: u8*, file_part: void*) -> u32;
        extern "C" fn CreateDirectoryA(path: cstr, security: void*) -> i32;
        extern "C" fn GetCurrentProcessId() -> u32;
        extern "C" fn _isatty(fd: i32) -> i32;
    }

    // GetStdHandle's names for stdin and stdout: (DWORD)-10 and (DWORD)-11
    fn std_input() -> u32 {
        return 0xfffffff6;
    }
    fn std_output() -> u32 {
        return 0xfffffff5;
    }
}

// path with / between its parts, as voltc writes paths (Windows takes either)
fn forward_slashes(path: str) -> std::string {
    var out: std::string = {};
    for (ch) in path {
        if (ch == '\\') {
            out.push('/');
        } else {
            out.push(ch);
        }
    }
    return out;
}

// c separates a path's parts: / everywhere, \ on Windows too
fn is_path_sep(c: u8) -> bool {
    comptime if (@cfg("os", "windows")) {
        return c == '/' || c == '\\';
    } else {
        return c == '/';
    }
}

// a program's file name: base, with .exe on Windows
fn exe_name(base: str) -> std::string {
    var out = S(base);
    comptime if (@cfg("os", "windows")) {
        out.append(".exe");
    }
    return out;
}

// a new private directory for a build, PREFIX-<something unique>: in /tmp, made 0700 by mkdtemp; on
// Windows in the user's temporary directory (%TEMP%, which only they can read), under a random name
// that nothing has yet. None when it can't be made
fn new_temp_dir(prefix: str) -> std::string? {
    comptime if (@cfg("os", "windows")) {
        var base = S(".");
        val temp = std::process::env("TEMP");
        val tmp = std::process::env("TMP");
        if (temp) {
            base = forward_slashes(temp);
        } else if (tmp) {
            base = forward_slashes(tmp);
        }
        var rng = std::random::os_seeded();
        var tries = 0;
        while (tries < 64) {
            var dir = std::fmt::format("{}/{}-{:x}", base.as_str(), prefix, rng.next_u64());
            if (sys::win::CreateDirectoryA(dir.c_str(), null) != 0) {
                return dir;
            }
            tries += 1;
        }
        return null;
    } else {
        var t = std::fmt::format("/tmp/{}-XXXXXX", prefix);
        t.push(0);
        if (sys::mkdtemp(@cast<u8*>(t.as_str().ptr)) == null) {
            return null;
        }
        return S(t.as_str()[0..t.len() - 1]);
    }
}

// the canonical path of an existing file or directory (links resolved, on Unix; on Windows absolute,
// with / between its parts), or none
fn real_file(path: str) -> std::string? {
    var p = S(path);
    comptime if (@cfg("os", "windows")) {
        var buf: u8[4096];
        val n = sys::win::GetFullPathNameA(p.c_str(), 4096, &buf[0], null);
        if (n == 0 || n >= 4096) {
            return null;
        }
        val full = forward_slashes(@cast<str>(@slice(&buf[0], @cast<usize>(n))));
        if (!std::fs::exists(full.as_str())) {
            return null;
        }
        return full;
    } else {
        val r = sys::realpath(p.c_str(), null) ?? return null;
        val out = S(@cast<str>(@slice(@cast<u8*>(r), strlen(r))));
        free(@cast<void*>(r));
        return out;
    }
}

// is input waiting on stdin (without reading it)? On Windows only a pipe can say, which is what an
// editor gives a language server
fn stdin_ready() -> bool {
    comptime if (@cfg("os", "windows")) {
        var avail: u32 = 0;
        val h = sys::win::GetStdHandle(sys::std_input());
        return sys::win::PeekNamedPipe(h, null, 0, null, &avail, null) != 0 && avail > 0;
    } else {
        var p: sys::pollfd = { fd: 0, events: 1, revents: 0 }; // POLLIN
        return sys::poll(&p, 1, 0) > 0;
    }
}

// up to n bytes of stdin into buf, as they come (no C stdio buffer, and on Windows no text mode's
// \r\n turned into \n): how many, 0 at its end, or -1 (an interrupted read on Unix: try again)
fn read_stdin(buf: u8*, n: usize) -> isize {
    comptime if (@cfg("os", "windows")) {
        var got: u32 = 0;
        // FALSE: the client closed its end (ERROR_BROKEN_PIPE), or it can't be read; either ends it
        if (sys::win::ReadFile(sys::win::GetStdHandle(sys::std_input()), @cast<void*>(buf), @cast<u32>(n), &got, null) == 0) {
            return 0;
        }
        return @cast<isize>(got);
    } else {
        return sys::read(0, @cast<void*>(buf), n);
    }
}

// up to n bytes from buf to stdout, as read_stdin reads: how many went, or -1
fn write_stdout(buf: u8*, n: usize) -> isize {
    comptime if (@cfg("os", "windows")) {
        var put: u32 = 0;
        if (sys::win::WriteFile(sys::win::GetStdHandle(sys::std_output()), @cast<void*>(buf), @cast<u32>(n), &put, null) == 0) {
            return -1;
        }
        return @cast<isize>(put);
    } else {
        return sys::write(1, @cast<void*>(buf), n);
    }
}

// is stderr a terminal (where diagnostics may be coloured)?
fn stderr_is_terminal() -> bool {
    comptime if (@cfg("os", "windows")) {
        return sys::win::_isatty(2) != 0;
    } else {
        return sys::isatty(2) != 0;
    }
}

// this process's id
fn process_id() -> u64 {
    comptime if (@cfg("os", "windows")) {
        return @cast<u64>(sys::win::GetCurrentProcessId());
    } else {
        return @cast<u64>(sys::getpid());
    }
}
