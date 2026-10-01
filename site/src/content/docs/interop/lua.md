---
title: Lua
description: Embedding Lua in Volt with the interop/lua package.
sidebar:
  order: 8
---

The `interop/lua` package (in the repository) embeds Lua 5.4 or later. Depend on it to run
scripts, call Lua functions with Volt values and give Lua Volt functions. Its build file asks
`pkg-config` for Lua's flags (`lua`, then `lua5.5`, `lua5.4` and other names distributions use;
`$LUA_PC` picks one).

```toml
# bolt.toml
[dependencies]
lua = { path = "../volt/interop/lua" }
```

```volt ignore
use std::io;

// hypot(a, b) for Lua
extern "C" fn hypot(L: void*) -> i32 {
    var a = lua::args_of(L);
    val x = a.number(1) ?? 0.0;
    val y = a.number(2) ?? 0.0;
    a.ret(std::math::sqrt(x * x + y * y));
    return 1;                                   // one result
}

fn run(l: lua::state&) -> lua::lua_error!void {
    try l.run("function greet(who) return 'hi ' .. who end\nscores = { 3, 9, 4 }");
    val greet = l.global("greet");
    std::println("{}", (try greet.call("volt")).to_string());          // hi volt
    std::println("{}", try (try l.global("scores").at(2)).to_i64());   // 9

    l.set_global("limit", 40);
    std::println("{}", try (try l.eval("limit + 2")).to_i64());        // 42

    l.register("hypot", hypot);
    std::println("{}", (try l.eval("hypot(3, 4)")).to_string());       // 5.0

    val bad = l.run("error('boom')");
    if (bad.err) {
        std::println("{}", bad.err);                                    // ERROR(run:1: boom)
    }
}

fn main() -> !void {
    var l = lua::start();                       // Lua closes when l is deleted
    try run(&l);
}
```

| | |
| --- | --- |
| `lua::start()` | a Lua state with the standard libraries (a `state`: deleting it closes Lua) |
| `l.run(code)` | runs a chunk |
| `l.eval(expr)`, `l.global(name)` | an expression's value; a global (nil when there's none) |
| `l.set_global(name, x)` | sets a global to a Volt value |
| `l.register(name, f)` | gives Lua a Volt function (see below) |
| `v.call(args...)` | calls a function, each argument converted; its first result |
| `v.get(key)`, `v.at(i)`, `v.len()` | `v[key]`, `v[i]` (1 is the first), `#v` |
| `v.to_i64()`, `to_f64()`, `to_bool()`, `to_string()` | back to Volt; `to_string` is Lua's `tostring` |
| `v.type_name()`, `v.is_nil()` | `type(v)`; whether it's nil |
| `lua::nil()` | nil, to pass or return |

Volt values going to Lua are integers, `f64`, `f32`, `bool`, `str`, `std::string` and
`lua::value`. A `lua::value` holds a reference in Lua's registry: copying it adds one and deleting
it drops it. Every call that can fail returns `lua_error!T`, and a Lua error becomes
`lua_error::ERROR` with its message.

## Volt functions in Lua

A registered function is `extern "C" fn(L: void*) -> i32`. `lua::args_of(L)` reads its arguments
(`len()`, `integer(i)`, `number(i)` and `text(i)`, null when the argument isn't one; `get(i)` as a
value) and `ret(x)` pushes a result; the function returns how many it pushed. Raising a Lua error
from Volt would skip Volt's deletes, so return nil and a message instead, as Lua's own functions
do:

```volt ignore
a.ret(lua::nil());
a.ret("hypot wants two numbers");
return 2;
```
