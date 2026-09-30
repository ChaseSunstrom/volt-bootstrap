---
title: The standard library
description: What std is, what's in it, and how to bring your own.
sidebar:
  order: 1
---

`std` is an ordinary package: a directory of `.volt` files that voltc compiles along with your
program (`--std DIR`, `$VOLT_STD`, or the `std/` next to voltc). Nothing in the compiler knows its
names, so you can replace it with your own.

Each file is wrapped in `namespace std`, and most declare a namespace of their own inside it:

| Module | What it has |
| --- | --- |
| [`std::io`](/volt-bootstrap/std/io/) | `println`, `print`, `eprintln`, `eprint`: formatted output, checked at compile time |
| [`std::fmt`](/volt-bootstrap/std/fmt/) | `format` (text as a `std::string`) and `write` (into any writer); format specifiers like `{:>8.2}` |
| [`std::text`](/volt-bootstrap/std/text/) | methods on `str`: search, trim, split, replace, case, parse numbers; UTF-8; ASCII classes on `u8`; `join` |
| [`std::string`](/volt-bootstrap/std/string/) | `string`: owned, growable UTF-8 text |
| [`std::vec`](/volt-bootstrap/std/vec/) | `vec<T>`: a growable array that owns its elements; `insert`, `remove`, `retain`, `dedup` |
| [`std::map`](/volt-bootstrap/std/map/) | `map<K, V>`: a hash map, `iter()` over its entries, and `hash` for the built-in key types |
| [`std::set`](/volt-bootstrap/std/set/) | `set<T>`: a hash set |
| [`std::sorted_map`](/volt-bootstrap/std/sorted_map/) | `sorted_map<K, V>`: a map that walks its keys in order |
| [`std::deque`](/volt-bootstrap/std/deque/) | `deque<T>`: a double-ended queue |
| [`std::heap`](/volt-bootstrap/std/heap/) | `heap<T>`: a priority queue, smallest first |
| [`std::slice`](/volt-bootstrap/std/slice/) | on any `T[..]`: stable `sort`, `sort_by`, `binary_search`, `reverse`, `contains`, `min`, `max` |
| [`std::compare`](/volt-bootstrap/std/compare/) | `eq` and `cmp`, which collections and algorithms compare values with |
| [`std::math`](/volt-bootstrap/std/math/) | constants, `sqrt`, `pow`, trig and the rest of libm (f64 and f32), `min`/`max`/`clamp`, integer limits, checked and saturating arithmetic, `gcd`/`lcm` |
| [`std::mem`](/volt-bootstrap/std/mem/) | allocators, `box<T>` (an owning pointer), `T::new`, `mem_error` |
| [`std::fs`](/volt-bootstrap/std/fs/) | reading and writing whole files |
| [`std::process`](/volt-bootstrap/std/process/) | running programs, arguments, the environment, `exit` |
| [`std::json`](/volt-bootstrap/std/json/) | JSON values: parse, build and print |

## Reaching the names

`use std::io;` makes `std::io`'s members reachable through the first namespace, so
`std::io::println` can be written `std::println`. The containers are declared directly in `std`
(`std::string`, `std::vec<T>`, `std::map<K, V>`; see [Collections](/volt-bootstrap/std/collections/)),
and `box` in `std::mem`.

```volt
use std::io;

fn main() -> !void {
    var names: std::vec<std::string> = {};
    try names.push(std::string::from("volt"));
    var ages: std::map<str, i32> = {};
    ages.put("volt", 1);
    val b: std::mem::box<i32> = try i32::new(5);
    std::println("{} {} {} {}", names.len, names.at(0).as_str(), *(ages.get("volt") ?? return), b);
}
// expect: 1 volt 1 5
```

## Your own std

A std binds what only the compiler can do through two attributes:

- `@attributes([@intrinsic("println")])` on a body-less `fn` makes it a compiler builtin (the
  formatted print functions) or, for a name starting with `volt_`, a function of the C runtime.
- `@attributes([@owns("ptr")])` on a struct makes it an owning pointer like `box`: it's used like a
  `T&`, and when it goes out of scope the value it points at is deleted first.

`tests/std_alt` in the repository is a std written from scratch. In bolt, `[std] path = "../mystd"`
picks one per package; `voltc --std DIR` does it by hand.

## Documentation from source

These pages come from `voltc doc std`, which prints a package's declarations and their comments as
JSON (the comment block directly above a declaration, or after a field on its line). Run it on your
own packages with `voltc doc NAME --pkg NAME=DIR`.
