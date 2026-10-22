// { } for a type made by its new(): the field that has no default is the type's own, so the help
// says how to make one
fn main() -> void {
    var ch: std::thread::channel<i64> = {};
}
// error: missing field 'state' (it has no default)
// error: make one with std::thread::channel<i64>::new()
