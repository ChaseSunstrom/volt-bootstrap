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

## Types built at compile time

`struct { ... }` and `enum { ... }` are values too: a comptime function can build a type and return
it. Inside the body, `comptime for` and `comptime if` work out the members, and a name that isn't a
bare identifier is computed: `f.name`, `names[i]`, or `(expr)` for any expression giving a `str`.

```volt
use std::io;

struct particle {
    x: f32;
    y: f32;
    alive: bool;
}

// one vector per field of T: a struct of arrays
comptime fn soa(T: type) -> type {
    return struct {
        comptime for (f) in @typeinfo(T).fields {
            f.name: std::vec<f.field_type> = {};
        }
    };
}

// a variant for each name, numbered from base
comptime fn codes(names: str[3], base: i32) -> type {
    return enum {
        comptime for (i) in 0..3 {
            names[i] = base + i,
        }
    };
}

type status = codes({ "OK", "MOVED", "GONE" }, 200);

fn main() -> void {
    var ps: soa(particle) = {};
    ps.x.push(1.5);
    ps.alive.push(true);
    std::println("{} {} {}", ps.x.len, ps.x[0], @typeinfo(soa(particle)).short_name);
    std::println("{}", status::GONE as i32);
}
// expect: 1 1.5 soa(particle)
// expect: 202
```

- A comptime function called with the same arguments gives the same type: `soa(particle)` written
  twice is one type, so methods attached to it work on every value of it.
- The type is named after the call (`soa(particle)`) in errors, `@typeinfo` and the editor. A body
  written right in a type alias, `type point3 = struct { x: f64; y: f64; z: f64 = 1.0; };`, takes
  the alias's name.
- Field types and enum values are worked out when the type is built, so they can use the loop
  variables; so can defaults that are numbers, bools or strings.
- A computed name has to be an identifier and can't repeat. `str + str` joins strings at compile time:
  `(prefix + "_count"): i32;`.
- `voltc expand` shows each built type's members where it's built.

### Functions a comptime function declares

A `fn` or `attach fn` written in a comptime function's body is declared when the function runs. Its
body sees the function's compile-time values as constants: parameters, the types it built, loop
variables. Its name can be worked out too: `fn (expr)(...)`. A top-level `comptime f(args);` runs
`f`, which returns `void`, for the functions it declares.

```volt
use std::io;

struct particle {
    x: f32;
    y: f32;
}

// a struct of arrays with its own push
comptime fn soa(T: type) -> type {
    val S = struct {
        comptime for (f) in @typeinfo(T).fields {
            f.name: std::vec<f.field_type> = {};
        }
    };
    attach fn push(this: S&, v: T) -> void {
        comptime for (f) in @typeinfo(T).fields {
            @field(this, f.name).push(@field(v, f.name));
        }
    }
    return S;
}

// a variant per name, and a lookup by text; T[] takes the argument's length
comptime fn codes(names: str[], base: i32) -> type {
    val E = enum {
        comptime for (i) in 0..names.len {
            names[i] = base + @cast<i32>(i),
        }
    };
    attach fn parse(static this: E, text: str) -> E? {
        comptime for (v) in @typeinfo(E).variants {
            if (text == v.name) {
                return @field(E, v.name);
            }
        }
        return null;
    }
    return E;
}

type status = codes({ "OK", "MOVED", "GONE" }, 200);

// get_x() and get_y()
comptime fn getters(T: type) -> void {
    for (f) in @typeinfo(T).fields {
        attach fn ("get_" + f.name)(this: T&) -> f.field_type {
            return @field(this, f.name);
        }
    }
}

comptime getters(particle);

fn main() -> void {
    var ps: soa(particle) = {};
    ps.push({ x: 1.0, y: 2.0 });
    val p: particle = { x: 3.0, y: 4.0 };
    std::println("{} {}", ps.y.len, p.get_y());
    std::println("{}", (status::parse("GONE") ?? status::OK) as i32);
}
// expect: 1 4
// expect: 202
```

- The functions live in the comptime function's namespace. Their bodies are checked when they're
  first used, like a generic instance's.
- A declaration made again with the same values is the one already made, so `soa(particle)` written
  twice has one `push`.
- A `var` the body sees is its value at the time of the declaration.
- `@field(E, name)` on an enum type is its variant called `name`.

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
size, alignment, kind (with fields, variants, element types) and more. Its `fields` and `variants`
are a struct's fields and an enum's variants (empty for other types), ready for a `comptime for`,
and its `methods` are the fns attached to the type (any type: `i32`'s too), in the order they're
declared: each one's `name`, the `trait` it's attached for (`""` when none) and its `params` (their
names, after `this`). `@field(v, m.name)(args)` calls one ([Code that writes
code](/volt-bootstrap/guide/metaprogramming/#code-from-the-fns-attached-to-any-type)). `borrows` says
whether a value of it points into something it doesn't own (a reference or slice in it, a closure's
capture by reference), so it mustn't be kept past what it points at.

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
    return out;
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

## Derive

`@attributes([@derive(eq, hash, fmt, json)])` on a struct gives it methods written in Volt, in
`std::derive`: `eq(other)` field by field (and so `==` and `!=`), `hash()` (so it can be a map
key), `to_string()` (the text `println` prints) and `to_json()` (an object with a member each
field). Copying needs no derive: `copy x` copies any struct field by field. On an enum, `eq` and
`hash` go by the variant and its payload; `to_json` is the variant's name, or for a variant with a
payload an object with one member, the variant's name: `{"KEY":97}`, a tuple payload as an array
(`{"CLICK":[10,20]}`). A JSON number is an `f64`, so an integer field past 2^53 loses its low bits
in `to_json`.

```volt
use std::io;

@attributes([@derive(eq, hash, json)])
struct point {
    x: i32;
    y: i32;
}

fn main() -> void {
    val a: point = { x: 1, y: 2 };
    val b: point = { x: 1, y: 2 };
    var seen: std::map<point, str> = {};
    seen.put(a, "first");
    std::println("{} {} {}", a == b, *seen.get(b), a.to_json().text());
}
// expect: true first {"x":1,"y":2}
```

Over an enum, a derive reads which variant a value holds with `@discriminant(v)`, the number
`@typeinfo` lists each variant's `discriminant` as, and a variant's payload as a field:
`@field(v, variant.name)` (see [Payloads](/volt-bootstrap/guide/enums-match/#payloads)). A tuple's
elements are `@field(t, i)` with `i` a comptime integer.

A derive is a trait with no functions, and methods that are generic over the types attaching it:
`@derive(eq)` is `attach std::derive::eq -> point {}`. A name that isn't a trait in scope is
`std::derive`'s. A derive of your own is written the same way, with a `comptime for` over the
fields:

```volt
use std::io;

namespace audit {
    trait fields {}
}

<T: audit::fields>
attach fn field_names(this: T&) -> std::string {
    var out = std::string::from(@typeinfo(T).short_name);
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                std::fmt::write(&out, " {}", f.name);
            }
        },
        default => {},
    }
    return out;
}

@attributes([@derive(audit::fields)])
struct account {
    id: u32;
    owner: str;
}

fn main() -> void {
    val a: account = { id: 7, owner: "ada" };
    std::println("{}", a.field_names());
}
// expect: account id owner
```

The methods apply to the types that attach the trait and no others: between generic versions that
fit equally well, one whose type parameter has a trait bound is chosen over one taking any type.

## Reading files: @embed

`@embed("path")` is a file's bytes as a compile-time `str`, the path relative to the source file.
Runtime code gets it as a string constant:

```volt
use std::io;

// user.schema.json, beside this file: read while compiling
val schema: str = @embed("user.schema.json");

fn main() -> void {
    std::println("{} {}", schema.len, schema[0..1]);
}
// expect: 129 {
```

Comptime code can read it too, and so build types and functions from data: [a struct from a
schema file](/volt-bootstrap/guide/metaprogramming/#a-struct-from-a-schema-file) does it for this
file. A package's compile-time code is trusted like its `build.volt`: `@embed` reads any path it's
given.

## What comptime code became: @expand and voltc expand

`@expand(expr)` is `expr`, and notes at compile time what it became: a comptime value with its
type, or the generic instance a call runs.

```volt
use std::io;

<T: type>
fn twice(v: T) -> T {
    return v + v;
}

fn main() -> void {
    val n = @expand(@sizeof(i64) * 2);
    val t = @expand(twice(21));
    std::println("{} {}", n, t);
}
// expect: 16 42
```

```
warning: expands to 16 (usize)
   ┌─ main.volt:9:13
warning: expands to a call of twice<i32>(v: i32) -> i32
   ┌─ main.volt:10:13
```

For code you'd rather not touch, `voltc expand FILE` lists what all of a file's comptime code became,
by line: comptime values, which way each `comptime if` went, the arm each `comptime match` took, the
copies a `comptime for` made, the generic instance each call runs, each fn a comptime fn declared
and the `attach` a `@derive` made. `voltc expand FILE:LINE` lists one line's:

```
$ voltc expand main.volt:10
main.volt:10:13: calls twice<i32>(v: i32) -> i32
```

In an editor, hover shows the same under **expands to**, and VS Code's **Volt: Expand Comptime**
opens the cursor's line's (or the file's) in a document beside it.

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

`@attributes([...])` before a declaration attaches compile-time attributes: the builtins below
(only known ones are accepted, so a typo is an error), and a library's own (see
[Your own attributes](#your-own-attributes)).

| Attribute | Meaning |
| --- | --- |
| `@inline`, `@noinline` | inlining hints |
| `@unchecked` | no bounds checks in this function's body (closures in it keep theirs): for a hot loop whose indexes are known to be in range |
| `@invalidates` | a method that may move or free its receiver's storage (`push`, `clear`...): a view into the receiver used after it warns ([safety](/volt-bootstrap/guide/safety/#what-the-compiler-warns-about)) |
| `@opt(n)` | optimization level for this function (0 to 3) |
| `@section(".name")` | put the function in a section |
| `@align(n)` | alignment |
| `@deprecated("use x")` | warn where it's used |
| `@intrinsic("name")` | a compiler builtin or runtime function (for std-like libraries) |
| `@owns("field")` | this struct owns what the field points at, like `box` |
| `@export_text("method")` | an export fn returning this struct hands other languages its text, as `method()` gives it (std's `string` has it) |
| `@instance(T, ...)` | on a generic export fn: export this instance, a type per generic parameter (`sum_i32` for `sum<i32>`; [bindings](/volt-bootstrap/interop/other-languages/#they-call-volt)) |
| `@thread_local` | a global `var` each thread has its own copy of, starting from its initial value |
| `@cfg("key")`, `@cfg("key", "value")` | the declaration is only in builds where this `@cfg` holds; on a namespace, everything in it |
| `@optional` | on a trait fn: attach blocks may leave it out (`@has_method` says which did) |
| `@closed` | on a trait: its attach blocks hold its fns and nothing else, with its parameter types |
| `@derive(a, b)` | on a struct or enum: attach each named trait (`std::derive`'s when not in scope); see [Derive](#derive) |
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

### Your own attributes

A library's attributes are plain structs. In `@attributes([...])`, a struct's name called like a
function is that struct, its fields filled in order (the rest take their defaults); a comptime
function's call, or a comptime value's name, works too. They go on declarations and on struct fields, and `@typeinfo` gives them
as a tuple: `@typeinfo(T).attributes`, and each field's `attributes`. A serializer looks through
them with `comptime for` and `@typeof`:

```volt
use std::io;

namespace ser {
    struct rename {
        to: str;
    }

    struct skip {}
}

struct user {
    @attributes([ser::rename("user_id")])
    id: u32;
    name: str;
    @attributes([ser::skip()])
    password: str;
}

<T: type>
fn keys(v: T&) -> std::string {
    var out: std::string = {};
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                comptime var key = f.name;
                comptime var skipped = false;
                comptime for (a) in f.attributes {
                    comptime if (@typeof(a) == ser::rename) {
                        key = a.to;
                    } else comptime if (@typeof(a) == ser::skip) {
                        skipped = true;
                    }
                }
                comptime if (!skipped) {
                    std::fmt::write(&out, "{}={} ", key, @field(v, f.name));
                }
            }
        },
        default => {},
    }
    return out;
}

fn main() -> void {
    val u: user = { id: 7, name: "ada", password: "-" };
    std::println("{}", keys(&u));
}
// expect: user_id=7 name=ada
```

An attribute is evaluated when `@typeinfo` reads it, so one naming nothing is an error then. A field
takes only a library's attributes; the builtins are about declarations.
