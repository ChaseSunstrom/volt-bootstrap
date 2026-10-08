// shapelib: what C and C++ call in a Volt library beyond plain shapes (tests/interop.rs builds it
// with voltc lib --shared and writes its bindings with voltc bindings --lang c and cpp): a generic's
// instances, a struct held by a handle with its methods, owned values as parameters, traits both
// ways, closures taking and giving text and handles, and closures given back
use std::string;

// a generic fn: the instances other languages call are named here
<T: type>
@attributes([@instance(i32), @instance(f64)])
export fn biggest(xs: T[..]) -> T {
    var best = xs[0];
    for (x) in xs {
        if (x > best) {
            best = x;
        }
    }
    return best;
}

// a struct that owns text: other languages hold it by a handle
public struct account {
    owner: std::string;
    cents: i64;
}

var closed: i32 = 0;

attach fn delete(this: account&) -> void {
    closed += 1;
}

// how many accounts were deleted
export fn closed_accounts() -> i32 {
    return closed;
}

export fn account_open(owner: str) -> account {
    return { owner: std::string::from(owner), cents: 0 };
}

// methods
export attach fn deposit(this: account&, cents: i64) -> i64 {
    this.cents += cents;
    return this.cents;
}

export attach fn owner(this: account&) -> str {
    return this.owner.as_str();
}

// named like the C++ class's own get(): that one's get_() there
export attach fn get(this: account&) -> i64 {
    return this.cents;
}

// owned values in: text, and a handle the fn takes over (and deletes)
export attach fn rename(this: account&, owner: std::string) -> void {
    this.owner = move owner;
}

export fn close_account(a: account) -> i64 {
    return a.cents;
}

// a trait other languages implement (and call, on a Volt value of it)
public trait shape {
    fn area(this) -> f64;
    fn name(this) -> std::string;
    fn grow(this, by: f64) -> void;
}

public struct square {
    side: f64;
}

attach shape -> square {
    fn area(this) -> f64 {
        return this.side * this.side;
    }
    fn name(this) -> std::string {
        return std::string::from("square");
    }
    fn grow(this, by: f64) -> void {
        this.side += by;
    }
}

// a lent shape
export fn describe(s: shape&) -> std::string {
    var out = s.name();
    out.append(" of area ");
    out.append_int(@cast<i64>(s.area()));
    return move out;
}

// a shape the fn takes over (deleted when it returns)
export fn grow_twice(s: shape) -> f64 {
    s.grow(1.0);
    s.grow(1.0);
    return s.area();
}

// a Volt shape given out
export fn make_square(side: f64) -> shape {
    val q: square = { side: side };
    var s: shape = move q;
    return move s;
}

// closures taking and giving text and handles
export fn shout(f: fn(std::string) -> std::string, s: str) -> std::string {
    return f(std::string::from(s));
}

export fn visit(a: account&, f: fn(account&) -> i64) -> i64 {
    return f(a);
}

// a callback's error: the C struct of the code and the value, in both languages
public error bank_error {
    OVERDRAWN,
}

export fn try_twice(f: fn(i32) -> bank_error!i32, x: i32) -> bank_error!i32 {
    val y = try f(x);
    return try f(y);
}

export fn opened_by(f: fn(str) -> account) -> i64 {
    val a = f("made by a callback");
    return a.cents + @cast<i64>(a.owner.len());
}

// closures given back
fn double_it(x: i32) -> i32 {
    return x * 2;
}

fn hello(name: str) -> std::string {
    var s = std::string::from("hello, ");
    s.append(name);
    return move s;
}

export fn doubler() -> fn(i32) -> i32 {
    return double_it;
}

export fn greeter() -> fn(str) -> std::string {
    return hello;
}

// a callback's E!void, and closures given back giving E!void and a str
export fn checked(f: fn(i32) -> bank_error!void, x: i32) -> bank_error!void {
    return f(x);
}

fn under_ten(x: i32) -> bank_error!void {
    if (x >= 10) {
        return bank_error::OVERDRAWN;
    }
}

export fn limiter() -> fn(i32) -> bank_error!void {
    return under_ten;
}

fn sign_of(x: i32) -> str {
    if (x > 0) {
        return "positive";
    }
    return "not positive";
}

export fn labeler() -> fn(i32) -> str {
    return sign_of;
}

// lists (std::vec given out, and taken), slices of text and handles, optional text and handles
export fn owners(xs: account&[..]) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    for (a) in xs {
        out.push(std::string::from(a.owner.as_str())) catch @panic("out of memory");
    }
    return out;
}

export fn open_all(names: str[..]) -> std::vec<account> {
    var out: std::vec<account> = {};
    for (n) in names {
        out.push(account_open(n)) catch @panic("out of memory");
    }
    return out;
}

export fn squares_upto(n: i64) -> std::vec<i64> {
    var out: std::vec<i64> = {};
    for (i) in 1..n + 1 {
        out.push(i * i) catch @panic("out of memory");
    }
    return out;
}

export fn sum_all(xs: std::vec<i64>) -> i64 {
    var t: i64 = 0;
    for (x) in xs.items() {
        t += x;
    }
    return t;
}

export fn joined(xs: std::string[..], sep: str) -> std::string {
    var out = std::string::from("");
    for (i) in 0..xs.len {
        if (i > 0) {
            out.append(sep);
        }
        out.append(xs[i].as_str());
    }
    return out;
}

export fn richest(xs: account[..]) -> i64 {
    var best: i64 = 0;
    for (i) in 0..xs.len {
        if (xs[i].cents > best) {
            best = xs[i].cents;
        }
        xs[i].cents += 1;
    }
    return best;
}

export fn total_len(xs: std::vec<std::string>) -> i64 {
    var t: i64 = 0;
    for (x) in xs.items() {
        t += @cast<i64>(x.as_str().len);
    }
    return t;
}

export fn close_all(xs: std::vec<account>) -> i64 {
    return @cast<i64>(xs.items().len);
}

export fn greeting(name: str?) -> std::string {
    val n = name ?? return std::string::from("hello, nobody");
    var out = std::string::from("hello, ");
    out.append(n);
    return out;
}

export fn nickname(a: account&) -> std::string? {
    if (a.owner.as_str().len > 3) {
        return null;
    }
    return std::string::from(a.owner.as_str());
}

export fn open_if(owner: str, ok: bool) -> account? {
    if (!ok) {
        return null;
    }
    return account_open(owner);
}

export fn close_if(a: account?) -> i64 {
    val x = a ?? return -1;
    return x.cents;
}

// optionals in a slice (as Volt lays them out)
export fn count_some(xs: i64?[..]) -> i64 {
    var n: i64 = 0;
    for (x) in xs {
        if (x != null) {
            n += 1;
        }
    }
    return n;
}

// a callback while the call lends handles (one after it, a slice of them), and a handle lent and one
// given in one call: what a call lends can't be closed or given away until it's back
export fn visit_then(f: fn(account&) -> i64, a: account&) -> i64 {
    return f(a) + a.cents;
}

export fn visit_over(xs: account&[..], f: fn(account&) -> i64) -> i64 {
    var t: i64 = 0;
    for (a) in xs {
        t += f(a) + a.cents;
    }
    return t;
}

export fn lend_give(a: account&, b: account) -> i64 {
    return a.cents + b.cents;
}
