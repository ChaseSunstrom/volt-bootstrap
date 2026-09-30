---
title: Errors and optionals
description: Error sets, E!T, try, catch, defer and errdefer; optionals, ?? and narrowing.
sidebar:
  order: 5
---

Volt has no exceptions. A function that can fail says so in its type and returns the error as a
value; the caller decides what to do with it.

## Error sets and E!T

An error set lists what can go wrong. `E!T` is either an error from `E` or a `T`.

```volt
use std::io;

error parse_error { EMPTY, BAD_DIGIT }

fn parse(s: str) -> parse_error!i32 {
    if (s.len == 0) {
        return parse_error::EMPTY;
    }
    var n = 0;
    for (ch) in s {
        if (ch < '0' || ch > '9') {
            return .BAD_DIGIT;                  // the set is known from the return type
        }
        n = n * 10 + (ch - '0') as i32;
    }
    return n;
}

fn main() -> void {
    std::println("{} {} {}", parse("123"), parse(""), parse("1x"));
}
// expect: 123 error.EMPTY error.BAD_DIGIT
```

## try and catch

`try x` gives `x`'s value, or returns its error from the current function (which must be able to
return it). `x catch v` gives `v` instead of an error; `x catch |e| { ... }` runs a block that
either leaves (`return`, `break`) or gives a value.

```volt
use std::io;

error parse_error { EMPTY, BAD_DIGIT }

fn parse(s: str) -> parse_error!i32 {
    if (s.len == 0) {
        return parse_error::EMPTY;
    }
    return 5;
}

fn sum(a: str, b: str) -> parse_error!i32 {
    return try parse(a) + try parse(b);
}

fn main() -> void {
    val x = sum("1", "") catch -1;
    val y = sum("1", "2") catch |e| {
        std::println("failed: {}", e);
        return;
    };
    std::println("{} {}", x, y);
}
// expect: -1 10
```

### Inferred error sets

`!T` without a set means "whatever errors the body can return": the compiler works the set out.

```volt
use std::io;

error net_error { TIMEOUT }
error disk_error { FULL }

fn fetch(ok: bool) -> net_error!i32 {
    if (!ok) { return net_error::TIMEOUT; }
    return 1;
}

fn save(ok: bool) -> disk_error!void {
    if (!ok) { return disk_error::FULL; }
}

fn sync(a: bool, b: bool) -> !i32 {             // can fail with TIMEOUT or FULL
    val n = try fetch(a);
    try save(b);
    return n;
}

fn main() -> void {
    std::println("{} {} {}", sync(true, true), sync(false, true), sync(true, false));
}
// expect: 1 error.TIMEOUT error.FULL
```

### Errors with data

Variants of an error set can carry a payload, like enum variants, and error sets can be generic.

```volt
use std::io;

error config_error {
    MISSING: str,
    BAD_VALUE: (str, i32),
}

fn port(n: i32) -> config_error!i32 {
    if (n > 65535) {
        return config_error::BAD_VALUE("port", n);
    }
    return n;
}

fn main() -> void {
    std::println("{}", port(70000));
}
// expect: error.BAD_VALUE(port, 70000)
```

## defer and errdefer

`defer` runs a statement when the scope ends, however it ends; `errdefer` only when it ends by
returning an error. They run in reverse order. (Deleting owned values is automatic: see
[Ownership](/volt-bootstrap/guide/ownership/). `defer` is for everything else.)

```volt
use std::io;

error job_error { FAILED }

fn run(fail: bool) -> job_error!void {
    std::println("start");
    defer std::println("cleanup");
    errdefer std::println("rolled back");
    if (fail) {
        return job_error::FAILED;
    }
    std::println("done");
}

fn main() -> void {
    run(false) catch {};
    run(true) catch {};
}
// expect: start
// expect: done
// expect: cleanup
// expect: start
// expect: rolled back
// expect: cleanup
```

## Looking inside

On a variable, `.err` is the error as an optional (`E?`: null when it holds a value), so `if (r.err)`
narrows to the error. `.value` is the value; reading it when there's an error stops the program in
debug builds.

```volt
use std::io;

error e { NOPE }

fn get(ok: bool) -> e!i32 {
    if (ok) { return 4; }
    return e::NOPE;
}

fn main() -> void {
    val bad = get(false);
    if (bad.err) {
        std::println("failed: {}", bad.err);
    }
    val good = get(true);
    if (good.err == null) {
        std::println("{}", good.value);
    }
}
// expect: failed: NOPE
// expect: 4
```

## Optionals

`T?` is a `T` or `null`. `x ?? fallback` gives the value or the fallback, and the fallback can leave
instead: `x ?? return`, `x ?? break`, `x ?? @panic("...")`.

```volt
use std::io;

fn index_of(xs: i32[..], want: i32) -> usize? {
    for (x, i) in xs {
        if (x == want) {
            return i;
        }
    }
    return null;
}

fn main() -> void {
    val data: i32[] = { 4, 8, 15 };
    val a = index_of(data[..], 8);
    val b = index_of(data[..], 16) ?? 99;
    std::println("{} {} {}", a, b, index_of(data[..], 3));
}
// expect: 1 99 null
```

### Narrowing

`if (x)` checks that an optional holds a value, and inside the branch `x` is that value, with no
unwrapping. `while (x)` narrows the same way.

```volt
use std::io;

fn next(n: i32) -> i32? {
    if (n > 0) {
        return n - 1;
    }
    return null;
}

fn main() -> void {
    var cur: i32? = 3;
    var total = 0;
    while (cur) {
        total += cur;            // cur is an i32 here
        cur = next(cur);
    }
    val maybe: i32? = 41;
    if (maybe) {
        std::println("{} {}", maybe + 1, total);
    }
}
// expect: 42 6
```

`x.value` and `x.none` read an optional directly. A condition is always a `bool`, except that an
optional is allowed (it means "has a value").

Pointers (`T*`) may be null too; `if (p)` and `p ?? x` turn one into a reference. See
[References and pointers](/volt-bootstrap/guide/references/).
