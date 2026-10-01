use std::io;
// a signal during a blocking read, set not to restart system calls (so the call returns EINTR),
// doesn't fail the read: std::net makes the call again, and it times out as asked

extern "C" fn signal(sig: i32, handler: extern "C" fn(i32) -> void) -> void*;
extern "C" fn siginterrupt(sig: i32, flag: i32) -> i32;
extern "C" fn ualarm(usecs: u32, interval: u32) -> u32;

fn on_alarm(sig: i32) -> void {}

fn read_status(s: std::net::tcp_stream&) -> void {
    var buf: u8[8];
    val n = s.read(buf[..]) catch |e| {
        std::println("read: {}", e);
        return;
    };
    std::println("read: {} bytes", n);
}

fn main() -> !void {
    signal(14, on_alarm); // SIGALRM
    siginterrupt(14, 1);  // interrupt system calls instead of restarting them
    var server = try std::net::listen("127.0.0.1", 0);
    var c = try std::net::connect("127.0.0.1", server.local().port);
    var s = try server.accept();
    s.set_timeout(std::time::millis(300), null);
    ualarm(50000, 0); // the signal comes 50 ms into the read
    read_status(&s);
}
// expect: read: TIMED_OUT
