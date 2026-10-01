---
title: Node.js addons
description: Writing Node.js addons in Volt with the interop/node package.
sidebar:
  order: 5
---

The `interop/node` package (in the repository) writes Node.js addons in Volt over Node-API: Volt
functions that JavaScript calls with any values, and that call JavaScript back. (To expose an
existing Volt library to JavaScript without writing addon code, use
[`bindings = ["node", "js", "ts"]`](/volt-bootstrap/interop/other-languages/#javascript-and-typescript).)

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
