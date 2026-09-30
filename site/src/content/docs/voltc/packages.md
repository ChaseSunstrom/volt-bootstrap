---
title: Packages and std
description: Packages as namespaces, prebuilt libraries, guard symbols, and choosing a std.
sidebar:
  order: 4
---

## Packages

A package is a directory of `.volt` files. Every file in it is wrapped in `namespace NAME`, so a
package's names are reached as `NAME::...`. voltc takes packages with `--pkg`:

```sh
voltc run main.volt --pkg geo=../geo --pkg json=../json
```

bolt does this for a package's dependencies. The name has to be a valid Volt name (letters,
digits, `_`), and each package is given once.

## std

std is a package too, given as `--std DIR` (or found through `$VOLT_STD`, or as a `std/` next to
voltc). Nothing in the compiler knows its names; a different std only has to provide what the
programs using it call. `--no-std` builds without one.

Two attributes connect a library to the compiler, and any package can use them:

- `@attributes([@intrinsic("println")])` on a function without a body binds it to a compiler
  builtin (the print functions) or, for names starting with `volt_`, a function of the C runtime.
- `@attributes([@owns("field")])` makes a struct an owning pointer (like `std::mem::box`): used like
  a `T&`, deleting what it points at when it goes out of scope.

`tests/std_alt` in the repository is a minimal std written from scratch.

## Prebuilt libraries

Compiling a package once and reusing it saves time:

```sh
voltc lib geo --pkg geo=../geo -o libgeo.a          # the package's non-generic code
voltc run main.volt --pkg geo=../geo --link geo=libgeo.a
```

The program still reads the package's sources, since templates are instantiated per program, but
takes its non-generic functions from the library. bolt builds every dependency this way, once per
profile.

Symbol names and error codes are stable across builds, and the runtime lives in the program, not in
libraries. Each library carries a **guard symbol** made from a hash of its exact sources, its
`--cfg` settings and its mode (debug or release): a program checked against different sources, or
built in the other mode, fails to link instead of misbehaving.

## Libraries for other languages

`voltc lib NAME --shared` builds a self-contained shared library (the package, what it uses from
std, and the runtime), and `--static` the same as a `.a`. `voltc bindings NAME --lang L` writes the
declarations another language needs. See [Other languages](/volt-bootstrap/interop/other-languages/).

## Per-package configuration

`--cfg KEY=VALUE` sets a key for the program's own files; `--cfg PKG:KEY=VALUE` for package PKG's.
`@cfg` in a file reads the settings for that file's package, which is how bolt gives each package
its own features.
