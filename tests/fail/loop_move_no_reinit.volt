// error: 'b' is moved inside a loop and has no new value before the next pass
fn main() -> void {
    var a: std::string = {};
    var b: std::string = {};
    for (i) in 0..3 {
        a = move b;
    }
}
