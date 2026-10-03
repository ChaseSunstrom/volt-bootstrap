---
title: Node.js
description: JavaScript and TypeScript calling Volt through generated bindings, and Node.js addons written in Volt with the interop/node package.
sidebar:
  order: 5
---

Volt meets JavaScript two ways: bindings that `bolt build` writes for a Volt library, which
JavaScript and TypeScript call like any module, and addons written in Volt with the `interop/node`
package, which take any JavaScript values and call JavaScript back. Both run in Node.js and in Bun.

## JavaScript calls Volt

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
