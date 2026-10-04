---
title: Comptime
description: Code that runs in the compiler, types as values, @typeinfo, @cfg and attributes.
sidebar:
  order: 11
---

Volt can run ordinary code while compiling. The results become constants, types or whole branches
of the program.

## comptime functions

A `comptime fn` always runs in the compiler; its calls are replaced by their results.

```volt
use std::io;

comptime fn fib(n: i32) -> i64 {
    var a: i64 = 0;
    var b: i64 = 1;
    for (i) in 0..n {
        val t = a + b;
        a = b;
        b = t;
    }
    return a;
}

comptime fn squares() -> i32[5] {
    var out: i32[5] = { 0, 0, 0, 0, 0 };
    for (i) in 0..5 {
        out[i] = i * i;
    }
    return out;
}

val TABLE_LEN: usize = fib(10);

fn main() -> void {
    var table: u8[TABLE_LEN];
    std::println("{} {} {}", fib(50), squares(), table.len);
}
// expect: 12586269025 { 0, 1, 4, 9, 16 } 55
```

A comptime error (overflow, an out-of-bounds index, a runaway loop) is a compile error.

## Types as values

`type` is a type, so a comptime function can compute one, and a variable can hold one.

```volt
use std::io;

comptime fn counter_type(big: bool) -> type {
    if (big) {
        return i64;
    }
    return i8;
}

fn main() -> void {
    val x: counter_type(true) = 5000000000;
    std::println(x);
}
// expect: 5000000000
```

## comptime if, match and for

Inside any function, `comptime if`, `comptime match` and `comptime for` are decided in the
compiler. A branch that isn't taken isn't even checked; a `comptime for` unrolls. In a `comptime if`
chain every `else if` is decided in the compiler too, and `else comptime if` makes one branch of a
run-time `if` a compile-time choice.

```volt
use std::io;

<C: i32>
fn classify() -> str {
    comptime match (C) {
        0 => { return "zero"; },
        c if c > 100 => { return "big"; },
        default => { return "other"; },
    }
}

<N: i32>
fn wide() -> i64 {
    comptime var T: type;
    comptime if (N > 0) {
        T = i64;
    } else {
        T = i8;
    }
    var v: T = 100;
    return v as i64;
}

fn main() -> void {
    std::println("{} {} {}", classify<0>(), classify<500>(), wide<1>());
    comptime for (i) in 0..3 {
        std::print(i);
    }
    std::println("");
}
// expect: zero big 100
// expect: 012
```

## Reflection: @typeinfo and @typeof

`@typeof(expr)` is an expression's type. `@typeinfo(T)` describes a type at compile time: its name,
size, alignment, kind (with fields, variants, element types) and more.

```volt
use std::io;

struct point {
    x: i32;
    y: i64;
}

<T: type>
fn name_of(v: T) -> str {
    return @typeinfo(T).short_name;
}

fn main() -> void {
    val p: point = { x: 1, y: 2 };
    std::println("{} {} {}", name_of(p), name_of(1.5), @typeinfo(@typeof(p)).size.value);
    std::println(@typeinfo(std::mem::box<i32>).canonical_name);
}
// expect: point f64 16
// expect: std::mem::box<i32, std::mem::default_allocator>
```

`@field(v, "name")` is `v.name` with the name worked out at compile time: read it, assign to it,
take its address. `@has_field(T, "name")` asks whether struct `T` has that field. With a
`comptime for` over `@typeinfo`'s fields, code over any struct is a few lines:

```volt
use std::io;

struct point {
    x: i32;
    y: i32;
}

<T: type>
fn same(a: T&, b: T&) -> bool {
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                if (@field(a, f.name) != @field(b, f.name)) {
                    return false;
                }
            }
        },
        default => {},
    }
    return true;
}

<T: type>
fn show(v: T&) -> std::string {
    var out = std::string::from(@typeinfo(T).short_name);
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                std::fmt::write(&out, " {}={}", f.name, @field(v, f.name));
            }
        },
        default => {},
    }
    return move out;
}

fn main() -> void {
    var p: point = { x: 1, y: 2 };
    val q: point = { x: 1, y: 2 };
    std::println("{} {}", same(&p, &q), @has_field(point, "y"));
    @field(p, "y") = 5;
    std::println("{}", show(&p));
}
// expect: true true
// expect: point x=1 y=5
```

`@compile_error("message")` fails compilation when it's reached, for custom checks in templates.

## Does a type attach a trait: @attaches

`@attaches(T, some_trait)` is `true` when `T` attaches the trait, the same test a `<T: some_trait>` bound
makes. A template can use what a type offers and do without what it doesn't:

```volt
use std::io;

trait measured {
    fn area(this) -> f64;
}

trait named {
    fn name(this) -> str;
}

struct circle { r: f64; }
struct square { side: f64; }

attach measured -> circle {
    fn area(this) -> f64 { return 3.0 * this.r * this.r; }
}

attach measured -> square {
    fn area(this) -> f64 { return this.side * this.side; }
}

attach named -> square {
    fn name(this) -> str { return "square"; }
}

<T: measured>
fn describe(s: T&) -> void {
    comptime if (@attaches(T, named)) {
        std::println("{}: {}", s.name(), s.area());
    } else {
        std::println("something: {}", s.area());
    }
}

fn main() -> void {
    val c: circle = { r: 1.0 };
    val q: square = { side: 2.0 };
    describe(&c);
    describe(&q);
}
// expect: something: 3
// expect: square: 4
```

A generic trait takes its arguments: `@attaches(T, source<i32>)`.

`@has_method(T, "name")` is `true` when `T` has a method of that name, attached by an `attach fn`
or an attach block. Types after the name ask for a method whose first arguments (after `this`) are
of those types: `@has_method(T, "draw", canvas&)`. With a trait's `@optional` functions, it's how a
template asks which ones a type wrote (see
[Traits](/volt-bootstrap/guide/traits/#optional-functions-and-closed-traits)).

## Type ids: @typeid

`@typeid(T)` is a `u64` naming a type: the 64-bit FNV-1a hash of its canonical name (the
`canonical_name` `@typeinfo` gives). It's worked out by the compiler, so it costs nothing at run
time, and because it comes from the name it's the same in every build, in every library and from
either compiler. Use it as a map key, or in tables built at compile time.

`@typeid(x)` of a value is its type's id, without running `x`. For a trait value, or a reference
to one, it's the id of the type the value holds, read from its tag: what C++'s `typeid` gives for an
object with virtual functions, with no type information stored in the program.

`@typeinfo` of a trait used as a type lists every type that attaches it, so a `comptime for` can
fill a registry with all of them:

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
    // one name per type that attaches shape, keyed by type id
    var names: std::map<u64, str> = {};
    comptime match (@typeinfo(shape).kind) {
        .TRAIT_UNION(u) => {
            comptime for (t) in u.1 {
                names.put(@typeid(t), @typeinfo(t).short_name);
            }
        },
        default => {},
    }
    val c: circle = { r: 1.0 };
    val q: square = { side: 2.0 };
    val shapes: shape[] = { c, q };
    for (s&) in shapes {
        std::print("{}:{} ", *names.get(@typeid(s)), s.area());
    }
    std::println("{}", @typeid(c) == @typeid(circle));
}
// expect: circle:3 square:4 true
```

Two different names could in principle hash to the same id; with 64 bits that's less than one chance in
10^11 for a program with ten thousand types.

## Configuration: @cfg

`@cfg("key")` is true when `--cfg key` (or `key=...`) was given; `@cfg("key", "value")` when
`--cfg key=value` was. bolt passes a package's enabled features as `feature=NAME`. A branch that's
off isn't checked, so it can use a dependency that isn't there.

```volt
use std::io;
// flags: --cfg feature=fast --cfg level=3

fn speed() -> str {
    comptime if (@cfg("feature", "fast")) {
        return "fast";
    }
    return "normal";
}

fn main() -> void {
    std::println("{} {} {}", speed(), @cfg("level"), @cfg("level", "2"));
}
// expect: fast true false
```

`--cfg pkg:key=value` sets a key for package `pkg`'s files only.

`@cfg("release")` is true in a `--release` build, for code that trades checks for speed. std's
default allocator uses it: debug builds check every free against the block's size, release builds
skip the check and take small blocks from free lists.

### The target

Three keys describe the platform being built for. Every package sees them without any `--cfg`:

| Key | Values |
| --- | --- |
| `os` | `linux`, `macos`, `windows`, `freebsd`, or `none` on [bare metal](/volt-bootstrap/voltc/bare-metal/) |
| `arch` | `x86_64`, `aarch64`, `riscv64`, `riscv32`, `x86`, `arm` |
| `pointer_bits` | `64` or `32` |

A library uses them to pick per-platform code, and the branches for other platforms aren't checked.
At run time, `std::process::os()` and `std::process::arch()` give the same names.
`@cfg("hosted")` is true when there's an OS at all (`os` isn't `none`), for code that needs files,
threads or a clock, and `@cfg("unix")` when it's a POSIX system (Linux, macOS or FreeBSD), for code
Windows does differently. With `--cfg os=...` they follow the `os` given.

`@cfg` also goes on a declaration, as an attribute: the declaration is only in builds where it holds,
and in others it isn't even checked. On a namespace it covers everything inside:

```volt
use std::io;
// flags: --cfg feature=fast

@attributes([@cfg("feature", "fast")])
fn speed() -> str { return "fast"; }

@attributes([@cfg("feature", "slow")])
fn speed() -> str { return "slow"; }

@attributes([@cfg("os", "none")])
namespace board {
    fn blink() -> void {}
}

fn main() -> void {
    std::println(speed());
}
// expect: fast
```

The keys describe the host. Passing one with `--cfg`, such as `--cfg os=windows`, replaces the host's
value for every package. `voltc check --cfg os=windows` then checks another platform's branches on
this machine. Only checking makes sense this way: a build still runs on the host, and
`std::process::os()` still reports the host.

```volt
use std::io;

fn line_end() -> str {
    comptime if (@cfg("os", "windows")) {
        return "\r\n";
    }
    return "\n";
}

fn main() -> void {
    std::print("{} on {}{}", std::process::os() == "windows", @cfg("pointer_bits", "64"), line_end());
}
// expect: false on true
```

## Attributes

`@attributes([...])` before a declaration attaches compile-time attributes. Only known ones are
accepted, so a typo is an error.

| Attribute | Meaning |
| --- | --- |
| `@inline`, `@noinline` | inlining hints |
| `@opt(n)` | optimization level for this function (0 to 3) |
| `@section(".name")` | put the function in a section |
| `@align(n)` | alignment |
| `@deprecated("use x")` | warn where it's used |
| `@intrinsic("name")` | a compiler builtin or runtime function (for std-like libraries) |
| `@owns("field")` | this struct owns what the field points at, like `box` |
| `@export_text("method")` | an export fn returning this struct hands other languages its text, as `method()` gives it (std's `string` has it) |
| `@thread_local` | a global `var` each thread has its own copy of, starting from its initial value |
| `@cfg("key")`, `@cfg("key", "value")` | the declaration is only in builds where this `@cfg` holds; on a namespace, everything in it |
| `@optional` | on a trait fn: attach blocks may leave it out (`@has_method` says which did) |
| `@closed` | on a trait: its attach blocks hold its fns and nothing else, with its parameter types |
| `@attach_as("trait")` | on a struct: `attach S -> T` and `<T: S>` mean that trait (how a C++ class's virtual methods are overridden) |

```volt
use std::io;

@attributes([@deprecated("use total")])
fn sum(a: i32, b: i32) -> i32 {
    return a + b;
}

@attributes([@inline])
fn total(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> void {
    std::println("{}", total(1, 2));
}
// expect: 3
```

A `@thread_local` global needs no lock: each thread reads and writes its own.

```volt
use std::io;
use std::thread;

@attributes([@thread_local])
var calls: i32 = 0;

fn count() -> void {
    calls += 1;
    std::println("{}", calls);
}

fn main() -> !void {
    count();
    count();
    var t = try std::thread::spawn(|| () { count(); });
    t.join();
    count();
}
// expect: 1
// expect: 2
// expect: 1
// expect: 3
```
