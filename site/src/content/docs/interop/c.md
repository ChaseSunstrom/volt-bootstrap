---
title: C
description: Importing C headers, declaring and exporting C functions, and C layouts.
sidebar:
  order: 1
---

Volt speaks C's ABI in both directions, and reads real C headers.

## Importing headers

`use { "header.h", ... } as ns;` runs the C preprocessor over the headers and imports what they
declare into namespace `ns`: functions, structs and unions, enums and their constants, `typedef`s,
numeric `#define`s, and global variables.

```c
/* vec2.h */
#define VEC2_VERSION 3
typedef struct { double x, y; } vec2;
enum axis { AXIS_X, AXIS_Y };
static inline vec2 vec2_add(vec2 a, vec2 b) { vec2 r = {a.x + b.x, a.y + b.y}; return r; }
static inline double vec2_dot(const vec2 *a, const vec2 *b) { return a->x * b->x + a->y * b->y; }
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
| `int`, `long`, `size_t`, `uint8_t`... | the integer type of the same size and sign |
| `double`, `float` | `f64`, `f32` |
| `T *` | `T*`, which may be null |
| `char *`, `const char *` | `cstr?` (string literals convert to `cstr`) |
| `void *` | `void*` |
| a function pointer | `extern "C" fn(...) -> R` |
| `struct`, `union` | the same, with C's layout |
| `enum` | its integer type, and a constant per enumerator |
| `static inline` functions | callable: voltc compiles a small C unit that exports them |

Flags for the preprocessor (`-I`, `-D`, `-U`) come from `--cc`: `voltc run app.volt --cc -Iinclude
--cc -DDEBUG`. A struct Volt can only partly read (a type it can't parse) still works: voltc asks
libclang for its size, alignment and field offsets, and skips what it can't name.

### Unions, bitfields and anonymous members

A union is a struct whose fields share their memory: `u.word = 1` writes it, `u.bytes[0]` reads it
back, and a literal sets one member. An anonymous struct or union member's fields are the outer
struct's, as in C, and an anonymous struct that types a named field is `OUTER_FIELD`. A bitfield
has no address, so C reads and writes it: each one gets `STRUCT_get_FIELD(&s)` and
`STRUCT_set_FIELD(&s, v)`.

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

Both backends build all of these: the LLVM backend lays out unions, bitfields' neighbours and
anonymous members where libclang says C puts them.

### What doesn't come in

- Function-like macros (`#define MAX(a, b) ...`): they have no types until they're used. Wrap one
  in a `static inline` function in a header of your own and import that.
- A named C enum is its integer type (`i32`), with a constant per enumerator, not a Volt enum: C
  code passes any integer there.
- `long double`, `_Complex` and `va_list`: functions using them are left out.

Every `typedef` is a type name you can write: `c::size_t`, `c::pthread_t`, a pointer typedef like
Node-API's `napi_env`, a function-pointer typedef (a callback type), or a struct's second name. A
function-pointer typedef is an optional function, as C's can be null.

Importing the same header in two places gives the same types: a `FILE*` from one import is the
same type as from another.

## Declaring C functions

`extern "C" fn` declares any function with a C ABI, from a C library, or a Rust `extern "C"`, Zig
`export`, or anything else linked in with `--cc`. C varargs (`...`) are allowed only here.

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

A Volt function passes as a C function pointer where one is expected, and `extern "C" fn` with a
body defines a function with the C calling convention. `export fn` also gives it an unmangled
symbol name, so C code linked with the program (or a library) can call it.

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

Structs imported from C have C's layout. For your own structs that cross into C, use `extern
struct`: fields in declaration order with C's padding (a plain `struct`'s layout is the compiler's
choice).

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
