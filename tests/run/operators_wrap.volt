// the wrapping operators on a struct: attach operator +%, -% and *% (a +%= b is a = a +% b)
use std::io;

// a fixed-point number in a u8 with 4 fraction bits: 16 is 1.0
struct fix {
    raw: u8;
}

attach operator +%(this: fix, o: fix) -> fix {
    return { raw: this.raw +% o.raw };
}

attach operator -%(this: fix, o: fix) -> fix {
    return { raw: this.raw -% o.raw };
}

// the product has 8 fraction bits: drop 4 and keep the low 8 bits
attach operator *%(this: fix, o: fix) -> fix {
    val p = @cast<u16>(this.raw) * @cast<u16>(o.raw);
    return { raw: @cast<u8>((p >> 4) & 255) };
}

// + is its own operator: a fix with only +% has no +, and the other way round
attach operator +(this: fix, o: fix) -> fix {
    return { raw: this.raw + o.raw + 100 };
}

fn main() -> void {
    val a: fix = { raw: 200 };
    val b: fix = { raw: 100 };
    std::println("{}", (a +% b).raw);
    std::println("{}", (b -% a).raw);
    std::println("{}", (a *% b).raw);
    val one: fix = { raw: 16 };
    val two: fix = { raw: 32 };
    std::println("{}", (one *% two).raw);
    std::println("{}", (one + two).raw);
    var c: fix = { raw: 250 };
    c +%= one;
    std::println("{}", c.raw);
    c -%= two;
    std::println("{}", c.raw);
    c *%= two;
    std::println("{}", c.raw);
}
// expect: 44
// expect: 156
// expect: 226
// expect: 32
// expect: 148
// expect: 10
// expect: 234
// expect: 212
