// std::net: the network: names (resolve), TCP (listen, connect, streams) and UDP, with timeouts.
// One file for every system: the socket calls, constants, struct layouts and error numbers that
// differ are picked with @cfg("os") (Linux, macOS, FreeBSD and Windows, 64-bit), so a program builds
// unchanged on each.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace net {
    // why a network call failed
    error net_error {
        NOT_FOUND,   // the name doesn't resolve (or isn't a name at all)
        REFUSED,     // nothing listens there
        TIMED_OUT,   // the timeout passed first
        IN_USE,      // the address is taken
        RESET,       // the other side closed the connection
        UNREACHABLE, // no route to the network or the host
        IO,          // anything else
    }

    // an IP address and a port: ip holds 4 bytes for IPv4 (the rest zero), 16 for IPv6
    struct address {
        ip: u8[16];
        v6: bool;
        port: u16;
    }

    // ---------- the system's calls ----------

    // Linux, macOS and FreeBSD: a socket is an int, the error is in errno
    namespace posix {
        internal extern "C" fn socket(family: i32, kind: i32, protocol: i32) -> i32;
        internal extern "C" fn connect(fd: i32, addr: void*, len: u32) -> i32;
        internal extern "C" fn bind(fd: i32, addr: void*, len: u32) -> i32;
        internal extern "C" fn listen(fd: i32, backlog: i32) -> i32;
        internal extern "C" fn accept(fd: i32, addr: void*, len: u32*) -> i32;
        internal extern "C" fn send(fd: i32, buf: void*, n: usize, flags: i32) -> isize;
        internal extern "C" fn recv(fd: i32, buf: void*, n: usize, flags: i32) -> isize;
        internal extern "C" fn sendto(fd: i32, buf: void*, n: usize, flags: i32, addr: void*, len: u32) -> isize;
        internal extern "C" fn recvfrom(fd: i32, buf: void*, n: usize, flags: i32, addr: void*, len: u32*) -> isize;
        internal extern "C" fn shutdown(fd: i32, how: i32) -> i32;
        internal extern "C" fn close(fd: i32) -> i32;
        internal extern "C" fn setsockopt(fd: i32, level: i32, name: i32, value: void*, len: u32) -> i32;
        internal extern "C" fn getsockopt(fd: i32, level: i32, name: i32, value: void*, len: u32*) -> i32;
        internal extern "C" fn getsockname(fd: i32, addr: void*, len: u32*) -> i32;
        internal extern "C" fn getpeername(fd: i32, addr: void*, len: u32*) -> i32;
        internal extern "C" fn fcntl(fd: i32, cmd: i32, ...) -> i32;
        internal extern "C" fn getaddrinfo(host: cstr, port: cstr?, hints: void*, out: void**) -> i32;
        internal extern "C" fn freeaddrinfo(ai: void*) -> void;
    }

    // Windows (Winsock): a socket is a 64-bit handle, the error comes from WSAGetLastError
    namespace win {
        internal extern "C" fn WSAStartup(version: u16, data: void*) -> i32;
        internal extern "C" fn WSAGetLastError() -> i32;
        internal extern "C" fn socket(family: i32, kind: i32, protocol: i32) -> u64;
        internal extern "C" fn connect(s: u64, addr: void*, len: i32) -> i32;
        internal extern "C" fn bind(s: u64, addr: void*, len: i32) -> i32;
        internal extern "C" fn listen(s: u64, backlog: i32) -> i32;
        internal extern "C" fn accept(s: u64, addr: void*, len: i32*) -> u64;
        internal extern "C" fn send(s: u64, buf: void*, n: i32, flags: i32) -> i32;
        internal extern "C" fn recv(s: u64, buf: void*, n: i32, flags: i32) -> i32;
        internal extern "C" fn sendto(s: u64, buf: void*, n: i32, flags: i32, addr: void*, len: i32) -> i32;
        internal extern "C" fn recvfrom(s: u64, buf: void*, n: i32, flags: i32, addr: void*, len: i32*) -> i32;
        internal extern "C" fn shutdown(s: u64, how: i32) -> i32;
        internal extern "C" fn closesocket(s: u64) -> i32;
        internal extern "C" fn setsockopt(s: u64, level: i32, name: i32, value: void*, len: i32) -> i32;
        internal extern "C" fn getsockopt(s: u64, level: i32, name: i32, value: void*, len: i32*) -> i32;
        internal extern "C" fn getsockname(s: u64, addr: void*, len: i32*) -> i32;
        internal extern "C" fn getpeername(s: u64, addr: void*, len: i32*) -> i32;
        internal extern "C" fn ioctlsocket(s: u64, cmd: i32, arg: u32*) -> i32;
        internal extern "C" fn WSAPoll(fds: void*, n: u32, timeout: i32) -> i32;
        internal extern "C" fn getaddrinfo(host: cstr, port: cstr?, hints: void*, out: void**) -> i32;
        internal extern "C" fn freeaddrinfo(ai: void*) -> void;
    }

    // BSD sockaddrs start with a length byte, then a one-byte family
    internal fn bsd() -> bool {
        return @cfg("os", "macos") || @cfg("os", "freebsd");
    }

    internal fn af_inet6() -> i32 {
        return platform::by_os(10, 30, 28, 23);
    }

    internal fn sol_socket() -> i32 {
        return platform::by_os(1, 0xffff, 0xffff, 0xffff);
    }

    // Winsock wants WSAStartup before anything else (it counts calls, so more than one is fine)
    internal var winsock_started: bool = false;

    internal fn start() -> void {
        comptime if (@cfg("os", "windows")) {
            if (!winsock_started) {
                var data: u8[512];
                win::WSAStartup(0x0202, @cast<void*>(&data));
                winsock_started = true;
            }
        }
    }

    // the error number of the last failed call
    internal fn last_error() -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::WSAGetLastError();
        } else {
            return platform::errno();
        }
    }

    // the net_error for an error number
    internal fn error_from(code: i32) -> net_error {
        if (code == platform::by_os(111, 61, 61, 10061)) {
            return net_error::REFUSED;
        }
        if (code == platform::by_os(110, 60, 60, 10060) || code == platform::by_os(11, 35, 35, 10035)) {
            return net_error::TIMED_OUT; // a timed-out read or write says EAGAIN
        }
        if (code == platform::by_os(98, 48, 48, 10048) || code == platform::by_os(99, 49, 49, 10049)) {
            return net_error::IN_USE;
        }
        if (code == platform::by_os(104, 54, 54, 10054) || code == platform::by_os(32, 32, 32, 10058) || code == platform::by_os(103, 53, 53, 10053)) {
            return net_error::RESET;
        }
        if (code == platform::by_os(101, 51, 51, 10051) || code == platform::by_os(113, 65, 65, 10065)) {
            return net_error::UNREACHABLE;
        }
        return net_error::IO;
    }

    internal fn failure() -> net_error {
        return error_from(last_error());
    }

    // a POSIX call a signal interrupted (EINTR), which should just be made again
    internal fn interrupted() -> bool {
        comptime if (@cfg("os", "windows")) {
            return false;
        } else {
            return last_error() == 4;
        }
    }

    // ---------- sockets, the same on every system ----------

    // a new socket (SOCK_STREAM 1 or SOCK_DGRAM 2), or -1
    internal fn sys_socket(family: i32, kind: i32) -> i64 {
        start();
        comptime if (@cfg("os", "windows")) {
            return @cast<i64>(win::socket(family, kind, 0)); // INVALID_SOCKET is all ones: -1
        } else {
            val fd = posix::socket(family, kind, 0);
            comptime if (@cfg("os", "macos")) {
                // writing to a closed connection mustn't kill the program: SO_NOSIGPIPE
                var on: i32 = 1;
                if (fd >= 0) {
                    posix::setsockopt(fd, 0xffff, 0x1022, @cast<void*>(&on), 4);
                }
            }
            return @cast<i64>(fd);
        }
    }

    internal fn sys_close(fd: i64) -> void {
        comptime if (@cfg("os", "windows")) {
            win::closesocket(@cast<u64>(fd));
        } else {
            posix::close(@cast<i32>(fd));
        }
    }

    internal fn sys_connect(fd: i64, sa: u8[..], len: u32) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::connect(@cast<u64>(fd), @cast<void*>(sa.ptr), @cast<i32>(len));
        } else {
            return posix::connect(@cast<i32>(fd), @cast<void*>(sa.ptr), len);
        }
    }

    internal fn sys_bind(fd: i64, sa: u8[..], len: u32) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::bind(@cast<u64>(fd), @cast<void*>(sa.ptr), @cast<i32>(len));
        } else {
            return posix::bind(@cast<i32>(fd), @cast<void*>(sa.ptr), len);
        }
    }

    internal fn sys_listen(fd: i64, backlog: i32) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::listen(@cast<u64>(fd), backlog);
        } else {
            return posix::listen(@cast<i32>(fd), backlog);
        }
    }

    internal fn sys_accept(fd: i64, sa: u8[..]) -> i64 {
        comptime if (@cfg("os", "windows")) {
            var len = @cast<i32>(sa.len);
            return @cast<i64>(win::accept(@cast<u64>(fd), @cast<void*>(sa.ptr), &len));
        } else {
            loop {
                var len = @cast<u32>(sa.len);
                val r = posix::accept(@cast<i32>(fd), @cast<void*>(sa.ptr), &len);
                if (r >= 0 || !interrupted()) {
                    return @cast<i64>(r);
                }
            }
        }
    }

    // bytes sent, or -1; never a SIGPIPE (Linux MSG_NOSIGNAL, FreeBSD's too; macOS has SO_NOSIGPIPE)
    internal fn sys_send(fd: i64, data: u8[..]) -> i64 {
        comptime if (@cfg("os", "windows")) {
            var n = data.len;
            if (n > 0x7fffffff) {
                n = 0x7fffffff;
            }
            return @cast<i64>(win::send(@cast<u64>(fd), @cast<void*>(data.ptr), @cast<i32>(n), 0));
        } else {
            loop {
                val r = posix::send(@cast<i32>(fd), @cast<void*>(data.ptr), data.len, platform::by_os(0x4000, 0, 0x20000, 0));
                if (r >= 0 || !interrupted()) {
                    return @cast<i64>(r);
                }
            }
        }
    }

    internal fn sys_recv(fd: i64, buf: u8[..]) -> i64 {
        comptime if (@cfg("os", "windows")) {
            var n = buf.len;
            if (n > 0x7fffffff) {
                n = 0x7fffffff;
            }
            return @cast<i64>(win::recv(@cast<u64>(fd), @cast<void*>(buf.ptr), @cast<i32>(n), 0));
        } else {
            loop {
                val r = posix::recv(@cast<i32>(fd), @cast<void*>(buf.ptr), buf.len, 0);
                if (r >= 0 || !interrupted()) {
                    return @cast<i64>(r);
                }
            }
        }
    }

    internal fn sys_sendto(fd: i64, data: u8[..], sa: u8[..], len: u32) -> i64 {
        comptime if (@cfg("os", "windows")) {
            return @cast<i64>(win::sendto(@cast<u64>(fd), @cast<void*>(data.ptr), @cast<i32>(data.len), 0, @cast<void*>(sa.ptr), @cast<i32>(len)));
        } else {
            loop {
                val r = posix::sendto(@cast<i32>(fd), @cast<void*>(data.ptr), data.len, platform::by_os(0x4000, 0, 0x20000, 0), @cast<void*>(sa.ptr), len);
                if (r >= 0 || !interrupted()) {
                    return @cast<i64>(r);
                }
            }
        }
    }

    internal fn sys_recvfrom(fd: i64, buf: u8[..], sa: u8[..]) -> i64 {
        comptime if (@cfg("os", "windows")) {
            var len = @cast<i32>(sa.len);
            return @cast<i64>(win::recvfrom(@cast<u64>(fd), @cast<void*>(buf.ptr), @cast<i32>(buf.len), 0, @cast<void*>(sa.ptr), &len));
        } else {
            loop {
                var len = @cast<u32>(sa.len);
                val r = posix::recvfrom(@cast<i32>(fd), @cast<void*>(buf.ptr), buf.len, 0, @cast<void*>(sa.ptr), &len);
                if (r >= 0 || !interrupted()) {
                    return @cast<i64>(r);
                }
            }
        }
    }

    internal fn sys_shutdown(fd: i64, how: i32) -> void {
        comptime if (@cfg("os", "windows")) {
            win::shutdown(@cast<u64>(fd), how);
        } else {
            posix::shutdown(@cast<i32>(fd), how);
        }
    }

    internal fn sys_setsockopt(fd: i64, level: i32, name: i32, value: void*, len: u32) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::setsockopt(@cast<u64>(fd), level, name, value, @cast<i32>(len));
        } else {
            return posix::setsockopt(@cast<i32>(fd), level, name, value, len);
        }
    }

    // the socket's pending error (SO_ERROR), for a connect that finished in the background
    internal fn sys_socket_error(fd: i64) -> i32 {
        var e: i32 = 0;
        comptime if (@cfg("os", "windows")) {
            var len: i32 = 4;
            win::getsockopt(@cast<u64>(fd), 0xffff, 0x1007, @cast<void*>(&e), &len);
        } else {
            var len: u32 = 4;
            posix::getsockopt(@cast<i32>(fd), sol_socket(), platform::by_os(4, 0x1007, 0x1007, 0x1007), @cast<void*>(&e), &len);
        }
        return e;
    }

    // the address at one end: getsockname (this side) or getpeername (the other)
    internal fn sys_name(fd: i64, peer: bool) -> address {
        var sa: u8[128];
        comptime if (@cfg("os", "windows")) {
            var len: i32 = 128;
            if (peer) {
                win::getpeername(@cast<u64>(fd), @cast<void*>(&sa), &len);
            } else {
                win::getsockname(@cast<u64>(fd), @cast<void*>(&sa), &len);
            }
        } else {
            var len: u32 = 128;
            if (peer) {
                posix::getpeername(@cast<i32>(fd), @cast<void*>(&sa), &len);
            } else {
                posix::getsockname(@cast<i32>(fd), @cast<void*>(&sa), &len);
            }
        }
        return get_addr(sa[..]);
    }

    internal fn sys_nonblocking(fd: i64, on: bool) -> void {
        comptime if (@cfg("os", "windows")) {
            var arg: u32 = 0;
            if (on) {
                arg = 1;
            }
            win::ioctlsocket(@cast<u64>(fd), @cast<i32>(@cast<u32>(0x8004667E)), &arg); // FIONBIO
        } else {
            val nonblock = platform::by_os(0x800, 4, 4, 0); // O_NONBLOCK
            val flags = posix::fcntl(@cast<i32>(fd), 3, 0); // F_GETFL
            if (on) {
                posix::fcntl(@cast<i32>(fd), 4, flags | nonblock); // F_SETFL
            } else {
                posix::fcntl(@cast<i32>(fd), 4, flags & ~nonblock);
            }
        }
    }

    // wait up to ms for the socket to be writable (or readable): >0 ready, 0 timed out, <0 failed
    internal fn sys_poll(fd: i64, write: bool, ms: i32) -> i32 {
        comptime if (@cfg("os", "windows")) {
            var p: u64[2]; // WSAPOLLFD: the socket, then events and revents
            p[0] = @cast<u64>(fd);
            var events: u64 = 0x100; // POLLRDNORM
            if (write) {
                events = 0x10; // POLLWRNORM
            }
            p[1] = events;
            return win::WSAPoll(@cast<void*>(&p), 1, ms);
        } else {
            var p: std::process::pollfd = { fd: @cast<i32>(fd), events: 1, revents: 0 }; // POLLIN
            if (write) {
                p.events = 4; // POLLOUT
            }
            // ponytail: after a signal the wait starts over with the whole timeout
            loop {
                val r = std::process::poll(&p, 1, ms);
                if (r >= 0 || !interrupted()) {
                    return r;
                }
            }
        }
    }

    // ---------- addresses ----------

    // a's sockaddr_in or sockaddr_in6 in sa (28 bytes at least): its length
    internal fn put_addr(a: address&, sa: u8[..]) -> u32 {
        for (i) in 0..28 {
            sa[i] = 0;
        }
        var family = 2; // AF_INET
        var len: u32 = 16;
        if (a.v6) {
            family = af_inet6();
            len = 28;
        }
        if (bsd()) {
            sa[0] = @cast<u8>(len);
            sa[1] = @cast<u8>(family);
        } else {
            sa[0] = @cast<u8>(family & 0xff);
            sa[1] = @cast<u8>(family >> 8);
        }
        sa[2] = @cast<u8>(a.port >> 8); // network order: big-endian
        sa[3] = @cast<u8>(a.port & 0xff);
        if (a.v6) {
            for (i) in 0..16 {
                sa[8 + i] = a.ip[i];
            }
        } else {
            for (i) in 0..4 {
                sa[4 + i] = a.ip[i];
            }
        }
        return len;
    }

    // the address in a sockaddr_in or sockaddr_in6
    internal fn get_addr(sa: u8[..]) -> address {
        var family = @cast<i32>(sa[0]) | (@cast<i32>(sa[1]) << 8);
        if (bsd()) {
            family = @cast<i32>(sa[1]);
        }
        var none: u8[16];
        var a: address = { ip: none, v6: family == af_inet6(), port: (@cast<u16>(sa[2]) << 8) | @cast<u16>(sa[3]) };
        if (a.v6) {
            for (i) in 0..16 {
                a.ip[i] = sa[8 + i];
            }
        } else {
            for (i) in 0..4 {
                a.ip[i] = sa[4 + i];
            }
        }
        return a;
    }

    // the addresses host (a name or a numeric address) resolves to, with port, from the system's
    // resolver (getaddrinfo: the hosts file, DNS, ...)
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn resolve(host: str, port: u16, allocator: A = {}) -> net_error!std::vec<address, A> {
        comptime if (@cfg("hosted") && !@cfg("pointer_bits", "64")) {
            @compile_error("std::net: only 64-bit targets for now (addrinfo's layout)");
        }
        start();
        var hb: u8[256];
        val name = std::fs::c_text(host, hb[..]) catch return net_error::NOT_FOUND;
        // struct addrinfo hints: any family, stream sockets (one entry per address)
        var hints: u64[6];
        @cast<i32*>(@cast<usize>(&hints) + 8)[0] = 1; // ai_socktype = SOCK_STREAM
        var list: void* = null;
        var rc = 0;
        comptime if (@cfg("os", "windows")) {
            rc = win::getaddrinfo(name, null, @cast<void*>(&hints), &list);
        } else {
            rc = posix::getaddrinfo(name, null, @cast<void*>(&hints), &list);
        }
        if (rc != 0) {
            return net_error::NOT_FOUND;
        }
        var out: std::vec<address, A> = { allocator: move allocator };
        // walk the list: ai_family at 4, ai_addr at 24 (Linux) or 32 (the others, after
        // ai_canonname), ai_next at 40
        val at_addr = @cast<usize>(platform::by_os(24, 32, 32, 32));
        var p = @cast<usize>(list);
        while (p != 0) {
            val sa = *@cast<u8**>(p + at_addr);
            if (@cast<usize>(sa) != 0) {
                var a = get_addr(@slice(sa, 28));
                a.port = port;
                out.push(a) catch @panic("out of memory");
            }
            p = *@cast<usize*>(p + 40);
        }
        comptime if (@cfg("os", "windows")) {
            win::freeaddrinfo(list);
        } else {
            posix::freeaddrinfo(list);
        }
        return move out;
    }

    // ---------- TCP ----------

    // A TCP connection: read and write bytes; closed when it's deleted. It's a writer, so std::write
    // formats straight into it (a failed write shows as failed).
    struct tcp_stream {
        fd: i64;
        failed: bool = false; // a write through write_str failed
    }

    // Accepts TCP connections on an address; closed when it's deleted.
    struct tcp_listener {
        fd: i64;
    }

    // connect to a's port, giving up after timeout (null: wait as long as the system does)
    fn connect_to(a: address, timeout: std::time::duration? = null) -> net_error!tcp_stream {
        var family = 2;
        if (a.v6) {
            family = af_inet6();
        }
        val fd = sys_socket(family, 1);
        if (fd < 0) {
            return failure();
        }
        var sa: u8[28];
        val len = put_addr(&a, sa[..]);
        if (timeout == null) {
            if (sys_connect(fd, sa[..], len) != 0) {
                if (!interrupted()) {
                    val e = failure();
                    sys_close(fd);
                    return e;
                }
                // a signal came: the connection goes on without us; wait for it, then ask how it went
                if (sys_poll(fd, true, -1) < 0 || sys_socket_error(fd) != 0) {
                    val e = error_from(sys_socket_error(fd));
                    sys_close(fd);
                    return e;
                }
            }
            return { fd: fd };
        }
        // with a timeout: start connecting without waiting, then wait for it to finish
        sys_nonblocking(fd, true);
        if (sys_connect(fd, sa[..], len) != 0) {
            val code = last_error();
            if (code != platform::by_os(115, 36, 36, 10035)) { // EINPROGRESS (WSAEWOULDBLOCK)
                sys_close(fd);
                return error_from(code);
            }
            val ready = sys_poll(fd, true, ms_of(timeout));
            if (ready <= 0) {
                sys_close(fd);
                if (ready == 0) {
                    return net_error::TIMED_OUT;
                }
                return net_error::IO;
            }
            val err = sys_socket_error(fd);
            if (err != 0) {
                sys_close(fd);
                return error_from(err);
            }
        }
        sys_nonblocking(fd, false);
        return { fd: fd };
    }

    // connect to host (a name or a numeric address) on port: each address it resolves to in turn,
    // giving up on each after timeout
    fn connect(host: str, port: u16, timeout: std::time::duration? = null) -> net_error!tcp_stream {
        val found = try resolve(host, port);
        var last = net_error::NOT_FOUND;
        for (a) in found.items() {
            val s = connect_to(a, timeout) catch |e| {
                last = e;
                continue;
            };
            return move s;
        }
        return last;
    }

    // listen for connections on host's port (port 0: any free one; local() tells which)
    fn listen(host: str, port: u16, backlog: i32 = 128) -> net_error!tcp_listener {
        val found = try resolve(host, port);
        if (found.len == 0) {
            return net_error::NOT_FOUND;
        }
        val a = *found.at(0);
        var family = 2;
        if (a.v6) {
            family = af_inet6();
        }
        val fd = sys_socket(family, 1);
        if (fd < 0) {
            return failure();
        }
        // a server restarted right away can have its port back (SO_REUSEADDR)
        var on: i32 = 1;
        sys_setsockopt(fd, sol_socket(), platform::by_os(2, 4, 4, 4), @cast<void*>(&on), 4);
        var sa: u8[28];
        val len = put_addr(&a, sa[..]);
        if (sys_bind(fd, sa[..], len) != 0 || sys_listen(fd, backlog) != 0) {
            val e = failure();
            sys_close(fd);
            return e;
        }
        return { fd: fd };
    }

    // ---------- UDP ----------

    // A UDP socket: sends and receives datagrams; closed when it's deleted.
    struct udp_socket {
        fd: i64;
    }

    // a UDP socket on host's port (port 0: any free one)
    fn bind_udp(host: str, port: u16) -> net_error!udp_socket {
        val found = try resolve(host, port);
        if (found.len == 0) {
            return net_error::NOT_FOUND;
        }
        val a = *found.at(0);
        var family = 2;
        if (a.v6) {
            family = af_inet6();
        }
        val fd = sys_socket(family, 2);
        if (fd < 0) {
            return failure();
        }
        var sa: u8[28];
        val len = put_addr(&a, sa[..]);
        if (sys_bind(fd, sa[..], len) != 0) {
            val e = failure();
            sys_close(fd);
            return e;
        }
        return { fd: fd };
    }

    // a duration in whole milliseconds for the system (null: none)
    internal fn ms_of(d: std::time::duration?) -> i32 {
        val t = d ?? return -1;
        var ms = t.ns / 1000000;
        if (ms > 0x7fffffff) {
            ms = 0x7fffffff;
        }
        return @cast<i32>(ms);
    }

    // (inside the namespace: a top-level `text` would hide the std::text namespace)
    // "1.2.3.4:80", or "[2001:db8:0:0:0:0:0:1]:443" for IPv6
    <A: std::mem::t_allocator = std::mem::default_allocator>
    attach fn text(this: address&, allocator: A = {}) -> std::string<A> {
        var out = std::string::new_in(move allocator);
        if (this.v6) {
            out.push('[');
            for (g) in 0..8 {
                if (g > 0) {
                    out.push(':');
                }
                val group = (@cast<u32>(this.ip[2 * g]) << 8) | @cast<u32>(this.ip[2 * g + 1]);
                std::fmt::write(&out, "{:x}", group);
            }
            out.push(']');
        } else {
            for (i) in 0..4 {
                if (i > 0) {
                    out.push('.');
                }
                out.append_uint(@cast<u64>(this.ip[i]));
            }
        }
        out.push(':');
        out.append_uint(@cast<u64>(this.port));
        return move out;
    }

    // set SO_RCVTIMEO or SO_SNDTIMEO (null: wait as long as it takes)
    internal fn set_timeout_opt(fd: i64, name_posix_linux: i32, name_other: i32, d: std::time::duration?) -> void {
        var ns: i64 = 0;
        if (d != null) {
            ns = (d ?? std::time::nanos(0)).ns;
            if (ns <= 0) {
                ns = 1000; // zero would mean no timeout at all
            }
        }
        comptime if (@cfg("os", "windows")) {
            var ms = @cast<u32>(ns / 1000000);
            if (ns > 0 && ms == 0) {
                ms = 1;
            }
            sys_setsockopt(fd, 0xffff, name_other, @cast<void*>(&ms), 4);
        } else {
            var tv: i64[2]; // struct timeval: seconds, microseconds
            tv[0] = ns / 1000000000;
            tv[1] = ns % 1000000000 / 1000;
            sys_setsockopt(fd, sol_socket(), platform::by_os(name_posix_linux, name_other, name_other, name_other), @cast<void*>(&tv), 16);
        }
    }
}

// ---------- TCP ----------

// the next connection, waiting for one
attach fn accept(this: std::net::tcp_listener&) -> std::net::net_error!std::net::tcp_stream {
    var sa: u8[128];
    val fd = std::net::sys_accept(this.fd, sa[..]);
    if (fd < 0) {
        return std::net::failure();
    }
    comptime if (@cfg("os", "macos")) {
        var on: i32 = 1;
        std::net::posix::setsockopt(@cast<i32>(fd), 0xffff, 0x1022, @cast<void*>(&on), 4); // SO_NOSIGPIPE
    }
    return { fd: fd };
}

// the address it listens on (with the port the system picked for port 0)
attach fn local(this: std::net::tcp_listener&) -> std::net::address {
    return std::net::sys_name(this.fd, false);
}

attach fn delete(this: std::net::tcp_listener&) -> void {
    std::net::sys_close(this.fd);
}

// read up to buf.len bytes: how many (0 when the other side has finished sending)
attach fn read(this: std::net::tcp_stream&, buf: u8[..]) -> std::net::net_error!usize {
    val n = std::net::sys_recv(this.fd, buf);
    if (n < 0) {
        return std::net::failure();
    }
    return @cast<usize>(n);
}

// everything until the other side finishes sending
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn read_all(this: std::net::tcp_stream&, allocator: A = {}) -> std::net::net_error!std::string<A> {
    var out = std::string::new_in(move allocator);
    var buf: u8[4096];
    loop {
        val n = try this.read(buf[..]);
        if (n == 0) {
            return move out;
        }
        out.append(@cast<str>(buf[0..n]));
    }
}

// send all of data
attach fn write(this: std::net::tcp_stream&, data: str) -> std::net::net_error!void {
    val bytes = @cast<u8[..]>(data);
    var sent: usize = 0;
    while (sent < bytes.len) {
        val n = std::net::sys_send(this.fd, bytes[sent..bytes.len]);
        if (n < 0) {
            return std::net::failure();
        }
        sent += @cast<usize>(n);
    }
}

// send s: this makes a stream a writer, for std::write. A failure sets failed
attach fn write_str(this: std::net::tcp_stream&, s: str) -> void {
    this.write(s) catch |e| {
        this.failed = true;
    };
}

// stop sending: the other side's reads see the end; this side can still read
attach fn shutdown_write(this: std::net::tcp_stream&) -> void {
    std::net::sys_shutdown(this.fd, 1); // SHUT_WR (SD_SEND)
}

// how long a read or a write may wait before it fails with TIMED_OUT (null: as long as it takes)
attach fn set_timeout(this: std::net::tcp_stream&, read: std::time::duration?, write: std::time::duration?) -> void {
    std::net::set_timeout_opt(this.fd, 20, 0x1006, read);  // SO_RCVTIMEO
    std::net::set_timeout_opt(this.fd, 21, 0x1005, write); // SO_SNDTIMEO
}

// the address of this end
attach fn local(this: std::net::tcp_stream&) -> std::net::address {
    return std::net::sys_name(this.fd, false);
}

// the address of the other end
attach fn peer(this: std::net::tcp_stream&) -> std::net::address {
    return std::net::sys_name(this.fd, true);
}

attach fn delete(this: std::net::tcp_stream&) -> void {
    std::net::sys_close(this.fd);
}

// ---------- UDP ----------

// send data as one datagram to to
attach fn send_to(this: std::net::udp_socket&, data: str, to: std::net::address) -> std::net::net_error!void {
    var sa: u8[28];
    val len = std::net::put_addr(&to, sa[..]);
    if (std::net::sys_sendto(this.fd, @cast<u8[..]>(data), sa[..], len) < 0) {
        return std::net::failure();
    }
}

// the next datagram, into buf (cut to buf.len): its length and where it came from
attach fn recv_from(this: std::net::udp_socket&, buf: u8[..]) -> std::net::net_error!(usize, std::net::address) {
    var sa: u8[128];
    val n = std::net::sys_recvfrom(this.fd, buf, sa[..]);
    if (n < 0) {
        return std::net::failure();
    }
    return (@cast<usize>(n), std::net::get_addr(sa[..]));
}

// how long recv_from may wait before it fails with TIMED_OUT (null: as long as it takes)
attach fn set_timeout(this: std::net::udp_socket&, read: std::time::duration?) -> void {
    std::net::set_timeout_opt(this.fd, 20, 0x1006, read);
}

// the address it's bound to (with the port the system picked for port 0)
attach fn local(this: std::net::udp_socket&) -> std::net::address {
    return std::net::sys_name(this.fd, false);
}

attach fn delete(this: std::net::udp_socket&) -> void {
    std::net::sys_close(this.fd);
}
