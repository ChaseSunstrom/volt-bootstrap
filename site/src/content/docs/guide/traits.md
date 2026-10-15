---
title: Traits
description: Traits as constraints on templates, and as types without vtables.
sidebar:
  order: 9
---

A trait names a set of functions. A type attaches a trait by providing them in an
`attach trait -> type { ... }` block. Traits do two jobs.

A trait's functions are signatures only, with no default bodies. An attach block must provide every
one of them (but the [optional](#optional-functions-and-closed-traits) ones), each taking the same
number of arguments; it may add helpers of its own. The compiler
checks each block where it's written, so a missing function is reported at the block, not later in
some template that calls it.

## As constraints

`<T: shape>` says the template only accepts types that attach `shape`. A call with any other
type is an error at the call, naming the trait, instead of an error somewhere inside the body.
`+` joins bounds: `<T: shape + named>` takes the types that attach both.

```volt
use std::io;

trait shape {
    fn area(this) -> f64;
    fn name(this) -> str;
}

struct circle { r: f64; }
struct square { side: f64; }

attach shape -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
    fn name(this) -> str { return "circle"; }
}

attach shape -> square {
    fn area(this) -> f64 { return this.side * this.side; }
    fn name(this) -> str { return "square"; }
}

<T: shape>
fn report(s: T&) -> void {
    std::println("{}: {}", s.name(), s.area());
}

fn main() -> void {
    val c: circle = { r: 1.0 };
    val q: square = { side: 3.0 };
    report(&c);
    report(&q);
}
// expect: circle: 3
// expect: square: 9
```

Inside an `attach` block, `this` can leave out its type.

## Optional functions and closed traits

A trait fn marked `@optional` may be left out of an attach block. A template asks whether a type
wrote it with `@has_method(T, "name")`, at compile time, so the call costs nothing either way. A
trait marked `@closed` holds its blocks to its own functions, taking its parameters' types: a
misspelt one is an error at the block rather than a helper nobody calls.

```volt
use std::io;

@attributes([@closed])
trait greeter {
    fn name(this) -> str;
    @attributes([@optional])
    fn greeting(this) -> str;
}

struct en { }
struct fr { }

attach greeter -> en {
    fn name(this) -> str { return "en"; }
}

attach greeter -> fr {
    fn name(this) -> str { return "fr"; }
    fn greeting(this) -> str { return "bonjour"; }
}

<T: greeter>
fn greet(g: T&) -> void {
    comptime if (@has_method(T, "greeting")) {
        std::println("{}: {}", g.name(), g.greeting());
    } else {
        std::println("{}: hello", g.name());
    }
}

fn main() -> void {
    val a: en = {};
    val b: fr = {};
    greet(&a);
    greet(&b);
}
// expect: en: hello
// expect: fr: bonjour
```

A struct marked `@attributes([@attach_as("name")])` stands for that trait: `attach S -> T` and
`<T: S>` mean `name`. That's how a [C++ class's](/volt-bootstrap/interop/cpp/) virtual methods are
overridden, by attaching the class.

## As types

Used as a type, a trait is a **tagged union** of every type in the program that attaches it: the
compiler sees the whole program, so the list is known. Values are stored inline (the size of the
largest member plus a tag), and a call is a switch on the tag followed by a direct call. There are
no vtables and no heap allocation.

```volt
use std::io;

trait shape {
    fn area(this) -> f64;
}

struct circle { r: f64; }
struct square { side: f64; }

attach shape -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
}

attach shape -> square {
    fn area(this) -> f64 { return this.side * this.side; }
}

fn main() -> void {
    val c: circle = { r: 2.0 };
    val q: square = { side: 1.5 };
    val shapes: shape[] = { c, q };
    var total = 0.0;
    for (s&) in shapes {
        total += s.area();
    }
    std::println("{}", total);
    match (shapes[0]) {                          // get the real type back
        circle(ci) => std::println("circle of radius {}", ci.r),
        square(sq) => std::println("square of side {}", sq.side),
    }
}
// expect: 14.25
// expect: circle of radius 2
```

A trait union also satisfies `<T: shape>`, so the same template takes one concrete shape (no tag
at all) or a mix.

Things to keep in mind:

- The union is as big as its largest member. Box a member that's much bigger than the rest.
- The member list is closed when the program is compiled: a precompiled library can't add members to
  a trait union later.
- A static function (`static this`) of the trait is called through a value: `v.kind_name()` calls
  `circle::kind_name()` when `v` holds a circle. `v` is evaluated once and only its tag is read.
  `shape::kind_name()` is an error, since no value says which member's to call.
- A trait that nothing attaches is still a type, one with no values: code taking a `plugin&`, a
  `plugin?` field or a `plugin[..]` compiles (calls through it check against the trait's functions;
  a `match` on it needs no arms), and runs with values once a type in the program attaches it.
  Nothing can make one before that: a literal, `x as plugin` or a coercion is an error. It's the
  size of the tag, 2 bytes.
- A precompiled library (`voltc lib`) can declare such a trait and take it as a parameter. A
  function with a trait union in its parameters or result is never taken from the library: each
  program builds it with that program's member list, so a type the program attaches reaches it.
  A package with a global whose type holds a trait union isn't taken from its library at all: the
  program builds it from source (and the linked packages that use it), with a warning naming the
  global, since the library's code that touches the global was built with the library's member list. A local inside a function compiled
  without the trait in its signature still sees the library's member list, none here: keep trait
  values in signatures.
- `@typeid(v)` of a trait value is the id of the type it holds, the same id `@typeid(circle)` gives;
  see [type ids](/volt-bootstrap/guide/comptime/#type-ids-typeid).

## Generic trait functions and generic traits

Trait functions can be templates, and a trait can take parameters itself:

```volt
use std::io;

<T: type>
trait source {
    fn next(this) -> T?;
}

struct countdown { n: i32; }

attach source<i32> -> countdown {
    fn next(this) -> i32? {
        if (this.n == 0) {
            return null;
        }
        this.n -= 1;
        return this.n + 1;
    }
}

fn main() -> void {
    var c: countdown = { n: 3 };
    while (true) {
        val v = c.next() ?? break;
        std::print("{} ", v);
    }
    std::println("");
}
// expect: 3 2 1
```

A generic type attaches a generic trait for all its instances at once,
`<T: type> attach source<T> -> stream<T> { ... }`, and a bound gives the trait's arguments:
`<S: source<i32>>`.

std's allocator is a trait whose functions are templates: `std::mem::allocator` has
`<T: type> fn malloc(this, count: usize = 1) -> mem_error!(T*)`, `realloc` and `free`, and
`box<T, Allocator>` and `vec<T, Allocator>` work with any type that attaches it.
