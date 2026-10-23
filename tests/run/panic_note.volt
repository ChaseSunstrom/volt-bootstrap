// a debug build's panic says that --backtrace lists the calls that led to it
fn main() -> void {
    @panic("stop");
}
// exit: 101
// expect-stderr: panic: stop
// expect-stderr: note: build with --backtrace to see the calls that led here
