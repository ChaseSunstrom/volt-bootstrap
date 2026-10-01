---
title: Ownership
description: Owners and scopes, delete and copy hooks, moves, box<T>, defer, and leak checking.
sidebar:
  order: 6
---

Volt has no garbage collector. Every value has one owner (a variable, a field, an element), and
when the owner's scope ends the value is **deleted**: the compiler inserts the call. Deletes run in
reverse order of declaration, and a struct's fields are deleted after the struct's own hook.

## The delete hook

A type that holds a resource attaches `fn delete(this: T&)`. It runs automatically, exactly once;
calling it by hand is an error.

```volt
use std::io;

struct file {
    name: str;
}

attach fn delete(this: file&) -> void {
    std::println("closing {}", this.name);
}

fn main() -> void {
    val a: file = { name: "a.txt" };
    {
        val b: file = { name: "b.txt" };
        std::println("inner scope ends");
    }
    std::println("main ends");
}
// expect: inner scope ends
// expect: closing b.txt
// expect: main ends
// expect: closing a.txt
```

Types made of owned parts (a struct with a `std::vec` field, say) need no hook: each field is
deleted when the struct is.

### Temporaries

A value nobody keeps, like the result of `make("a")` below, is a temporary. It's deleted at the end
of the statement it's in, so `make("a").view()` can be used anywhere in that statement, even when
the result points into it (`word().as_str()` as an argument). In a `val` or `var`'s initializer,
it lives as long as the variable instead, and so does one in a `break` value that the initializer's
block gives. A `defer`'s statement keeps its own until it's done.

```volt
use std::io;

struct note {
    text: str;
}

attach fn delete(this: note&) -> void {
    std::println("delete {}", this.text);
}

attach fn view(this: note&) -> str {
    return this.text;
}

fn make(t: str) -> note {
    return { text: t };
}

fn main() -> void {
    std::println("{}", make("a").view()); // deleted after this statement
    val kept = make("b").view();          // deleted when kept goes out of scope
    std::println("{} still here", kept);
}
// expect: a
// expect: delete a
// expect: b still here
// expect: delete b
```

## Moves

Using an owned value by value (passing it, returning it, assigning it) **moves** it: the new place
owns it, and the old one is no longer usable. `move x` says so explicitly. The compiler tracks moves
through branches and loops, and using a moved value is a compile error:

```volt fail
use std::io;

fn consume(v: std::vec<i32>) -> void {}

fn main() -> void {
    val v: std::vec<i32> = {};
    consume(v);
    std::println("{}", v.len);
}
// error: 'v' was moved earlier
```

Moving inside a loop is also an error (the second time around there'd be nothing to move). Values
that own nothing, like numbers and plain structs, are copied instead of moved.

To lend a value without giving it up, pass a reference:

```volt
use std::io;

fn total(v: std::vec<i32>&) -> i32 {        // borrows: the caller keeps v
    var sum = 0;
    for (x) in v.items() {
        sum += x;
    }
    return sum;
}

fn main() -> !void {
    var v: std::vec<i32> = {};
    try v.push(2);
    try v.push(3);
    std::println("{} {}", total(&v), v.len);
}
// expect: 5 2
```

A reference never owns anything: nothing is deleted through a `T&`.

## Copies

`copy x` makes a second, independent value. For a type with a `delete` hook, copying needs a
`copy` hook too, or both copies would delete the same resource:

```volt
use std::io;

struct token {
    id: i32;
}

attach fn delete(this: token&) -> void {
    std::println("revoke {}", this.id);
}

attach fn copy(this: token&) -> token {
    return { id: this.id + 100 };
}

fn main() -> void {
    val a: token = { id: 1 };
    val b = copy a;
    std::println("{} {}", a.id, b.id);
}
// expect: 1 101
// expect: revoke 101
// expect: revoke 1
```

std's containers attach `copy`, so `copy v` on a `vec` copies its elements.

## box: owning heap memory

`std::mem::box<T>` owns one value on the heap. `T::new(value)` makes one (allocation can fail, so
it's an error union); a box is used like a `T&`, and deleting the box deletes the value and frees
the memory.

```volt
use std::io;

struct node {
    value: i32;
    next: std::mem::box<node>?;
}

fn sum(n: node&) -> i32 {
    if (n.next) {                        // narrows the field: a box, used like a node&
        return n.value + sum(n.next);
    }
    return n.value;
}

fn main() -> !void {
    val tail = try node::new({ value: 3, next: null });
    val head: node = { value: 1, next: try node::new({ value: 2, next: tail }) };
    std::println("{}", sum(&head));
}
// expect: 6
```

`box` is an ordinary std type: `@attributes([@owns("ptr")])` is what makes a struct an owning
pointer, and a library can make its own.

## defer

Deletes handle memory and anything with a hook. For other cleanup (unlocking, logging, closing a C
handle) use `defer`, which runs when the scope ends, and `errdefer`, which runs only when it ends by
returning an error. See [Errors](/volt-bootstrap/guide/errors/#defer-and-errdefer).

## Checks

Debug builds stop the program on a double free. `--leak-check` makes a debug build exit with
code 102 if any allocation was never freed:

```sh
voltc run app.volt --leak-check
```
