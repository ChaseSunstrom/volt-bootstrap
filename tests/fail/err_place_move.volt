error oops {
    MSG: std::string,
}
fn f() -> oops!i32 { return oops::MSG(std::string::from("x")); }
fn main() -> void {
    val r = f();
    val e = r.err;
}
// error: copy it instead
