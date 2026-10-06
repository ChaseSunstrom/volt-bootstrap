// error: 'value' was moved earlier
fn f(value: std::string, opt: i32?) -> std::string {
    if (val x = opt) {
        val keep = value;
    }
    return value;
}
fn main() -> void {}
