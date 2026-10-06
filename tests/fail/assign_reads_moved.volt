// error: 'a' was moved earlier
fn keep(s: std::string) -> std::string {
    return s;
}
fn main() -> void {
    var a: std::string = {};
    val b = move a;
    a = keep(a);
}
