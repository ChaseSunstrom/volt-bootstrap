---
title: Namespaces, globals and packages
description: namespace blocks, use paths, globals, visibility, and how packages become namespaces.
sidebar:
  order: 13
---

## Namespaces

`namespace a { ... }` groups declarations; `a::name` reaches them. Namespaces nest (`namespace
a::b` is short for one inside the other), and the same namespace can be opened again in another
place or file.

```volt
use std::io;

namespace geo {
    struct vec2 { x: f64; y: f64; }

    fn len2(v: vec2) -> f64 {
        return v.x * v.x + v.y * v.y;
    }

    namespace units {
        fn to_cm(m: f64) -> f64 { return m * 100.0; }
    }
}

fn main() -> void {
    val v: geo::vec2 = { x: 3.0, y: 4.0 };
    std::println("{} {}", geo::len2(v), geo::units::to_cm(1.23));
}
// expect: 25 123
```

Inside a namespace, its own names (and those of the namespaces around it) are reachable without a
prefix.

## use

`use a::b::c;` makes `c`'s members reachable through the first namespace of the path, `a`: so
after `use std::io;`, `std::io::println` can be written `std::println`. When `c` is a single item
instead of a namespace, the item itself becomes `a::c`. The full path keeps working.

```volt
use std::io;
use app::util;

namespace app::util {
    fn twice(x: i32) -> i32 { return x * 2; }
}

fn main() -> void {
    std::println("{}", app::twice(21));
    std::io::println("full paths still work");
}
// expect: 42
// expect: full paths still work
```

Two `use`s that bring the same name into one namespace merge into one overload set. A method the
namespace attaches doesn't hide such a name either, since methods are called as `x.name()`: std
attaches `min` to slices, and after `use std::math;`, `std::min(a, b)` is still math's function.

`use { "header.h" } as c;` is different: it imports a C header into namespace `c`. See
[C interop](/volt-bootstrap/interop/c/).

## Globals

`val` and `var` work at the top level and in namespaces. A global's value must be known at compile
time (it can call `comptime` functions).

```volt
use std::io;

val LIMIT: i32 = 3 * 4;
var hits: i32 = 0;

fn record() -> void {
    hits += 1;
}

fn main() -> void {
    record();
    record();
    std::println("{} {}", LIMIT, hits);
}
// expect: 12 2
```

A `static` local keeps its value between calls: `static var calls: i32 = 0;` inside a function.

## Visibility

Declarations are public by default. `internal` marks one as belonging to its own package: code in
that package can use it, and anywhere else, naming it (a function, method, type or global) is a
compile error, `'helper' is internal to package mylib`. Templates are fine: a std template that
calls an internal helper still works when your program instantiates it.

```volt
internal fn helper() -> i32 { return 1; }

fn api() -> i32 { return helper() + 1; }
```

## Packages

A package is a directory of `.volt` files, and each of its files is wrapped in `namespace NAME`.
That's all std is: every std file is inside `namespace std`. You give voltc packages with
`--pkg NAME=DIR` (bolt does it for dependencies), and the program reaches them as `NAME::...`.
See [Packages and std](/volt-bootstrap/voltc/packages/).
