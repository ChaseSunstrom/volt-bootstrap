---
title: Structs and methods
description: Structs, field defaults, literals, attached functions, static functions and C layout.
sidebar:
  order: 3
---

## Structs

A struct has named fields. A field can have a default, which a literal may leave out; pointer
fields default to `null`. A struct literal is `{ field: value, ... }`, typed by where it goes.

```volt
use std::io;

struct window {
    title: str;
    width: i32 = 800;
    height: i32 = 600;
}

fn area(w: window) -> i32 {
    return w.width * w.height;
}

fn main() -> void {
    val w: window = { title: "editor", width: 1024 };
    val title = "shell";
    val v: window = { title };                       // shorthand for title: title
    std::println("{} {}", area(w), area(v));
    std::println(w);                                  // structs print their fields
}
// expect: 614400 480000
// expect: window { title: editor, width: 1024, height: 600 }
```

Leaving out a field that has no default is an error:

```volt fail
struct pair { a: i32; b: i32; }

fn main() -> void {
    val p: pair = { a: 1 };
}
// error: missing field 'b'
```

When the type is known, the fields can also come in declaration order, without names; a bare name
in its own field's place still reads as that field (`{ move segs, span }`). A local moves into a
field without `move` (using it afterwards is an error that says where it moved), as it does into an
argument or a `return`:

```volt
use std::io;
struct span { lo: u32; hi: u32; }
struct path { segs: std::vec<i32>; at: span; tag: u8 = 9; }

fn main() -> void {
    var segs: std::vec<i32> = {};
    segs.push(4);
    val at: span = { 3, 8 };                         // lo, then hi
    val p: path = { segs, at };                      // by name: segs moves in
    std::println("{} {} {}", p.segs.len, p.at.hi, p.tag);
}
// expect: 1 8 9
```

A literal gives its fields all by name or all in order: `{ x: 1, 2 }` is an error, as is a bare name
in another field's place.

A literal can start from another value: `{ ..base, field: value }` is `base` with the named fields
replaced, and its type is base's when nothing else gives one. It takes base the way
`var t = base;` would: a plain struct is copied, one that owns memory moves (`..copy base` keeps
it), and a replaced field's old value is deleted. Through a reference (`this` in a method) base is
the value it reaches, so an update never writes through it. The new values are worked out after
base is taken, so they can read a copied base, not a moved one.

```volt
use std::io;

struct window {
    title: str;
    width: i32 = 800;
    height: i32 = 600;
}

struct note {
    text: std::string;
    pinned: bool = false;
}

fn main() -> void {
    val w: window = { title: "editor", width: 1024 };
    val wide = { ..w, width: w.width * 2 };
    val turned: window = { ..w, width: w.height, height: w.width };
    std::println("{} {} {}", wide.width, turned.width, turned.height);

    val n: note = { text: std::string::from("buy milk") };
    val kept: note = { ..copy n, pinned: true };          // n is still there
    std::println("{} {}", n.text.as_str(), kept.pinned);
}
// expect: 2048 600 1024
// expect: buy milk true
```

An empty struct (`struct marker {}` or `struct marker;`) takes no space.

## Methods

Methods are declared outside the struct with `attach fn`. The first parameter, `this`, says what
they attach to: `this: T&` works on the caller's value (and can change it when it's a `var`),
`this: T` gets a copy.

```volt
use std::io;

struct counter {
    count: i32 = 0;
}

attach fn bump(this: counter&, by: i32) -> void {
    this.count += by;
}

attach fn doubled(this: counter) -> i32 {
    return this.count * 2;
}

fn main() -> void {
    var c: counter = {};
    c.bump(3);
    c.bump(4);
    std::println("{} {}", c.count, c.doubled());
}
// expect: 7 14
```

`.` reaches through a reference, so `this.count` works on a `counter&`.

### Static functions

`static this: T` attaches a function to the type rather than to a value: it's called as
`T::name(...)`, usually to build one.

```volt
use std::io;

struct rgb {
    r: u8;
    g: u8;
    b: u8;
}

attach fn gray(static this: rgb, level: u8) -> rgb {
    return { r: level, g: level, b: level };
}

fn main() -> void {
    val c = rgb::gray(128);
    std::println("{} {} {}", c.r, c.g, c.b);
}
// expect: 128 128 128
```

### Attaching to any type

Methods can attach to any type, including ones you didn't declare, like `i32` or `str`.

```volt
use std::io;

attach fn squared(this: i32) -> i32 {
    return this * this;
}

attach fn shout(this: str) -> void {
    std::println("{}!", this);
}

fn main() -> void {
    val n = 7;
    std::println("{}", n.squared());
    "hey".shout();
}
// expect: 49
// expect: hey!
```

Two attached functions named `delete` and `copy` are hooks the compiler calls: see
[Ownership](/volt-bootstrap/guide/ownership/).

### Operators

`attach operator` gives a struct or an enum an operator. It's a method under another name: the left
operand is `this`, the right one the other parameter, and overloads pick by the right operand's
type, like any function's.

```volt
use std::io;

struct vec2 {
    x: f64;
    y: f64;
}

attach operator +(this: vec2, o: vec2) -> vec2 {
    return { x: this.x + o.x, y: this.y + o.y };
}

attach operator -(this: vec2) -> vec2 {
    return { x: -this.x, y: -this.y };
}

attach operator *(this: vec2, k: f64) -> vec2 {
    return { x: this.x * k, y: this.y * k };
}

attach operator <(this: vec2, o: vec2) -> bool {
    return this.x * this.x + this.y * this.y < o.x * o.x + o.y * o.y;
}

fn main() -> void {
    val a: vec2 = { x: 1.0, y: 2.0 };
    var pos = a + a * 2.0;
    pos += -a;
    std::println("{} {} {}", pos.x, pos.y, a < pos);
}
// expect: 2 4 true
```

These can be attached:

| Operator | Parameters | Gives |
| --- | --- | --- |
| `+ - * / % & \| ^ << >>` | `this` and the right operand | `a op b`, and `a op= b` as `a = a op b` |
| `-` `~` | `this` | `-a`, `~a` |
| `<` | `this` and the right operand | `a < b`; `a > b` is `b < a`, `a <= b` is `!(b < a)`, `a >= b` is `!(a < b)` |
| `==` | `this` and the right operand, both `T&` | `a == b` and `a != b`; it's the type's [`eq`](/volt-bootstrap/guide/basics/#operators) |
| `[]` | `this` and the index | `a[i]`; when it returns a `T&`, `a[i]` is a place: `a[i] = x` and `a[i] += x` work |

- Operands are still evaluated left to right, even when `a > b` runs as `b < a`.
- A right operand taken by reference (`o: T&`) lends its address; a temporary one lives until the
  call is done, so `a + (b + c)` works.
- `a += b` evaluates the place `a` once; the old value is deleted like on `a = a + b`.
- Built-in types keep their own operators, and `&& || ?? = .` and the wrapping `+% -% *%` can't be
  attached. Neither can `> <= >= != +=`: they come from `<`, `==` and `+`.
- The left operand picks the operator: `v * 2.0` can be attached to `vec2`, `2.0 * v` can't.

```volt
use std::io;

struct grid {
    cells: i32[4];
}

attach operator [](this: grid&, i: usize) -> i32& {
    return &this.cells[i];
}

fn main() -> void {
    var g: grid = { cells: { 0; 4 } };
    g[1] = 5;
    g[1] += 2;
    std::println("{}", g[1]);
}
// expect: 7
```

## Generic structs

A struct can take generic parameters, with defaults:

```volt
use std::io;

<T: type, N: usize = 4>
struct ring {
    items: T[N];
    next: usize = 0;
}

<T: type, N: usize>
attach fn add(this: ring<T, N>&, x: T) -> void {
    this.items[this.next % N] = x;
    this.next += 1;
}

fn main() -> void {
    var r: ring<i32> = { items: { 0, 0, 0, 0 } };
    for (i) in 1..=6 {
        r.add(i);
    }
    std::println("{} {}", r.items[0], r.items[1]);
}
// expect: 5 6
```

More in [Templates](/volt-bootstrap/guide/templates/).

## Layout

The compiler may reorder a struct's fields to save padding. `extern struct` keeps C's layout
(declaration order, C alignment), for structs that cross into C:

```volt
extern struct c_point {
    x: i32;
    y: f64;
}
```

`@sizeof(T)`, `@alignof(T)` and `@offsetof(T, field)` give a type's layout at compile time.
