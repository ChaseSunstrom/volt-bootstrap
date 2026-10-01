// std::write appends to its writer: not to a val
fn main() -> void {
    val out: std::string = {};
    std::fmt::write(&out, "hi {}", 3);
}
// error: 'out' is a val, and write_str changes it (through this): declare it with var
