// a variant without a payload has no field to read
enum mode {
    ON,
    OFF,
}

fn main() -> void {
    val m = mode::ON;
    val x = m.ON;
}
// error: ON has no payload
