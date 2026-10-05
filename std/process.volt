// std::process: running programs (run, capture), the environment, arguments and exit.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace process {
    // through the runtime (runtime/prelude.h), not a libc header: std is in every program, and a
    // #include there could clash with a user's own extern "C" declarations
    @attributes([@intrinsic("volt_exit")])
    fn c_exit(code: i32) -> never;
    @attributes([@intrinsic("volt_rt_argc")])
    fn c_argc() -> i32;
    @attributes([@intrinsic("volt_rt_arg")])
    fn c_arg(i: i32) -> str;
    @attributes([@intrinsic("volt_rt_os")])
    fn c_os() -> str;
    @attributes([@intrinsic("volt_rt_arch")])
    fn c_arch() -> str;

    // the system this program was built for: "linux", "macos", "windows" or "freebsd" (what
    // @cfg("os", ...) tests at compile time)
    public fn os() -> str {
        return c_os();
    }

    // the CPU this program was built for: "x86_64", "aarch64", "riscv64", "x86" or "arm" (what
    // @cfg("arch", ...) tests at compile time)
    public fn arch() -> str {
        return c_arch();
    }

    // ends the program right away: scopes don't run their deletes or defers
    public fn exit(code: i32) -> never {
        c_exit(code);
    }

    // command-line arguments; arg(0) is the program itself
    public fn arg_count() -> usize {
        return @cast<usize>(c_argc());
    }

    // argument i (null past the last one)
    public fn arg(i: usize) -> str? {
        if (i >= arg_count()) {
            return null;
        }
        return c_arg(@cast<i32>(i));
    }
}

namespace process {
    extern "C" fn getenv(name: cstr) -> cstr?;
    extern "C" fn strlen(s: cstr) -> usize;
    extern "C" fn fork() -> i32;
    extern "C" fn execvp(file: cstr, argv: cstr?*) -> i32;
    extern "C" fn waitpid(pid: i32, status: i32*, options: i32) -> i32;
    extern "C" fn _exit(code: i32) -> never;
    extern "C" fn pipe(fds: i32*) -> i32;
    extern "C" fn dup2(from: i32, to: i32) -> i32;
    extern "C" fn close(fd: i32) -> i32;
    extern "C" fn read(fd: i32, buf: void*, n: usize) -> isize;
    extern "C" fn write(fd: i32, buf: void*, n: usize) -> isize;
    extern "C" fn fcntl(fd: i32, cmd: i32, ...) -> i32;
    extern "C" fn signal(sig: i32, handler: void*) -> void*;
    extern "C" fn poll(fds: pollfd*, n: u64, timeout: i32) -> i32;
    extern "C" fn setenv(name: cstr, value: cstr, overwrite: i32) -> i32;
    extern "C" fn unsetenv(name: cstr) -> i32;
    extern "C" fn getcwd(buf: u8*, size: usize) -> void*;
    extern "C" fn readlink(path: cstr, buf: u8*, n: usize) -> isize;
    extern "C" fn realpath(path: cstr, resolved: u8*) -> cstr?;
    extern "C" fn _NSGetExecutablePath(buf: u8*, size: u32*) -> i32;
    extern "C" fn sysctl(name: i32*, n: u32, old: void*, old_len: usize*, new: void*, new_len: usize) -> i32;
    extern "C" fn chdir(path: cstr) -> i32;

    // Windows (64-bit): the CRT for the environment and the working directory, kernel32 for
    // processes and pipes. Handles are isize: INVALID_HANDLE_VALUE is -1
    namespace win {
        extern "C" fn _putenv_s(name: cstr, value: cstr) -> i32;
        extern "C" fn _getcwd(buf: u8*, size: i32) -> void*;
        extern "C" fn _chdir(path: cstr) -> i32;
        extern "C" fn GetModuleFileNameA(module: void*, buf: u8*, size: u32) -> u32;
        extern "C" fn CreateProcessA(app: void*, line: cstr, pa: void*, ta: void*, inherit: i32, flags: u32, env: void*, dir: void*, si: void*, pi: void*) -> i32;
        extern "C" fn WaitForSingleObject(h: isize, ms: u32) -> u32;
        extern "C" fn GetExitCodeProcess(h: isize, code: u32*) -> i32;
        extern "C" fn TerminateProcess(h: isize, code: u32) -> i32;
        extern "C" fn CloseHandle(h: isize) -> i32;
        extern "C" fn CreatePipe(r: isize*, w: isize*, sa: void*, size: u32) -> i32;
        extern "C" fn SetHandleInformation(h: isize, mask: u32, flags: u32) -> i32;
        extern "C" fn GetStdHandle(which: u32) -> isize;
        extern "C" fn GetCurrentProcess() -> isize;
        extern "C" fn DuplicateHandle(from: isize, h: isize, to: isize, out: isize*, access: u32, inherit: i32, options: u32) -> i32;
        extern "C" fn ReadFile(h: isize, buf: void*, n: u32, got: u32*, overlapped: void*) -> i32;
        extern "C" fn WriteFile(h: isize, buf: void*, n: u32, put: u32*, overlapped: void*) -> i32;

        // STARTUPINFOA
        extern struct startup_info {
            cb: u32 = 104; // its size
            reserved: usize = 0;
            desktop: usize = 0;
            title: usize = 0;
            x: u32 = 0;
            y: u32 = 0;
            x_size: u32 = 0;
            y_size: u32 = 0;
            x_chars: u32 = 0;
            y_chars: u32 = 0;
            fill: u32 = 0;
            flags: u32 = 0x100; // STARTF_USESTDHANDLES: the three below
            show_window: u16 = 0;
            reserved2_size: u16 = 0;
            reserved2: usize = 0;
            std_in: isize = 0;
            std_out: isize = 0;
            std_err: isize = 0;
        }

        // PROCESS_INFORMATION
        extern struct process_info {
            process: isize = 0;
            thread: isize = 0;
            pid: u32 = 0;
            tid: u32 = 0;
        }

        // SECURITY_ATTRIBUTES, for handles a child inherits
        extern struct security_attributes {
            size: u32 = 24;
            descriptor: usize = 0;
            inherit: i32 = 1;
        }
    }

    // a child inherits every inheritable handle there is when it starts: the pipes made for one
    // child mustn't be open while another starts (it would hold them, and the first child's reader
    // would wait for that one to exit), so making them and starting the child happen under this lock.
    // ponytail: only std's own spawns take it; STARTUPINFOEX's handle list if other code spawns too
    @attributes([@cfg("os", "windows")])
    var spawn_lock: i32 = 0;

    // poll.h's struct pollfd
    struct pollfd {
        fd: i32;
        events: i16;
        revents: i16;
    }

    // a call failed only because a signal handler ran (EINTR): try it again
    public fn interrupted() -> bool {
        return platform::interrupted();
    }

    // A pipe that a successful exec closes (close-on-exec): the child writes one byte to it only
    // when exec fails, so the parent can tell "couldn't run it" from a program exiting 127
    @attributes([@cfg("unix")])
    fn exec_pipe(fds: i32[2]&) -> bool {
        if (pipe(&fds[0]) != 0) {
            return false;
        }
        fcntl(fds[1], 2, 1); // F_SETFD, FD_CLOEXEC
        return true;
    }

    // in the child, after exec failed
    @attributes([@cfg("unix")])
    fn exec_failed(fds: i32[2]&) -> never {
        var b: u8 = 1;
        write(fds[1], &b, 1);
        _exit(127);
    }

    // in the parent: did the child's exec fail? (reaps the child when it did)
    @attributes([@cfg("unix")])
    fn exec_error(fds: i32[2]&, pid: i32) -> bool {
        close(fds[1]);
        var b: u8 = 0;
        var n = read(fds[0], &b, 1);
        while (n < 0 && interrupted()) {
            n = read(fds[0], &b, 1);
        }
        close(fds[0]);
        if (n > 0) {
            wait_for(pid) catch |e| 0;
            return true;
        }
        return false;
    }

    // wait for a child; its exit code, or 128 + the signal that killed it
    @attributes([@cfg("unix")])
    fn wait_for(pid: i32) -> process_error!i32 {
        var status: i32 = 0;
        while (waitpid(pid, &status, 0) < 0) {
            if (!interrupted()) {
                return process_error::SPAWN_FAILED;
            }
        }
        if ((status & 127) == 0) {
            return (status >> 8) & 255;
        }
        return 128 + (status & 127);
    }

    // why a program couldn't be run
    public error process_error {
        SPAWN_FAILED, // not found, not executable, or out of processes
    }

    // an environment variable (valid until the environment changes)
    public fn env(name: str) -> str? {
        var n = std::string::from(name);
        val v = getenv(n.c_str()) ?? return null;
        return @cast<str>(@slice(@cast<u8*>(v), strlen(v)));
    }

    // set environment variable name to value, for this process and the programs it starts
    public fn set_env(name: str, value: str) -> void {
        var n = std::string::from(name);
        var v = std::string::from(value);
        comptime if (@cfg("os", "windows")) {
            win::_putenv_s(n.c_str(), v.c_str());
        } else {
            setenv(n.c_str(), v.c_str(), 1);
        }
    }

    // remove environment variable name
    public fn unset_env(name: str) -> void {
        var n = std::string::from(name);
        comptime if (@cfg("os", "windows")) {
            win::_putenv_s(n.c_str(), ""); // an empty value removes it
        } else {
            unsetenv(n.c_str());
        }
    }

    // the path of this program's executable, with symlinks resolved (null if the system won't say;
    // Linux, macOS, FreeBSD and Windows do)
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn exe_path(allocator: A = {}) -> std::string<A>? {
        var buf: u8[4096];
        comptime if (@cfg("os", "macos")) {
            // the path it was started by, which may go through symlinks
            var size: u32 = 4096;
            if (_NSGetExecutablePath(&buf[0], &size) != 0) {
                return null;
            }
            var real: u8[4096];
            val r = realpath(@cast<cstr>(&buf[0]), &real[0]) ?? return null;
            return std::string::from(@cast<str>(@slice(@cast<u8*>(r), strlen(r))), copy allocator);
        } else if (@cfg("os", "freebsd")) {
            var mib: i32[4] = { 1, 14, 12, -1 }; // CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, this process
            var n: usize = 4096;
            if (sysctl(&mib[0], 4, @cast<void*>(&buf[0]), &n, @cast<void*>(0), 0) != 0 || n == 0) {
                return null;
            }
            return std::string::from(@cast<str>(@slice(&buf[0], n - 1)), copy allocator); // n counts the NUL
        } else if (@cfg("os", "windows")) {
            val n = win::GetModuleFileNameA(@cast<void*>(0), &buf[0], 4096);
            if (n == 0 || n >= 4096) {
                return null; // failed, or cut short
            }
            return std::string::from(@cast<str>(@slice(&buf[0], @cast<usize>(n))), copy allocator);
        } else {
            val n = readlink("/proc/self/exe", &buf[0], 4096);
            if (n <= 0 || n == 4096) {
                return null;
            }
            return std::string::from(@cast<str>(@slice(&buf[0], @cast<usize>(n))), copy allocator);
        }
    }

    // the working directory (where relative paths start)
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn cwd(allocator: A = {}) -> std::string<A> {
        var size: usize = 256;
        loop {
            val buf: u8* = allocator.malloc<u8>(size) catch @panic("out of memory");
            var got = false;
            comptime if (@cfg("os", "windows")) {
                got = win::_getcwd(buf, @cast<i32>(size)) != null;
            } else {
                got = getcwd(buf, size) != null;
            }
            if (got) {
                val out = std::string::from(@cast<str>(@slice(buf, strlen(@cast<cstr>(buf)))), copy allocator);
                allocator.free<u8>(buf, size);
                return out;
            }
            allocator.free<u8>(buf, size);
            if (platform::errno() != 34) { // ERANGE: a bigger buffer helps; nothing else does
                @panic("std::process::cwd: the working directory can't be read");
            }
            size *= 2;
        }
    }

    // change the working directory to path
    public fn set_cwd(path: str) -> std::fs::fs_error!void {
        var p = std::string::from(path);
        comptime if (@cfg("os", "windows")) {
            if (win::_chdir(p.c_str()) != 0) {
                return std::fs::from_errno();
            }
        } else {
            if (chdir(p.c_str()) != 0) {
                return std::fs::from_errno();
            }
        }
    }

    // run a program (found on PATH) and wait for it; its exit code, or 128 + signal
    public fn run(argv: str[..]) -> process_error!i32 {
        if (argv.len == 0) {
            return process_error::SPAWN_FAILED;
        }
        comptime if (@cfg("os", "windows")) {
            return run_windows(argv);
        } else if (@cfg("unix")) {
            return run_posix(argv);
        } else {
            return process_error::SPAWN_FAILED; // no OS: no programs to run
        }
    }

    // run, through fork and exec
    @attributes([@cfg("unix")])
    fn run_posix(argv: str[..]) -> process_error!i32 {
        var owned: std::vec<std::string> = {};
        for (a) in argv {
            owned.push(std::string::from(a)) catch @panic("out of memory");
        }
        var ptrs: std::vec<cstr?> = {};
        for (s&) in owned.items() {
            ptrs.push(s.c_str()) catch @panic("out of memory");
        }
        ptrs.push(null) catch @panic("out of memory");
        var ep: i32[2] = { -1, -1 };
        if (!exec_pipe(&ep)) {
            return process_error::SPAWN_FAILED;
        }
        val pid = fork();
        if (pid < 0) {
            close(ep[0]);
            close(ep[1]);
            return process_error::SPAWN_FAILED;
        }
        if (pid == 0) {
            close(ep[0]); // the program only inherits stdin/out/err
            execvp(owned.at(0).c_str(), ptrs.ptr);
            exec_failed(&ep); // the child stops here
        }
        if (exec_error(&ep, pid)) {
            return process_error::SPAWN_FAILED;
        }
        return wait_for(pid);
    }

    // what a program printed, and how it ended
    <A: std::mem::allocator = std::mem::default_allocator>
    public struct output {
        code: i32;           // exit code, or 128 + signal
        out: std::string<A>; // its stdout
        err: std::string<A>; // its stderr
    }

    // run a program (found on PATH) with `input` as its stdin; waits and collects its output, in
    // memory from allocator
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn capture(argv: str[..], input: str, allocator: A = {}) -> process_error!output<A> {
        if (argv.len == 0) {
            return process_error::SPAWN_FAILED;
        }
        comptime if (@cfg("os", "windows")) {
            return capture_windows(argv, input, move allocator);
        } else if (@cfg("unix")) {
            return capture_posix(argv, input, move allocator);
        } else {
            return process_error::SPAWN_FAILED; // no OS: no programs to run
        }
    }

    // capture, through fork and exec
    <A: std::mem::allocator>
    fn capture_posix(argv: str[..], input: str, allocator: A) -> process_error!output<A> {
        var owned: std::vec<std::string> = {};
        for (a) in argv {
            owned.push(std::string::from(a)) catch @panic("out of memory");
        }
        var ptrs: std::vec<cstr?> = {};
        for (s&) in owned.items() {
            ptrs.push(s.c_str()) catch @panic("out of memory");
        }
        ptrs.push(null) catch @panic("out of memory");
        var inp: i32[2] = { -1, -1 };
        var outp: i32[2] = { -1, -1 };
        var errp: i32[2] = { -1, -1 };
        var ep: i32[2] = { -1, -1 };
        if (pipe(&inp[0]) != 0 || pipe(&outp[0]) != 0 || pipe(&errp[0]) != 0 || !exec_pipe(&ep)) {
            close_all(&inp, &outp, &errp);
            close_pipe(&ep);
            return process_error::SPAWN_FAILED;
        }
        val pid = fork();
        if (pid < 0) {
            close_all(&inp, &outp, &errp);
            close_pipe(&ep);
            return process_error::SPAWN_FAILED;
        }
        // the child: the pipes become its stdin, stdout and stderr
        if (pid == 0) {
            dup2(inp[0], 0);
            dup2(outp[1], 1);
            dup2(errp[1], 2);
            close_all(&inp, &outp, &errp);
            close(ep[0]);
            execvp(owned.at(0).c_str(), ptrs.ptr);
            exec_failed(&ep); // the child stops here
        }
        // the parent keeps the other ends
        close(inp[0]);
        close(outp[1]);
        close(errp[1]);
        if (exec_error(&ep, pid)) {
            close(inp[1]);
            close(outp[0]);
            close(errp[0]);
            return process_error::SPAWN_FAILED;
        }
        var r: output<A> = { code: 0, out: std::string::new_in(copy allocator), err: std::string::new_in(move allocator) };
        pump(inp[1], outp[0], errp[0], input, &r);
        r.code = try wait_for(pid);
        return r;
    }

    // feed the child its input while collecting its stdout and stderr, all at once: a child
    // blocked writing one pipe never waits on us reading another. Closes the three fds.
    <A: std::mem::allocator>
    fn pump(inp: i32, outp: i32, errp: i32, input: str, r: output<A>&) -> void {
        var fds: pollfd[3];
        fds[0] = { fd: inp, events: 4, revents: 0 }; // POLLOUT
        fds[1] = { fd: outp, events: 1, revents: 0 }; // POLLIN
        fds[2] = { fd: errp, events: 1, revents: 0 };
        if (input.len == 0) {
            close(inp);
            fds[0].fd = -1; // poll skips negative fds
        }
        // a child that exits without reading its input mustn't take us down with SIGPIPE; the
        // disposition is process-wide, so it's ignored only while this runs and then restored
        val old = signal(13, @cast<void*>(@cast<usize>(1))); // SIGPIPE, SIG_IGN
        var sent: usize = 0;
        var buf: u8[4096];
        while (fds[0].fd >= 0 || fds[1].fd >= 0 || fds[2].fd >= 0) {
            if (poll(&fds[0], 3, -1) < 0) {
                if (interrupted()) {
                    continue;
                }
                break;
            }
            if (fds[0].revents != 0) {
                // no POLLOUT: POLLERR or POLLHUP, the child closed its stdin
                var done = (fds[0].revents & 4) == 0;
                if (!done) {
                    // POLLOUT promises room for a page: a write that size won't block
                    var len = input.len - sent;
                    if (len > 4096) {
                        len = 4096;
                    }
                    val n = write(inp, @cast<void*>(input.ptr + sent), len);
                    if (n > 0) {
                        sent += @cast<usize>(n);
                    } else if (!interrupted()) {
                        done = true;
                    }
                }
                if (done || sent == input.len) {
                    close(inp);
                    fds[0].fd = -1;
                }
            }
            for (i) in 1..3 {
                if (fds[i].fd < 0 || fds[i].revents == 0) {
                    continue;
                }
                val n = read(fds[i].fd, &buf, 4096);
                if (n > 0) {
                    val got = @cast<str>(@slice(&buf[0], @cast<usize>(n)));
                    if (i == 1) {
                        r.out.append(got);
                    } else {
                        r.err.append(got);
                    }
                } else if (n == 0 || !interrupted()) {
                    close(fds[i].fd);
                    fds[i].fd = -1;
                }
            }
        }
        for (f&) in fds {
            if (f.fd >= 0) {
                close(f.fd);
            }
        }
        signal(13, old);
    }

    // close the ends of these pipes that were opened (-1 marks one that wasn't)
    @attributes([@cfg("unix")])
    fn close_all(a: i32[2]&, b: i32[2]&, c: i32[2]&) -> void {
        close_pipe(a);
        close_pipe(b);
        close_pipe(c);
    }

    @attributes([@cfg("unix")])
    fn close_pipe(p: i32[2]&) -> void {
        for (fd) in *p {
            if (fd >= 0) {
                close(fd);
            }
        }
    }

    // argv as one Windows command line, each argument quoted so that the C runtime's parser
    // (CommandLineToArgvW's rules) gives the program back the same arguments
    public fn windows_args(argv: str[..]) -> std::string {
        var out = std::string::from("");
        for (a, i) in argv {
            if (i > 0) {
                out.push(' ');
            }
            var plain = a.len > 0;
            for (c) in a {
                if (c == ' ' || c == '\t' || c == '\n' || c == 11 || c == '"') {
                    plain = false;
                }
            }
            if (plain) {
                out.append(a);
                continue;
            }
            // backslashes are literal, but for those before a quote: each one doubles, and one more
            // escapes the quote itself
            out.push('"');
            var slashes: usize = 0;
            for (c) in a {
                if (c == '\\') {
                    slashes += 1;
                    continue;
                }
                if (c == '"') {
                    slashes = slashes * 2 + 1;
                }
                for (k) in 0..slashes {
                    out.push('\\');
                }
                slashes = 0;
                out.push(c);
            }
            for (k) in 0..slashes * 2 {
                out.push('\\'); // before the closing quote
            }
            out.push('"');
        }
        return out;
    }

    // Windows: start argv (CreateProcessA searches PATH) with these as its stdin, stdout and stderr
    // (inheritable handles); the process's handle, or 0. Under spawn_lock
    @attributes([@cfg("os", "windows")])
    fn win_start(argv: str[..], std_in: isize, std_out: isize, std_err: isize) -> isize {
        // a .bat or .cmd runs through cmd.exe, which reads the line by its own rules, not the ones
        // windows_args quotes for (an argument could become a command): refused. Windows drops a
        // name's trailing dots and spaces, so "x.bat." is one too
        var prog = argv[0];
        while (prog.len > 0 && (prog[prog.len - 1] == '.' || prog[prog.len - 1] == ' ')) {
            prog = prog[0..prog.len - 1];
        }
        if (prog.len >= 4) {
            val ext = prog[prog.len - 4..prog.len];
            if (ext.eq_ignore_case(".bat") || ext.eq_ignore_case(".cmd")) {
                return 0;
            }
        }
        var line = windows_args(argv);
        var si: win::startup_info = { std_in: std_in, std_out: std_out, std_err: std_err };
        var pi: win::process_info = {};
        val none = @cast<void*>(0);
        if (win::CreateProcessA(none, line.c_str(), none, none, 1, 0, none, none, @cast<void*>(&si), @cast<void*>(&pi)) == 0) {
            return 0;
        }
        win::CloseHandle(pi.thread);
        return pi.process;
    }

    // wait for a process and close its handle: its exit code
    @attributes([@cfg("os", "windows")])
    fn win_wait(h: isize) -> i32 {
        win::WaitForSingleObject(h, 0xffffffff); // INFINITE
        var code: u32 = 0;
        win::GetExitCodeProcess(h, &code);
        win::CloseHandle(h);
        return @cast<i32>(code);
    }

    // an inheritable copy of this process's stdin, stdout or stderr (0 when it has none)
    @attributes([@cfg("os", "windows")])
    fn win_inheritable(which: u32) -> isize {
        val h = win::GetStdHandle(which);
        var copy_of: isize = 0;
        if (h == 0 || h == -1) {
            return 0;
        }
        val me = win::GetCurrentProcess();
        if (win::DuplicateHandle(me, h, me, &copy_of, 0, 1, 2) == 0) { // DUPLICATE_SAME_ACCESS
            return 0;
        }
        return copy_of;
    }

    @attributes([@cfg("os", "windows")])
    fn win_close(h: isize) -> void {
        if (h != 0 && h != -1) {
            win::CloseHandle(h);
        }
    }

    // run, through CreateProcessA: the child gets this program's stdin, stdout and stderr
    @attributes([@cfg("os", "windows")])
    fn run_windows(argv: str[..]) -> process_error!i32 {
        std::thread::lock_word(&spawn_lock);
        val i = win_inheritable(0xfffffff6); // STD_INPUT_HANDLE
        val o = win_inheritable(0xfffffff5); // STD_OUTPUT_HANDLE
        val e = win_inheritable(0xfffffff4); // STD_ERROR_HANDLE
        val h = win_start(argv, i, o, e);
        win_close(i);
        win_close(o);
        win_close(e);
        std::thread::unlock_word(&spawn_lock);
        if (h == 0) {
            return process_error::SPAWN_FAILED;
        }
        return win_wait(h);
    }

    // write input to the child's stdin, then close it (on a thread of its own)
    @attributes([@cfg("os", "windows")])
    fn win_feed(h: isize, input: str) -> void {
        var sent: usize = 0;
        while (sent < input.len) {
            var n = input.len - sent;
            if (n > 65536) {
                n = 65536;
            }
            var put: u32 = 0;
            if (win::WriteFile(h, @cast<void*>(input.ptr + sent), @cast<u32>(n), &put, @cast<void*>(0)) == 0) {
                break; // the child closed its stdin
            }
            sent += @cast<usize>(put);
        }
        win::CloseHandle(h);
    }

    // read a pipe to its end (the child closed its side), then close it
    <A: std::mem::allocator>
    fn win_drain(h: isize, into: std::string<A>&) -> void {
        var buf: u8[4096];
        loop {
            var got: u32 = 0;
            if (win::ReadFile(h, @cast<void*>(&buf[0]), 4096, &got, @cast<void*>(0)) == 0 || got == 0) {
                break;
            }
            into.append(@cast<str>(@slice(&buf[0], @cast<usize>(got))));
        }
        win::CloseHandle(h);
    }

    // a thread that couldn't start: close the handle it would have, and say so
    @attributes([@cfg("os", "windows")])
    fn not_started(h: isize, started: bool&) -> std::thread::thread {
        win::CloseHandle(h);
        *started = false;
        return {};
    }

    // capture, through CreateProcessA and three pipes. Windows can't poll pipes: one thread feeds
    // the input and another reads stderr while this one reads stdout, so the child never waits on
    // us. The stderr thread collects into its own string (allocator may not be safe across threads)
    <A: std::mem::allocator>
    fn capture_windows(argv: str[..], input: str, allocator: A) -> process_error!output<A> {
        // ends: the child's stdin (read, write), stdout (read, write), stderr (read, write)
        var ends: isize[6] = { 0, 0, 0, 0, 0, 0 };
        var sa: win::security_attributes = {};
        std::thread::lock_word(&spawn_lock);
        var h: isize = 0;
        if (win::CreatePipe(&ends[0], &ends[1], @cast<void*>(&sa), 0) != 0 && win::CreatePipe(&ends[2], &ends[3], @cast<void*>(&sa), 0) != 0 && win::CreatePipe(&ends[4], &ends[5], @cast<void*>(&sa), 0) != 0) {
            // our ends stay here
            win::SetHandleInformation(ends[1], 1, 0); // HANDLE_FLAG_INHERIT
            win::SetHandleInformation(ends[2], 1, 0);
            win::SetHandleInformation(ends[4], 1, 0);
            h = win_start(argv, ends[0], ends[3], ends[5]);
        }
        // the child has its own copies of its ends
        win_close(ends[0]);
        win_close(ends[3]);
        win_close(ends[5]);
        std::thread::unlock_word(&spawn_lock);
        if (h == 0) {
            win_close(ends[1]);
            win_close(ends[2]);
            win_close(ends[4]);
            return process_error::SPAWN_FAILED;
        }
        var r: output<A> = { code: 0, out: std::string::new_in(copy allocator), err: std::string::new_in(move allocator) };
        var errs = std::string::from("");
        {
            val inp = ends[1];
            val errp = ends[4];
            var feeder: std::thread::thread = {};
            var reader: std::thread::thread = {};
            var started = true;
            if (input.len == 0) {
                win::CloseHandle(inp);
            } else {
                feeder = std::thread::spawn(|inp, input| () {
                    win_feed(inp, input);
                }) catch |x| not_started(inp, &started);
            }
            if (started) {
                reader = std::thread::spawn(|errp, errs&| () {
                    win_drain(errp, &errs);
                }) catch |x| not_started(errp, &started);
            } else {
                win::CloseHandle(errp);
            }
            if (!started) {
                // no thread for it: stop the child, so the one that did start finishes
                win::TerminateProcess(h, 1);
                win::CloseHandle(ends[2]);
                win_wait(h);
                return process_error::SPAWN_FAILED;
            }
            win_drain(ends[2], &r.out);
        } // the threads are joined here
        r.err.append(errs.as_str());
        r.code = win_wait(h);
        return r;
    }
}
