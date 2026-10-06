// error: 'b' is moved inside a loop and has no new value before the next pass
fn take(s: std::string) -> void {}
fn main() -> void {
    var b: std::string = {};
    var i = 0;
    while (i < 3) {
        i += 1;
        take(move b);
        if (i == 1) {
            continue;
        }
        b = {};
    }
}
