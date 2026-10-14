// a +% b calls only an attached +%: a type with + has no +% from it
struct fix {
    raw: u8;
}

attach operator +(this: fix, o: fix) -> fix {
    return { raw: this.raw + o.raw };
}

fn wrapped(a: fix, b: fix) -> fix {
    return a +% b;
}

fn main() -> void {}
// error: can't use +% on fix; attach operator +% to give it one
