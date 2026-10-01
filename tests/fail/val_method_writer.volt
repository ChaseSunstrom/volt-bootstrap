struct counter {
    n: i32 = 0;
}

attach fn bump(this: counter&) -> void {
    this.n += 1;
}

fn main() -> void {
    val c: counter = {};
    c.bump();
}
// error: 'c' is a val, and bump changes it (through this): declare it with var
