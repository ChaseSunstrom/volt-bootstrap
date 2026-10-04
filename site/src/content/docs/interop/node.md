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
| an exported constant of a number, `boolean` or string | a `val` |

A thrown exception stops the program with its text, as a Volt panic does. A function needs its
parameter types written, and its return type when it returns something. Generics, `async`
functions, callbacks, object types, imports between modules (bundle them into one file first) and
TypeScript that needs more than stripping (parameter properties, namespaces) are left out or
refused, and what's left out is listed in a comment of the generated declarations. bolt needs node
23.2 or later (`$NODE`) to strip TypeScript, and JavaScriptCore from WebKitGTK
(`javascriptcoregtk-4.1`, or `$JSC_PKG`): the program links it, nothing of Node.js.

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

Here is how values convert:
- Numbers and `bool` convert directly. A number that doesn't fit the parameter's type throws a
  `RangeError`, and a fraction, NaN or infinity given for an integer throws a `TypeError`.
  64-bit integers also take a `BigInt`. They come back as numbers, which are exact up to 2^53.
- A struct is a plain object. Passed as `T&`, what Volt changes in it comes back to the object.
- A slice is an array, and what Volt writes into its elements comes back too.
- An optional is the value or `null`.
- A callback is any function. It's called during the call it was passed to.
- `str` and owned text are strings.
- An error is thrown as an `Error` whose `code` is the error's name, and an error set is an object
  of its names (for `error math_error { NEGATIVE }`, `greet.math_error.NEGATIVE` is `"NEGATIVE"`).
- Each class checks that its methods get an instance of it.

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

`bolt build` makes `target/debug/libaddon.so`; Node loads an addon from a `.node` file, so copy it
to `addon.node` and `require("./addon.node")`. The package's build file finds Node's headers next to
the `node` on your `PATH` (or in `/usr/include/node`).

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
