---
title: JavaScript and Node.js
description: Calling TypeScript and JavaScript modules from Volt by importing them like a header, JavaScript calling Volt through generated bindings, and Node.js addons written in Volt.
sidebar:
  order: 5
---

## Volt calls JavaScript

A TypeScript module is imported like a header, and so is a JavaScript one with a `.d.ts` beside it
for its types. Nothing in it is written for Volt, and the Volt code has no engine or value handles:
bolt reads the module's TypeScript declarations, strips the types with node, and writes Volt that
runs the module in JavaScriptCore, embedded in the program. It starts the first time it's called.

```volt ignore
use std::io;
use { "geom.ts" } as geom;
use { "util.js" } as util;            // its types: util.d.ts

fn main() -> void {
    var p = geom::Point::new(3.0, 4.0);                  // new Point(3, 4)
    p.scale(2.0);
    p.set_y(1.5);                                         // a field: y() and set_y(v)
    std::println("{} {}", p.norm(), geom::upper("quiet"));  // 6.18465843842649 QUIET
    std::println("{}", geom::add(40.0));                  // a default: add(a, b = 2) is 42
    std::println("{}", util::greet("volt"));
}
```

| TypeScript | Volt |
| --- | --- |
| an exported function | `fn f(...)`; literal defaults stay defaults, `x?: T` is `x: T? = null` |
| an exported class | a handle: a reference to the object (a copy refers to the same one); `is_null()` for `null` |
| `new T(...)` | `T::new(...)` |
| methods, `static` methods | methods, and `T::f(...)`; a subclass has its base's too |
| a field, a `get`/`set` accessor | `x()` and, unless it's `readonly` (or has no setter), `set_x(v)`; `T::x()` for a static one |
| a base class `B` of the module | `as_B()`: the same object, as a `B` |
| a numeric `enum` | a Volt enum with the same values |
| `number`, `boolean` | `f64`, `bool` |
| `string` | `str` in, `std::string` out |
| `T[]` of those | `T[..]` in (what JavaScript changes in an array of numbers or booleans comes back), `std::vec<T>` out |
| `T \| null`, `T \| undefined` | `T?`; for a class, an empty handle is `null` |
| an `interface`, or a `type` of an object type | a struct, copied to and from a JavaScript object: `x?: T` is `x: T? = null` (absent on the way back is `null`), `extends` brings the base's fields; one with methods or an index signature is left out |
| `type X = T` | `T` |
| a generic function or class (`first<T>(xs: T[]): T`, `class Box<T>`) | a Volt generic (`geom::first<f64>(xs)`, `geom::Box<f64>::new(2.0)`): each value converted by its type, which must be a number, `bool`, `str` or `std::string`, or one of the module's classes, enums or object types |
| an array of classes, enums, object types or a type parameter | `T[..]` in, `std::vec<T>` out |
| a callback parameter, `(x: number) => number` | a Volt fn value, `fn(f64) -> f64`, that JavaScript calls, and may keep and call later (its parameters and result are one value each, not arrays) |
| an `async` function, or one giving a `Promise<T>` | `T`: the call gives what the promise settles to, and a rejection stops the program with its text |
| an exported constant of a number, `boolean` or string | a `val` |

```volt ignore
val b = geom::Box<f64>::new(2.0);
val n = geom::each(3.0, || (i: f64) -> void { std::print("[{}]", i); });    // [0][1][2]
val size: geom::Size = { w: 2.0, h: 3.0, tag: null };
std::println("{} {} {}", b.get(), geom::later(21.0), geom::area(size));        // 2 42 6
```

A thrown exception stops the program with its text, as a Volt panic does. A function needs its
parameter types written, and its return type when it returns something. There's no event loop:
an async function's promise must settle as the call returns (what it awaits already done, or a
promise of its own), and one still pending stops the program (`never settled`); an async call from
inside a callback JavaScript is running can't settle either. A struct passed in is moved like any
value (`copy s` keeps it). A callback is freed when JavaScript collects the function holding it, so
one it keeps until the program ends is never freed. Imports between modules (bundle them into one
file first) and TypeScript that needs more than stripping (parameter properties, namespaces) are
left out or refused, and what's left out is listed in a comment of the generated declarations
(`VOLT_SHOW_IMPORT=1 voltc check main.volt` prints them). bolt needs node 23.2 or later (`$NODE`)
to strip TypeScript, and JavaScriptCore from WebKitGTK (`javascriptcoregtk-4.1`, or `$JSC_PKG`):
the program links it, nothing of Node.js.

## JavaScript calls Volt

The other way round, Volt meets JavaScript two ways: bindings that `bolt build` writes for a Volt
library, which JavaScript and TypeScript call like any module, and addons written in Volt with the
`interop/node` package, which take any JavaScript values and call JavaScript back. Both run in
Node.js and in Bun.

A Volt library that lists `node` among its bindings gets the C source of a Node-API addon, which
`bolt build` compiles to `target/debug/bindings/NAME.node` when Node's headers are installed. `js`
adds its loader (`NAME.js`) and `ts` its TypeScript types (`NAME.d.ts`).

The examples here use `greet`, the library every client in
[examples/interop/calls-volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt)
calls: `export fn add(a: i64, b: i64) -> i64`, `export fn hello(name: str) -> std::string`, and an
`export struct tally` with `tally_new`, `tally_add` and `tally_name`. What `export` means, and what
crosses as what, is in [They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt).

```toml
# bolt.toml of the Volt library
[lib]
kind = ["shared"]
bindings = ["node", "js", "ts"]
```

```js
const greet = require("./target/debug/bindings/greet.js");   // loads greet.node next to it

console.log("add", greet.add(2, 3));    // add 5
console.log(greet.hello("volt"));       // hello, volt
const c = new greet.tally("clicks");    // an export struct is a class
c.add(1);
console.log(c.name(), c.add(2));        // clicks 3
c.close();                              // or `using c = ...`, or leave it to the garbage collector
```

`bolt build` writes the addon and its loader to `target/debug/bindings`. The loader finds the
addon in `$VOLT_NAME_NODE` (the package's name in capitals), else next to itself. TypeScript imports the same
loader, typed by `NAME.d.ts`:

```ts
import { createRequire } from "node:module";
import type * as Greet from "./target/debug/bindings/greet.js";

const greet: typeof Greet = createRequire(import.meta.url)("./target/debug/bindings/greet.js");
const c: Greet.tally = new greet.tally("clicks");
```

A Node project can also install a Volt library with `npm install`, which runs bolt: see
[pip install and npm install](/volt-bootstrap/interop/other-languages/#pip-install-and-npm-install).

Here is how values convert:
- Numbers and `bool` convert directly. A number that doesn't fit the parameter's type throws a
  `RangeError`, and a fraction, NaN or infinity given for an integer throws a `TypeError`.
  64-bit integers also take a `BigInt`. They come back as numbers, which are exact up to 2^53.
- A struct is a plain object. Passed as `T&` or `T*` (`null` for a null `T*`), what Volt changes
  in it comes back to the object. Its fields can be text (a string, kept until the call is back),
  arrays (an array of exactly their length), structs, and pointers (an External from another
  call, or `null`).
- A pointer a function returns is an External too, or `null`; TypeScript types both `unknown`.
- An enum is its number, and the module has an object of its values (for `enum color { RED,
  GREEN }`, `greet.color.GREEN` is `1`).
- An `E!T` parameter takes the value, or the `Error` `voltError(name)` makes for one of its errors.
- A slice is an array, and what Volt writes into its elements comes back too.
- An optional is the value or `null`.
- A callback is any function. It's called during the call it was passed to. A struct Volt lends
  it by pointer is an object (`null` for a null `T*`), and what the callback changes in it goes
  back to Volt.
- `str` and owned text are strings.
- An error is thrown as an `Error` whose `code` is the error's name (and `errno` its number), and
  an error set is an object of its names (for `error math_error { NEGATIVE }`,
  `greet.math_error.NEGATIVE` is `"NEGATIVE"`).
- Each class checks that its methods get an instance of it.

### Every shape

JavaScript takes [every shape](/volt-bootstrap/interop/other-languages/#every-shape):
- **Numbers by reference.** A `n: i32*` or `x: f64&` parameter takes an array of one, `[7]`, and
  what Volt writes comes back into it (`null` is a null `i32*`); TypeScript has it as `[number]`
  (`[number] | null | undefined` for a `T*`).
- **Owned values as parameters.** A `std::string` parameter takes a string (Volt copies it). An
  export struct by value takes its instance, which gives its handle up (closing it after does
  nothing). A call checks every instance it's given first (open, owned, each once), so one that
  throws gives nothing up. An instance lent to a call that hasn't returned yet (a callback can
  reach it) can't be closed or given away until it does.
- **Traits.** A Volt trait is any object with its methods, lent (`s: shape&`) or given (`s:
  shape`). When Volt is done with one it was given, it calls the object's `[Symbol.dispose]()` or
  `close()`, if it has one. A Volt value of the trait comes back as a `volt_shape`, with the
  methods, `close()` and `Symbol.dispose`.
- **Callbacks taking and giving text and handles.** A function gets strings and instances, and
  gives them back. An instance Volt lends is let go of when the callback returns. A callback for
  `E!T` throws `voltError(name)` to give Volt that error. Anything else it throws is thrown by the
  call once Volt is back, and Volt gets a stand-in meanwhile: the error set's first error, empty
  text, or zero. A callback that has to give a handle has no stand-in, so a throw there stops the
  program, as a Volt panic does. Callbacks run on the thread that made the call.
- **Closures given back** are functions with `close()` and `Symbol.dispose` (TypeScript's
  `VoltFunction<F>`). One that isn't closed is freed when it's collected.
- **Worker threads.** Each `worker_threads` Worker that loads the addon gets its own classes, so
  the main thread and the workers all make and take instances; an instance stays in the thread
  that made it.
- **Lists, and arrays of text and handles.** A `std::vec<T>` comes back as an array: strings, or
  instances the caller owns. Arrays go in for lists, for `std::string[..]` and for slices of
  handles. An optional text or handle is the value or `null`.

For a library `shapes` with a trait `shape` (`area`, `name`, `grow`), `describe(s: shape&) ->
std::string`, `make_square(side: f64) -> shape`, `doubler() -> fn(i32) -> i32` and `owners(xs:
account&[..]) -> std::vec<std::string>`:

```js
const circle = {
    r: 1,
    area() { return 3 * this.r * this.r; },
    name() { return "circle"; },
    grow(by) { this.r += by; },
};
console.log(shapes.describe(circle));      // circle of area 3
const sq = shapes.make_square(2);          // Volt's own shape
console.log(sq.name(), sq.area());         // square 4
sq.close();
const d = shapes.doubler();
console.log(d(21));                        // 42
d.close();
console.log(shapes.owners([a, b]));        // [ 'ann', 'bob' ]: a std::vec<std::string>
```

## Addons written in Volt

The `interop/node` package (in the repository) writes Node.js addons in Volt over Node-API: Volt
functions that JavaScript calls with any values, and that call JavaScript back.

```toml
# bolt.toml
[lib]
kind = ["shared"]

[dependencies]
node = { path = "../volt/interop/node" }
```

```volt ignore
// lib/addon.volt
fn add(c: node::call&) -> node::node_error!node::value {
    return c.number(try c.arg(0).to_f64() + try c.arg(1).to_f64());
}

// calls back into JavaScript: f(x, "from volt")
fn apply(c: node::call&) -> node::node_error!node::value {
    return c.arg(0).call(try c.arg(1).to_f64(), "from volt");
}

fn fails(c: node::call&) -> node::node_error!node::value {
    return node::node_error::THROWN(std::string::from("volt says no"));   // a JS Error
}

export fn napi_register_module_v1(env: void*, exports: void*) -> void* {
    var m = node::init(env, exports);
    m.function("add", add) catch |e| {};
    m.function("apply", apply) catch |e| {};
    m.function("fails", fails) catch |e| {};
    return m.exports();
}
```

`bolt build` makes `target/debug/libaddon.so` (`libaddon.dylib` on macOS, `addon.dll` on
Windows); Node loads an addon from a `.node` file, so copy it
to `addon.node` and `require("./addon.node")`. The package's build file finds Node's headers next to
the `node` on your `PATH` (or in `/usr/include/node` or `/usr/local/include/node`).

| | |
| --- | --- |
| `c.arg(i)`, `c.len()`, `c.this_arg()` | the call's arguments (`undefined` past the end) and `this` |
| `c.number(x)`, `c.string(s)`, `c.boolean(b)`, `c.object()`, `c.array()`, `c.null_value()`, `c.undefined()` | new values |
| `v.to_f64()`, `to_i64()`, `to_bool()`, `to_string()` | back to Volt (`to_string` is `String(v)` for non-strings) |
| `v.type_of()` | `"number"`, `"string"`, `"object"`, `"function"`... |
| `v.get(name)`, `v.set(name, x)` | properties |
| `v.length()`, `v.at(i)`, `v.put(i, x)` | array elements |
| `v.call(args...)` | calls a JavaScript function; arguments are converted (numbers, `bool`, `str`, `std::string`, values) |

A function returns `node_error!node::value`: an error is thrown in JavaScript as an `Error` with its
message. A JavaScript exception thrown by a function Volt calls comes back as
`node_error::THROWN(message)`, and `try` passes it on. Values are only good during the call that
made them.
