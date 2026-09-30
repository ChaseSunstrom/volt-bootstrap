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
