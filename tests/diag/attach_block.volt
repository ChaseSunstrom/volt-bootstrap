// an attach block must name a trait and hold every fn it requires, taking the same parameters
trait shape {
    fn area(this) -> f64;
    fn scale(this, k: f64) -> f64;
}

trait named {
    fn name(this) -> str { return "?"; }
}

struct square { side: f64; }
struct circle { r: f64; }
struct dot {}

attach shpae -> square {
    fn area(this) -> f64 { return this.side * this.side; }
}

attach shape -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
}

attach shape -> dot {
    fn area(this) -> f64 { return 0.0; }
    fn scale(this) -> f64 { return 0.0; }
}

// overloads: one of them matches the trait, so this block is fine
struct pin {}

attach shape -> pin {
    fn area(this) -> f64 { return 0.0; }
    fn scale(this) -> f64 { return 0.0; }
    fn scale(this, k: f64) -> f64 { return k; }
}

attach circle -> dot {
}

fn main() -> void {}
