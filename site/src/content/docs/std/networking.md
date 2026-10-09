---
title: Networking
description: std::net for names, TCP and UDP, with timeouts. One API on Linux, macOS, FreeBSD and Windows.
sidebar:
  order: 7
---

`std::net` talks to the system's sockets directly. The pieces that differ between systems
(constants, struct layouts, error numbers, Winsock) are chosen with `@cfg("os")`, so one program
builds unchanged on Linux, macOS, FreeBSD and Windows. Failures are `net_error`s: `NOT_FOUND`,
`REFUSED`, `TIMED_OUT`, `IN_USE`, `RESET`, `UNREACHABLE` and `IO`. A call that a signal interrupts
is made again, so it doesn't fail.

On Windows, a program that uses `std::net` has to be linked with `ws2_32`
(`--cc -lws2_32`). voltc doesn't add it on its own yet.

## TCP

`listen(host, port)` gives a `tcp_listener`, and `accept()` waits for the next connection.
`connect(host, port)` tries each address the name resolves to. A `tcp_stream` reads and writes
bytes:
- `read(buf)` returns 0 once the other side has finished sending.
- `read_all()` reads until then.
- `write(data)` sends all of it.
- `shutdown_write()` tells the other side that you've finished sending.

Port 0 picks any free port, and `local()` tells you which one. Deleting a stream or a listener
closes it.

```volt
use std::io;
use std::text;
use std::thread;

fn main() -> !void {
    var server = try std::net::listen("127.0.0.1", 0);
    val port = server.local().port;
    var client = try std::thread::spawn(|port| () {
        var c = std::net::connect("127.0.0.1", port) catch @panic("connect");
        c.write("ping") catch @panic("write");
        c.shutdown_write();
        val answer = c.read_all() catch @panic("read");
        std::println("client got {}", answer.as_str());
    });
    var conn = try server.accept();
    val got = try conn.read_all();
    try conn.write(got.as_str().to_upper().as_str());
    conn.shutdown_write();
    client.join();
}
// expect: client got PING
```

A stream is a writer, so `std::write(&stream, "{}\n", x)` formats straight into it. `read_all` keeps
reading as long as the other side keeps sending. For a peer you don't trust, read into a buffer of
your own size with `read`, and set a timeout.

## Timeouts

`connect` takes an optional timeout as a `std::time::duration`. `set_timeout(read, write)` limits
how long each read or write waits; `null` means no limit. When the time runs out, the call fails
with `TIMED_OUT`.

```volt
use std::io;

fn main() -> !void {
    var quiet = try std::net::listen("127.0.0.1", 0);
    var c = try std::net::connect("127.0.0.1", quiet.local().port, std::time::millis(2000));
    var buf: u8[8];
    c.set_timeout(std::time::millis(20), null);
    val n = c.read(buf[..]) catch |e| {
        std::println("nothing came: {}", e);
        return;
    };
}
// expect: nothing came: TIMED_OUT
```

## UDP

`bind_udp(host, port)` gives a `udp_socket`. `send_to(data, address)` sends one datagram, and
`recv_from(buf)` returns the next datagram's length and where it came from.

```volt
use std::io;

fn main() -> !void {
    var a = try std::net::bind_udp("127.0.0.1", 0);
    var b = try std::net::bind_udp("127.0.0.1", 0);
    try a.send_to("hello", b.local());
    var buf: u8[32];
    val (n, from) = try b.recv_from(buf[..]);
    std::println("{} from port {}", @cast<str>(buf[0..n]), from.port == a.local().port);
}
// expect: hello from port true
```

## Names and addresses

`resolve(host, port)` asks the system's resolver (the hosts file, DNS) and returns a
`vec<address>`. Like other std functions, it takes an optional allocator. An `address` holds the IP
(`ip`: 4 bytes for IPv4, 16 for IPv6), `v6` and `port`. `text()` writes it out:

```volt
use std::io;

fn main() -> !void {
    val found = try std::net::resolve("127.0.0.1", 8080);
    val first = found[0].text();
    std::println("{}", first.as_str());
}
// expect: 127.0.0.1:8080
```
