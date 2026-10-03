---
title: References and pointers
description: T& and T*, taking addresses, dereferencing, pointer arithmetic and null.
sidebar:
  order: 7
---

Volt has two kinds of address:

| | `T&` reference | `T*` pointer |
| --- | --- | --- |
| null | never | may be |
| optional | can't be (`T&?` is an error) | is its own "maybe" |
| reaching through | `.` | `->` |
| arithmetic, `p[i]` | no | yes, unchecked, like C |
| owns | never | never |

`&x` gives a `T&`. A `T&` converts to a `T*` by itself; a `T*` becomes a `T&` through `if (p)` or
`p ?? other`, which check for null.

## References

```volt
use std::io;

struct account {
    balance: i32;
}

fn deposit(a: account&, amount: i32) -> void {
    a.balance += amount;                   // `.` reaches through the reference
}

fn main() -> void {
    var acct: account = { balance: 10 };
    deposit(&acct, 5);
    val r = &acct.balance;
    std::println("{} {}", acct.balance, *r);
}
// expect: 15 15
```

`*r` reads through a reference; printing `r` itself prints the address.

## References to a val

A reference to a `val` (or to a parameter without `var`) can be read through, never written
through. Passing `&x`, or calling a method on `x`, is fine as long as what's called only reads:

```volt
use std::io;

struct account {
    balance: i32;
}

attach fn report(this: account&) -> i32 {
    return this.balance;
}

attach fn deposit(this: account&, amount: i32) -> void {
    this.balance += amount;
}

fn main() -> void {
    val fixed: account = { balance: 10 };
    var open: account = { balance: 10 };
    open.deposit(5);
    std::println("{} {}", fixed.report(), open.report());
}
// expect: 10 15
```

Calling `deposit` on the `val` is an error, found where the call is:

```volt fail
struct account {
    balance: i32;
}

attach fn deposit(this: account&, amount: i32) -> void {
    this.balance += amount;
}

fn main() -> void {
    val fixed: account = { balance: 10 };
    fixed.deposit(5);
}
// error: 'fixed' is a val, and deposit changes it (through this): declare it with var
```

The compiler follows the reference through every call: a function that passes it on to one that
writes through it changes it too, and so do closures and fn values that do. Writing through a
reference made from a `val` (`val r = &x; *r = 1;`) is an error right away, and so is sorting a
slice of a `val` array. A reference a function returns points where its argument did, so writing
through what `x_of(&p)` returns changes `p`:

```volt fail
struct point {
    x: i32;
}

attach fn x_of(this: point&) -> i32& {
    return &this.x;
}

fn main() -> void {
    val p: point = { x: 0 };
    *p.x_of() = 1;
}
// error: 'p' is a val, and it's changed through what x_of returns: declare it with var
```

A reference keeps where it points when it's stored in a struct, tuple or array, passed or returned
inside one (or inside an error union), or assigned to a variable later:

```volt fail
struct holder {
    r: i32&;
}

fn main() -> void {
    val x = 0;
    val h: holder = { r: &x };
    *h.r = 1;
}
// error: can't assign through this; it reaches a val (or a parameter without var)
```

The references in one value share a verdict: when one of them points at a `val`, writing through
any of them is an error.

Calls into C, pointers made with `@cast`, ones an `await` gives, a reference stored through another
reference, and references kept in an enum's payload or in a struct that also owns memory through a
pointer (as a `std::vec` does) aren't checked.

A `val` is shallow: what its pointers and slices point at isn't part of it. A `val` slice of a `var`
array can still change the array's elements; a slice of a `val` array can't.

## Pointers

Pointers are for C interop and low-level code: they can be null, do arithmetic, and index without
bounds checks. `->` reaches a field through one. Dereferencing a null pointer stops the program in
debug builds.

```volt
use std::io;

struct node {
    key: i32;
    next: node*;                         // defaults to null
}

fn find(var cur: node*, key: i32) -> node* {
    while (cur) {                        // narrows: cur is a node& inside
        if (cur.key == key) {
            return cur;
        }
        cur = cur->next;
    }
    return null;
}

fn main() -> void {
    var c: node = { key: 3 };
    var b: node = { key: 2, next: &c };
    var a: node = { key: 1, next: &b };
    val hit = find(&a, 3);
    val miss = find(&a, 9);
    std::println("{} {}", hit->key, miss == null);
    var nums: i32[] = { 10, 20, 30 };
    val p: i32* = &nums[0];
    std::println("{} {}", p[2], *(p + 1));
}
// expect: 3 true
// expect: 30 20
```

`void*` is C's opaque pointer: `@cast` it to a real pointer type before using it.

## What references can't do

A reference can't be null, so it can't be optional either, and it can't be a struct field's default.
Store a `T*` when "none" has to be possible:

```volt fail
fn main() -> void {
    val x: i32&? = null;
}
// error: optional
```
