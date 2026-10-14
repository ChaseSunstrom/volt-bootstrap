// a op= b uses a's own operator (this first); a right-hand operator doesn't serve op=
struct meters {
    m: i32;
}

struct scale {
    k: i32;
}

attach operator *(m: meters, this: scale) -> meters {
    return { m: m.m * this.k };
}

fn grow(len: meters, s: scale) -> meters {
    var out = len;
    out *= s;
    return out;
}

fn main() -> void {}
// error: expected meters, found scale
