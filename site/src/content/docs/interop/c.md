---
title: C
description: Importing C headers, declaring and exporting C functions, and C layouts.
sidebar:
  order: 1
---

Volt speaks C's ABI in both directions, and reads real C headers. Runnable examples:
[Volt calls C](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/c) and [C calls Volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt/c).

## Importing headers

`use { "header.h", ... } as ns;` runs the C preprocessor over the headers and imports what they
declare into namespace `ns`: functions, structs and unions, enums and their constants, `typedef`s,
numeric and string `#define`s (a string one is a `str`: adjacent literals joined, escapes decoded),
and global variables. A header is looked for next to the importing file first,
then where `#include <...>` looks (the system's directories and `-I`'s).

```c
/* vec2.h */
#define VEC2_VERSION 3
typedef struct { double x, y; } vec2;
enum axis { AXIS_X, AXIS_Y };
static inline vec2 vec2_add(vec2 a, vec2 b) { vec2 r = {a.x + b.x, a.y + b.y}; return r; }
static inline double vec2_dot(const vec2 *a, const vec2 *b) { return a->x * b->x + a->y * b->y; }
static inline void vec2_each(vec2 v, void (*f)(double)) { f(v.x); f(v.y); }
```

```volt
use std::io;
use { "vec2.h" } as v;
use { "stdlib.h", "string.h" } as c;

fn main() -> void {
    val a: v::vec2 = { x: 1.0, y: 2.0 };
    val b: v::vec2 = { x: 3.0, y: 4.0 };
    val sum = v::vec2_add(a, b);
    std::println("{} {} {}", sum.x, v::vec2_dot(&a, &b), v::VEC2_VERSION);
    std::println("{} {} {}", v::AXIS_Y, c::strlen("volt"), c::abs(-9));
}
// expect: 4 11 3
// expect: 1 4 9
```

How C's types come in:

| C | Volt |
| --- | --- |
| `int`, `long`, `size_t`, `uint8_t`... | the integer type of the same size and sign (`char` is `i8`) |
| `double`, `float` | `f64`, `f32` |
| `long double` | `f64`, through a C wrapper (below) |
| `float _Complex`, `double _Complex` | the struct `ns::cf32` or `ns::cf64`, `{ re, im }`: by value through a C wrapper, as a struct member or pointee directly (the same layout) |
| `T *` | `T*`, which may be null |
| `char *`, `const char *` | `cstr?` (string literals convert to `cstr`) |
| `void *` | `void*` |
| a function pointer | `extern "C" fn(...) -> R`, optional (it may be null) |
| `T[N]` | `T[N]` (a parameter's is a `T*`, as in C) |
| `T __attribute__((vector_size(N)))` (a member or a typedef) | `@vector(T, N / sizeof T)`, with C's layout |
| `struct`, `union` | the same, with C's layout |
| a named `enum` | a Volt enum of the same values and integer type, which converts to and from integers |
| an anonymous `enum` | a constant per enumerator, of its integer type |
| `static inline` functions | callable: voltc compiles a small C unit that exports them |

Flags for the preprocessor (`-I`, `-D`, `-U`, `-isystem`, `-iquote`, `-idirafter`, `-include`)
come from `--cc`: `voltc run app.volt --cc -Iinclude --cc -DDEBUG`. A struct Volt can only partly
read (a type it can't parse) still works: voltc asks libclang for its size, alignment and field
offsets, and skips what it can't name.

### Unions, bitfields and anonymous members

A union is a struct whose fields share their memory: `u.word = 1` writes it, `u.bytes[0]` reads it
back, and a literal sets one member. An anonymous struct or union member's fields are the outer
struct's, as in C, and an anonymous struct that types a named field is `OUTER_FIELD`. A bitfield
has no address, so C reads and writes it: each one gets `STRUCT_get_FIELD(&s)` and
`STRUCT_set_FIELD(&s, v)`, unless the header declares that name itself: then the name is the
header's.

```c
/* packet.h */
typedef union { unsigned int word; unsigned char bytes[4]; } raw32;
struct header {
    unsigned int version : 4;
    unsigned int urgent : 1;
    struct { unsigned short port; unsigned short length; };
    raw32 checksum;
};
```

```volt
use std::io;
use { "packet.h" } as p;

fn main() -> void {
    var h: p::header = { port: 8080, checksum: { word: 0x01020304 } };
    p::header_set_version(&h, 3);
    p::header_set_urgent(&h, 1);
    h.length = 512;
    std::println("{} {}", p::header_get_version(&h), p::header_get_urgent(&h));
    std::println("{} {} {}", h.port, h.length, h.checksum.bytes[0]);
}
// expect: 3 1
// expect: 8080 512 4
```

Both backends build all of these: the LLVM backend lays out unions, bitfields' neighbours,
anonymous members and structs whose layout an attribute changes (`packed`, `aligned(N)` on the
struct, a member or a member's typedef, `#pragma pack`) where libclang says C puts them, and passes a struct C classifies by members
Volt can't see (a `_Complex`, a bitfield beside a `float`) by value through a small C shim (see
[backends](/volt-bootstrap/voltc/backends/)).

### Enums, long double and complex numbers

A named enum (by its tag, or the `typedef` that names it) is a Volt enum with C's values and
integer type, so `match` takes its variants, and each enumerator is a constant of it. C passes any
integer where one goes, so it stands for its integer type too: it passes for that type or a wider
one, an integer that widens to that type passes for it (an integer's address for a pointer to one),
and operators, indexes, ranges, array lengths, `@cast` and `{}` see its number. An anonymous enum's
enumerators are integer constants. In a function pointer's type an enum is its integer, so a Volt
function written against the numbers passes as a callback.

`long double` and `_Complex` have no Volt type. A function taking or giving one by value is called
through a small C wrapper that converts it: a `long double` is an `f64` (what it holds past an
`f64`'s precision is lost), and a complex is the struct `cf32` (for `float _Complex`) or `cf64`
`{ re, im }` of the import's namespace (`cf64_` when the header has a type named `cf64`, and so on
for `cf32`). A struct member or pointee of a `float` or `double` complex is that struct too, which
C11 lays out as the complex (`s.z.re = 1.0`; a `double _Complex*` parameter is a `cf64*`); a
`long double` one, and a struct member that is a `long double`, are C's to read and write, as a
member Volt can't read is, and a pointer to one is a `void*`.

```c
/* levels.h */
enum level { LEVEL_LOW, LEVEL_HIGH = 10 };
static inline enum level level_up(enum level l) { return l == LEVEL_LOW ? LEVEL_HIGH : l; }
static inline long double gain(long double x) { return x * 1.5L; }
static inline double _Complex turn(double _Complex z) { return z * __builtin_complex(0.0, 1.0); }
```

```volt
use std::io;
use { "levels.h" } as lv;

fn main() -> void {
    val l: lv::level = lv::level_up(lv::LEVEL_LOW);
    match (l) {
        .LEVEL_HIGH => { std::println("high: {} {}", l, l as i32 + 1); },
        default => { std::println("low"); },
    }
    val n: i32 = lv::LEVEL_HIGH;
    std::println("{} {}", n, lv::level_up(0) == lv::LEVEL_HIGH);
    val z = lv::turn({ re: 1.0, im: 2.0 });
    std::println("{} {} {}", lv::gain(2.0), z.re, z.im);
}
// expect: high: 10 11
// expect: 10 true
// expect: 3 -2 1
```

### Macros and varargs

A function-like macro (`#define CLAMP(x, lo, hi) ...`) has no types until it's used, so each call
is worked out from its arguments' types: clang reads the call in C with the import's headers, its
result is the expansion's type, and a small C function made for those argument types makes the
call (one per distinct list of types, made once). So is a varargs function that takes or gives a
`long double` or a `_Complex`. A function whose last parameter is a `va_list` (`vsnprintf`) takes
varargs in its place: a C wrapper makes the `va_list` from them.

```c
/* shapes.h */
struct box { int w, h; };
#define AREA(b) ((b)->w * (b)->h)
#define CLAMP(x, lo, hi) ((x) < (lo) ? (lo) : (x) > (hi) ? (hi) : (x))
static inline int vtotal(int n, va_list ap) { ... }   /* the sum of n ints */
```

```volt
use std::io;
use { "shapes.h" } as sh;

fn main() -> void {
    var b: sh::box = { w: 3, h: 4 };
    val big: f64 = 7.5;
    std::println("{} {} {}", sh::AREA(&b), sh::CLAMP(big, 0.0, 5.0), sh::vtotal(3, 1, 2, 3));
}
// expect: 12 5 6
```

A macro sees its arguments as C would: a variable or field (any place) is the place itself, so
`INC(n)` for `#define INC(x) (++(x))` changes `n` (a `val` is `const` to C: changing one is C's
error), and a string or integer literal is written into the call as it is (`sizeof` of `"abc"` is
4, `#x` of `5` is `"5"`). Any other argument is its value. An argument needs a type of its own
(`null` or `{...}` alone doesn't have one: give it one with a typed `val`), and one C has: a number,
`bool`, a pointer or reference (C's pointer), a C string (`cstr`), or a struct or enum of a C
import. A call C rejects is a compile error with C's message, as is a result Volt has no type for
(an anonymous struct by value); a string result (`#x`) is a `cstr`. A `va_list` function needs a
parameter before the `va_list` (C's `va_start` does, before C23).

Every `typedef` is a type name you can write: `c::size_t`, `c::pthread_t`, a pointer typedef like
Node-API's `napi_env`, a function-pointer typedef (a callback type), or a struct's second name. A
function-pointer typedef is an optional function, as C's can be null. A struct with a `typedef` is
named by its first one, not by its tag: after `typedef struct counter tally;` it is `c::tally`. A
struct and a function of one name (`struct stat` and `stat()`) both come in: `c::stat` is the type
where a type goes and the function where a call does.

Importing the same header in two places gives the same types: a `FILE*` from one import is the
same type as from another.

### C versions

Headers are read and compiled under a C standard: the newest both libclang and `$CC` take, in GNU's
form (`gnu23` with a current compiler), unless `--cc -std=c11` sets one for the whole program or
`@standard` one for the import:

```volt ignore
@attributes([@standard("c89")])
use { "legacy.h" } as old;   // typedef int bool; K&R definitions
use { "modern.h" } as c;     // constexpr, nullptr, [[attributes]]: C23
```

Volt's own C (the C backend's output, the LLVM backend's runtime) is compiled under the GNU form of
the program's standard (`gnu99` at the least), and includes the headers imported under it (or its
GNU or ISO twin: `c11` and `gnu11` share it). A header imported under another one is compiled in a unit of its own
standard instead, and Volt calls its functions through pointers that unit defines (on ELF systems,
Linux and the BSDs, calling one the header declares and nothing defines panics, naming it, one
called through a wrapper, a `long double`'s or a `va_list`'s, too, but not a variadic one or a
macro worked out per use; and as the reference is weak, a static library's member that only such a
function needs isn't linked: link it whole, or under the program's standard. On Windows one called
directly panics the same way, but a header declaring one called through a wrapper doesn't link; on
macOS a header declaring any function nothing defines doesn't link); its structs are laid out by Volt (with
padding where a bitfield sits), so a union, or a struct with a union member, has to come in under
the program's standard. A K&R definition's parameters take the types a caller without a prototype passes (`char`
and `short` as `int`, `float` as `double`).

## Declaring C functions

`extern "C" fn` declares any function with a C ABI, from a C library, or a Rust `extern "C"`, Zig
`export`, or anything else linked in with `--cc`. C varargs (`...`) are for these declarations and
for `extern "C" fn` types, after at least one fixed parameter (C before C23 has no `int f(...)`, so
`extern "C" fn(...) -> i32` is an error). A declaration of your own may see a function another way than a header
or std does (`void*` where the header says `const void*`): the two never meet. Declaring one
function twice yourself, with two signatures, is an error.

```volt
use std::io;

extern "C" fn snprintf(buf: u8*, n: usize, fmt: cstr, ...) -> i32;

fn main() -> void {
    var buf: u8[32];
    val n = snprintf(&buf[0], 32, "%d-%s", 7, "x");
    std::println("{}", n);
}
// expect: 3
```

## Callbacks and exports

A Volt function passes as a C function pointer where one is expected (for a `void*` callback,
`@cast<void*>(f)` is its address; see [C function pointers](/volt-bootstrap/guide/closures/#c-function-pointers)),
and `extern "C" fn` with a body defines a function with the C calling convention. `export fn` also
gives it an unmangled symbol name, so C code linked with the program (or a library) can call it. A library C programs call gets its header
from `voltc bindings NAME --lang c`, which takes every shape: generics' instances, structs held by
handles with their methods, owned values, traits and closures both ways
([They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt)).

```volt
use std::io;
use { "vec2.h" } as v;

fn show(x: f64) -> void {
    std::print("[{}]", x);
}

export fn volt_scale(k: i32, x: i32) -> i32 {
    return k * x;
}

fn main() -> void {
    val p: v::vec2 = { x: 1.5, y: 2.5 };
    v::vec2_each(p, show);
    std::println(" {}", volt_scale(3, 4));
}
// expect: [1.5][2.5] 12
```

## Layout

Structs imported from C have C's layout, and `@sizeof` and `@alignof` of one are compile-time values
(an array's length, comptime code): C's own numbers, which libclang gives where an attribute, a
bitfield or an anonymous union places the fields. A union's (and those of a struct with a member
Volt can't read that libclang can't place either) are known at run time only, and in a global's
initializer.
Otherwise an imported struct is a type like any other: fns and traits attach to it
([Attaching to any type](/volt-bootstrap/guide/structs/#attaching-to-any-type)), and `@typeinfo`
reads its fields.

Every Volt struct is laid out as C lays out the same struct (fields in declaration order, C's
padding), so one can cross into C as it is; `extern struct` marks one that's meant to:

```volt
extern struct packet {
    kind: u8;
    length: u32;
    payload: u8[64];
}
```

## Linking C code

`--cc file.c` compiles a C file into the program, and `--cc -lNAME` links a library. In bolt, a
build file's `bolt::c_source(path)` and `bolt::link_c(name)` do the same.
