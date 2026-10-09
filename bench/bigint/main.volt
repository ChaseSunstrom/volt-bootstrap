// bigint: arbitrary-precision integers in base 1e9 limbs: n! by repeated small multiplies, the m-th
// Fibonacci number by repeated additions, and a schoolbook product of two big numbers, each printed
// as its digit count and digit sum; Volt wraps a std::vec<u32> in a struct with attached operators
use std::io;
use std::text;

val BASE: u32 = 1000000000;

struct big {
    limbs: std::vec<u32> = {}; // least significant first
}

attach fn from(static this: big, v: u32) -> big {
    var b: big = {};
    b.limbs.push(v) catch @panic("out of memory");
    return b;
}

// scales in place, as C++'s *= does (Volt attaches no compound-assignment operators)
attach fn scale(this: big&, k: u32) -> void {
    var carry: u64 = 0;
    for (l&) in this.limbs.items() {
        val x = @cast<u64>(*l) * @cast<u64>(k) + carry;
        *l = @cast<u32>(x % @cast<u64>(BASE));
        carry = x / @cast<u64>(BASE);
    }
    while (carry != 0) {
        this.limbs.push(@cast<u32>(carry % @cast<u64>(BASE))) catch @panic("out of memory");
        carry /= @cast<u64>(BASE);
    }
}

attach operator +(this: big&, o: big&) -> big {
    var l = &this.limbs;
    var s = &o.limbs;
    if (l.len < s.len) {
        l = &o.limbs;
        s = &this.limbs;
    }
    var r: big = {};
    r.limbs.resize(l.len, 0) catch @panic("out of memory");
    val ls = l.items();
    val ss = s.items();
    val rs = r.limbs.items();
    var carry: u32 = 0;
    for (i) in 0..ls.len {
        // the limbs first, then the carry, as the C adds them
        var x = ls[i];
        if (i < ss.len) {
            x += ss[i];
        }
        x += carry;
        val over = x >= BASE;
        rs[i] = if (over) x - BASE else x;
        carry = if (over) 1 else 0;
    }
    if (carry != 0) {
        r.limbs.push(1) catch @panic("out of memory");
    }
    return r;
}

attach operator *(this: big&, o: big&) -> big {
    var r: big = {};
    r.limbs.resize(this.limbs.len + o.limbs.len, 0) catch @panic("out of memory");
    val a = this.limbs.items();
    val b = o.limbs.items();
    val rs = r.limbs.items();
    for (i) in 0..a.len {
        var carry: u64 = 0;
        for (j) in 0..b.len {
            val x = @cast<u64>(rs[i + j]) + @cast<u64>(a[i]) * @cast<u64>(b[j]) + carry;
            rs[i + j] = @cast<u32>(x % @cast<u64>(BASE));
            carry = x / @cast<u64>(BASE);
        }
        rs[i + b.len] = @cast<u32>(carry);
    }
    while (r.limbs.len > 1 && *r.limbs.at(r.limbs.len - 1) == 0) {
        r.limbs.pop();
    }
    return r;
}

fn report(what: str, b: big&) -> void {
    var sum: u64 = 0;
    for (l) in b.limbs.items() {
        var x = l;
        while (x != 0) {
            sum += @cast<u64>(x % 10);
            x /= 10;
        }
    }
    var digits = (b.limbs.len - 1) * 9;
    var top = *b.limbs.at(b.limbs.len - 1);
    while (top != 0) {
        digits += 1;
        top /= 10;
    }
    std::println("{}: {} digits, digit sum {}", what, digits, sum);
}

fn main() -> void {
    val n = @cast<u32>((std::process::arg(1) ?? "20000").parse_int() catch 20000);
    var f = big::from(1);
    for (k) in 2..=n {
        f.scale(k);
    }
    report("factorial", &f);
    // fib[i % 2] steps through the Fibonacci numbers, each sum replacing the older of the two
    var fib: big[] = { big::from(0), big::from(1) };
    for (i) in 0..n * 10 {
        fib[i % 2] = fib[0] + fib[1];
    }
    report("fibonacci", &fib[1]);
    val p = f * fib[1];
    report("product", &p);
}
