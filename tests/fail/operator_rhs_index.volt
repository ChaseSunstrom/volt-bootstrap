// [] takes this first: i[v] isn't an index of v
struct rgb {
    r: u8;
}

attach operator [](i: usize, this: rgb) -> u8 {
    return this.r;
}

fn main() -> void {}
// error: operator [] takes this first: only a binary operator takes it second
