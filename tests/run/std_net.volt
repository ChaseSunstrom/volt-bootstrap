// flags: --leak-check
use std::io;
use std::string;
use std::text;
use std::thread;
// std::net: resolving names, TCP (a listener, streams both ways, shutdown, timeouts, a refused
// connection) and UDP, all over the loopback interface

fn resolve_status(host: str) -> void {
    val found = std::net::resolve(host, 80) catch |e| {
        std::println("{}: {}", host, e);
        return;
    };
    var loopback = false;
    for (a) in found.items() {
        val t = a.text();
        loopback = loopback || t.as_str() == "127.0.0.1:80" || t.as_str() == "[::1]:80";
    }
    std::println("{}: {} {}", host, found.len > 0, loopback);
}

fn connect_status(port: u16) -> void {
    val c = std::net::connect("127.0.0.1", port) catch |e| {
        std::println("connect: {}", e);
        return;
    };
    std::println("connect: ok");
}

fn read_status(s: std::net::tcp_stream&) -> void {
    var buf: u8[8];
    val n = s.read(buf[..]) catch |e| {
        std::println("read: {}", e);
        return;
    };
    std::println("read: {} bytes", n);
}

fn main() -> !void {
    // names: localhost is a loopback address; a name that can't exist isn't found
    resolve_status("localhost");
    resolve_status("no-such-host.invalid");

    // TCP: a listener on a free port; a thread connects, sends a line, reads the answer, and
    // shuts its side, so the server's read_all ends
    var server = try std::net::listen("127.0.0.1", 0);
    val port = server.local().port;
    var client = try std::thread::spawn(|port| () {
        var c = std::net::connect("127.0.0.1", port) catch |e| {
            std::println("connect failed: {}", e);
            return;
        };
        c.write("hello over tcp\n") catch @panic("write");
        var buf: u8[64];
        var got: usize = 0;
        while (got < 14) {
            val n = c.read(buf[got..64]) catch 0;
            if (n == 0) {
                break;
            }
            got += n;
        }
        std::println("client got [{}]", @cast<str>(buf[0..got]));
        c.write("bye") catch @panic("write");
        c.shutdown_write();
    });
    {
        var conn = try server.accept();
        var buf: u8[64];
        var got: usize = 0;
        while (got == 0 || buf[got - 1] != '\n') {
            got += try conn.read(buf[got..64]);
        }
        val line = @cast<str>(buf[0..got]).trim();
        val loud = line.to_upper();
        try conn.write(loud.as_str());
        val rest = try conn.read_all();
        client.join();
        val from = conn.peer().text();
        std::println("server got [{}] then [{}] from {}", line, rest.as_str(), from.as_str().starts_with("127.0.0.1:"));
    }

    // a read that waits longer than its timeout
    {
        var quiet = try std::net::listen("127.0.0.1", 0);
        var c = try std::net::connect("127.0.0.1", quiet.local().port, std::time::millis(2000));
        var s = try quiet.accept();
        s.set_timeout(std::time::millis(50), null);
        read_status(&s);
    }

    // nothing listens on a port that was just closed
    var gone: u16 = 0;
    {
        val l = try std::net::listen("127.0.0.1", 0);
        gone = l.local().port;
    }
    connect_status(gone);

    // UDP between two sockets
    var a = try std::net::bind_udp("127.0.0.1", 0);
    var b = try std::net::bind_udp("127.0.0.1", 0);
    try a.send_to("ping", b.local());
    var buf: u8[16];
    val (n, from) = try b.recv_from(buf[..]);
    std::println("udp [{}] from a: {}", @cast<str>(buf[0..n]), from.port == a.local().port);

    // addresses as text
    val v4: std::net::address = { ip: { 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, v6: false, port: 8080 };
    val v6: std::net::address = { ip: { 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, v6: true, port: 443 };
    val (t4, t6) = (v4.text(), v6.text());
    std::println("{} {}", t4.as_str(), t6.as_str());
}
// expect: localhost: true true
// expect: no-such-host.invalid: NOT_FOUND
// expect: client got [HELLO OVER TCP]
// expect: server got [hello over tcp] then [bye] from true
// expect: read: TIMED_OUT
// expect: connect: REFUSED
// expect: udp [ping] from a: true
// expect: 10.0.0.1:8080 [2001:db8:0:0:0:0:0:1]:443
