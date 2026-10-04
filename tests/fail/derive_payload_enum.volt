// std's eq derive covers enums without payloads only (for now)
@attributes([@derive(eq)])
enum shape {
    CIRCLE: f64,
    SQUARE: f64,
}

fn main() -> void {
    val a = shape::CIRCLE(1.0);
    val b = shape::CIRCLE(1.0);
    val same = a == b;
}
// error: @derive(eq) on an enum with payloads isn't supported yet
