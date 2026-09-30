---
title: C++
description: Importing C++ headers with use cpp, what maps to what, and the limits.
sidebar:
  order: 2
---

`use cpp { "header.hpp" } as ns;` reads C++ headers with libclang and makes their declarations
Volt declarations. (This is the self-hosted voltc: the bootstrap compiler reads only C headers.)

```cpp
// geometry.hpp
namespace geo {
struct Vec2 {
    double x, y;
    double length() const { return std::sqrt(x * x + y * y); }
};

class Path {
public:
    Path() : count(0) {}
    void add(Vec2 p) { points[count++] = p; }
    double length() const;
private:
    Vec2 points[16];
    int count;
};

template <typename T>
T clamp(T v, T lo, T hi) { return v < lo ? lo : v > hi ? hi : v; }
}
```

```volt
use std::io;
use cpp { "geometry.hpp" } as cpp;

fn main() -> void {
    var path = cpp::geo::Path::new();
    path.add({ x: 0.0, y: 0.0 });
    path.add({ x: 6.0, y: 8.0 });
    path.add({ x: 6.0, y: 8.5 });
    val v: cpp::geo::Vec2 = { x: 3.0, y: 4.0 };
    std::println("{} {} {}", path.length(), v.length(), cpp::geo::clamp<f64>(1.5, 0.0, 1.0));
}
// expect: 10.5 5 1
```

## What maps to what

| C++ | Volt |
| --- | --- |
| namespace | namespace |
| class, struct | a struct with C++'s size and layout: public fields by name, the rest as padding |
| constructors | `T::new(...)`, one per overload (a default argument adds an overload without it) |
| destructor | a `delete` hook (only when the class needs one) |
| copy constructor | a `copy` hook |
| methods, static methods | attached functions, overloads kept |
| functions, function templates | functions, generic functions: `ns::biggest<i32>(a, b)` |
| class templates | generic structs: `ns::Box<f64>` |
| enum, enum class | enums with the same values and tag type |

## How it works

Every imported function becomes a Volt function whose body is one `@cpp<R>("C++ expression",
args)`: `{0}`, `{1}`... are the arguments. voltc writes an `extern "C"` wrapper for each call into a
C++ file, compiles it with `$CXX` (`c++` by default) and links it with `-lstdc++`. You can write
`@cpp` calls yourself for anything the importer leaves out:

```volt
use std::io;
use cpp { "geometry.hpp" } as cpp;

fn scaled_length(v: cpp::geo::Vec2&, k: f64) -> f64 {
    return @cpp<f64>("{0}.length() * {1}", v, k);
}

fn main() -> void {
    val v: cpp::geo::Vec2 = { x: 3.0, y: 4.0 };
    std::println("{}", scaled_length(&v, 1.5));
}
// expect: 7.5
```

`VOLT_SHOW_CPP=1` prints the Volt declarations voltc generated from the headers.

## Limits

- What doesn't map is left out, with a comment in the generated source: rvalue references,
  operators, and types from the C++ standard library in signatures.
- A C++ exception that reaches Volt stops the program, like a panic.
- Volt moves values by copying their bytes. A C++ object that points into itself (like libstdc++'s
  `std::string`) should stay behind a pointer.
