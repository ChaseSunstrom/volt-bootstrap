// a unary operator takes this first: only a binary one has a right-hand form
struct mask {
    bits: u8;
}

attach operator ~(k: u8, this: mask) -> mask {
    return { bits: ~this.bits };
}

fn main() -> void {}
// error: operator ~ takes this first: only a binary operator takes it second
