// main's error exit says where the error came from and each try that passed it up, innermost first
// (an error return trace); one handled on the way (catch) leaves nothing behind for a later one
error fs_error { NOT_FOUND, DENIED }
fn open(name: str) -> fs_error!i32 {
    if (name == "secret") {
        return fs_error::DENIED;
    }
    return fs_error::NOT_FOUND;
}
fn read(name: str) -> fs_error!i32 {
    val fd = try open(name);
    return fd;
}
fn handled() -> i32 {
    val n = read("secret") catch |e| { return 0; };
    return n;
}
fn main() -> !void {
    val h = handled();
    val n = try read("missing");
}
// exit: 1
// (the path as voltc was given it, before each site)
// expect-stderr: error: NOT_FOUND, from
// expect-stderr: error_trace.volt:8:12
// expect-stderr:   passed up at
// expect-stderr: error_trace.volt:11:14
// expect-stderr: error_trace.volt:20:13
// reject-stderr: error_trace.volt:6:
