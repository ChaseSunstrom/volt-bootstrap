// std::process: running programs (run, capture), the environment, arguments and exit.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace process {
    // through the runtime (runtime/prelude.h), not a libc header: std is in every program, and a
    // #include there could clash with a user's own extern "C" declarations
    @attributes([@intrinsic("volt_exit")])
    internal fn c_exit(code: i32) -> never;
    @attributes([@intrinsic("volt_rt_argc")])
    internal fn c_argc() -> i32;
    @attributes([@intrinsic("volt_rt_arg")])
    internal fn c_arg(i: i32) -> str;

    // ends the program right away: scopes don't run their deletes or defers
    fn exit(code: i32) -> never {
        c_exit(code);
    }

    // command-line arguments; arg(0) is the program itself
    fn arg_count() -> usize {
        return @cast<usize>(c_argc());
    }

    // argument i (null past the last one)
    fn arg(i: usize) -> str? {
        if (i >= arg_count()) {
            return null;
        }
        return c_arg(@cast<i32>(i));
    }
}

namespace process {
    internal extern "C" fn getenv(name: cstr) -> cstr?;
    internal extern "C" fn strlen(s: cstr) -> usize;
    internal extern "C" fn fork() -> i32;
    internal extern "C" fn execvp(file: cstr, argv: cstr?*) -> i32;
    internal extern "C" fn waitpid(pid: i32, status: i32*, options: i32) -> i32;
    internal extern "C" fn _exit(code: i32) -> never;
    internal extern "C" fn pipe(fds: i32*) -> i32;
    internal extern "C" fn dup2(from: i32, to: i32) -> i32;
    internal extern "C" fn close(fd: i32) -> i32;
    internal extern "C" fn read(fd: i32, buf: void*, n: usize) -> isize;
    internal extern "C" fn write(fd: i32, buf: void*, n: usize) -> isize;
    internal extern "C" fn fcntl(fd: i32, cmd: i32, ...) -> i32;
    internal extern "C" fn signal(sig: i32, handler: void*) -> void*;
    internal extern "C" fn poll(fds: pollfd*, n: u64, timeout: i32) -> i32;
    internal extern "C" fn __errno_location() -> i32&;
    internal extern "C" fn setenv(name: cstr, value: cstr, overwrite: i32) -> i32;
    internal extern "C" fn unsetenv(name: cstr) -> i32;
    internal extern "C" fn getcwd(buf: u8*, size: usize) -> void*;
    internal extern "C" fn chdir(path: cstr) -> i32;

    // poll.h's struct pollfd
    internal struct pollfd {
        fd: i32;
        events: i16;
        revents: i16;
    }

    // a call failed only because a signal handler ran (EINTR): try it again
    fn interrupted() -> bool {
        return *__errno_location() == 4;
    }

    // A pipe that a successful exec closes (close-on-exec): the child writes one byte to it only
    // when exec fails, so the parent can tell "couldn't run it" from a program exiting 127
    internal fn exec_pipe(fds: i32[2]&) -> bool {
        if (pipe(&fds[0]) != 0) {
            return false;
        }
        fcntl(fds[1], 2, 1); // F_SETFD, FD_CLOEXEC
        return true;
    }

    // in the child, after exec failed
    internal fn exec_failed(fds: i32[2]&) -> never {
        var b: u8 = 1;
        write(fds[1], &b, 1);
        _exit(127);
    }

    // in the parent: did the child's exec fail? (reaps the child when it did)
    internal fn exec_error(fds: i32[2]&, pid: i32) -> bool {
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
    internal fn wait_for(pid: i32) -> process_error!i32 {
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
    error process_error {
        SPAWN_FAILED, // not found, not executable, or out of processes
    }

    // an environment variable (valid until the environment changes)
    fn env(name: str) -> str? {
        var n = std::string::from(name);
        val v = getenv(n.c_str()) ?? return null;
        return @cast<str>(@slice(@cast<u8*>(v), strlen(v)));
    }

    // set environment variable name to value, for this process and the programs it starts
    fn set_env(name: str, value: str) -> void {
        var n = std::string::from(name);
        var v = std::string::from(value);
        setenv(n.c_str(), v.c_str(), 1);
    }

    // remove environment variable name
    fn unset_env(name: str) -> void {
        var n = std::string::from(name);
        unsetenv(n.c_str());
    }

    // the working directory (where relative paths start)
    fn cwd() -> std::string {
        var size: usize = 256;
        loop {
            val raw = std::mem::c_malloc(size) ?? @panic("out of memory");
            val buf = @cast<u8*>(raw);
            if (getcwd(buf, size) != null) {
                val out = std::string::from(@cast<str>(@slice(buf, strlen(@cast<cstr>(buf)))));
                std::mem::c_free(raw);
                return move out;
            }
            std::mem::c_free(raw);
            if (*__errno_location() != 34) { // ERANGE: a bigger buffer helps; nothing else does
                @panic("std::process::cwd: the working directory can't be read");
            }
            size *= 2;
        }
    }

    // change the working directory to path
    fn set_cwd(path: str) -> std::fs::fs_error!void {
        var p = std::string::from(path);
        if (chdir(p.c_str()) != 0) {
            return std::fs::from_errno();
        }
    }

    // run a program (found on PATH) and wait for it; its exit code, or 128 + signal
    fn run(argv: str[..]) -> process_error!i32 {
        if (argv.len == 0) {
            return process_error::SPAWN_FAILED;
        }
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
    struct output {
        code: i32;           // exit code, or 128 + signal
        out: std::string;    // its stdout
        err: std::string;    // its stderr
    }

    // run a program (found on PATH) with `input` as its stdin; waits and collects its output
    fn capture(argv: str[..], input: str) -> process_error!output {
        if (argv.len == 0) {
            return process_error::SPAWN_FAILED;
        }
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
        var r: output = { code: 0, out: {}, err: {} };
        pump(inp[1], outp[0], errp[0], input, &r);
        r.code = try wait_for(pid);
        return move r;
    }

    // feed the child its input while collecting its stdout and stderr, all at once: a child
    // blocked writing one pipe never waits on us reading another. Closes the three fds.
    internal fn pump(inp: i32, outp: i32, errp: i32, input: str, r: output&) -> void {
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
    internal fn close_all(a: i32[2]&, b: i32[2]&, c: i32[2]&) -> void {
        close_pipe(a);
        close_pipe(b);
        close_pipe(c);
    }

    internal fn close_pipe(p: i32[2]&) -> void {
        for (fd) in *p {
            if (fd >= 0) {
                close(fd);
            }
        }
    }
}
