// internal items belong to their package: std's can't be used from the program (each fn below is
// checked on its own, so each reports its error)
use std::io;

fn call_fn() -> void {
    val d = std::json::hex_digit('a');
}

fn call_method() -> void {
    var m: std::map<i32, i32> = {};
    m.grow();
}

fn use_type() -> void {
    var p: std::process::pollfd = { fd: 0, events: 1, revents: 0 };
}

fn use_global() -> void {
    val v = std::json::missing.is_null();
}

fn main() -> void {}
// error: 'hex_digit' is internal to package std
// error: 'grow' is internal to package std
// error: 'pollfd' is internal to package std
// error: 'missing' is internal to package std
