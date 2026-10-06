// alternatives count toward exhaustiveness, and only what they name
enum dir {
    N,
    E,
    S,
    W,
}

fn turn(d: dir) -> i32 {
    match (d) {
        .N | .S => { return 0; },
        .E => { return 1; },
    }
}

fn main() -> void {
    val t = turn(dir::N);
}
// error: W
