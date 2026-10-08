---
title: Lua
description: Embedding Lua in Volt with the interop/lua package, and calling Volt from Lua through generated bindings.
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

## Lua calls Volt

A Volt library that lists `lua` among its bindings gets the C source of a Lua module, which
`bolt build` compiles to `target/debug/bindings/lua/NAME.so` when Lua's headers are installed
(Lua 5.4 or later).

The examples here use `greet`, the library every client in
[examples/interop/calls-volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt)
calls: `export fn add(a: i64, b: i64) -> i64`, `export fn hello(name: str) -> std::string`, and an
`export struct tally` with `tally_new`, `tally_add` and `tally_name`. What `export` means, and what
crosses as what, is in [They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt).

```toml
# bolt.toml of the Volt library
[lib]
kind = ["shared"]
bindings = ["lua"]
```

```sh
bolt build
LUA_CPATH="target/debug/bindings/lua/?.so" lua main.lua
```

```lua
local greet = require("greet")

print("add", greet.add(2, 3))       -- add 5
print(greet.hello("volt"))          -- hello, volt
do
    local c <close> = greet.tally.new("clicks")   -- closed at the end of the block
    c:add(1)
    print(c:name(), c:add(2))       -- clicks 3
end
```

Structs are tables with their fields; what Volt changes in one passed by reference comes back
into the table, and so do the elements of a slice (a sequence). An enum is a table of its values,
an error set a table of its names, and an error is raised as a table with its `name` and `code`.
Integers that don't fit the parameter's type raise an error, as do wrong types. A callback is any
function (or anything with `__call`, such as a closure Volt gave back). An export struct is a
userdata with `close()`, `<close>` and `__gc`.

### Every shape

Lua takes [every shape](/volt-bootstrap/interop/other-languages/#every-shape):
- **Owned values as parameters.** A `std::string` parameter takes a string (Volt copies it); an
  export struct by value takes its userdata, which is closed once Volt has it. A call can't give
  one handle twice (or lend and give it), nor give one Volt only lent to Lua.
- **Traits.** Any table or userdata with the trait's methods can be lent (`s: shape&`) or given
  (`s: shape`: Volt calls its `close` method, when it has one, once it's done with it). A Volt
  value of the trait is a userdata with the methods, `close()`, `<close>` and `__gc`.
- **Callbacks taking and giving text and handles.** A callback gets strings and userdata (one Volt
  lends is closed when the callback returns) and gives them back; for an `E!T` callback it gives
  the value, or `nil, err` for an error, `err` being one of the error set's names (or an error
  raised from Volt).
- **Closures given back** are userdata called like functions, with `close()`, `<close>` and
  `__gc`.
- **Lists and sequences of text and handles.** A `std::vec<T>` comes back as a sequence (strings,
  or userdata the caller owns); a sequence goes in for `std::string[..]`, a slice of an export
  struct and a `std::vec<T>` (giving its handles). An optional text or handle is the value or
  `nil`; for nil elements, a sequence's `n` field (as `table.pack` gives) is its length.

An error a callback or a method raises comes out of the Volt call: meanwhile Volt gets a stand-in
(zeros, empty text, the error set's first error), and the calls into Lua after it are skipped. A
callback that has to give a handle has nothing to stand in, so its error ends the program, as a
Volt panic does.

For a library `shapes` with a trait `shape` (`area`, `name`, `grow`), `describe(s: shape&) ->
std::string`, `make_square(side: f64) -> shape`, `owners(xs: account&[..]) ->
std::vec<std::string>` and `try_twice(f: fn(i32) -> bank_error!i32, x: i32) -> bank_error!i32`:

```lua
local Circle = {}
Circle.__index = Circle
function Circle:area() return 3 * self.r * self.r end
function Circle:name() return "circle" end
function Circle:grow(by) self.r = self.r + by end

print(shapes.describe(setmetatable({ r = 1 }, Circle)))   -- circle of area 3
do
    local sq <close> = shapes.make_square(2)              -- Volt's own shape
    print(sq:name(), sq:area())                            -- square  4.0
end
local names = shapes.owners({ a, b })                      -- { "ann", "bobby" }
local ok, err = pcall(shapes.try_twice, function(x)
    if x > 5 then
        return nil, shapes.bank_error.OVERDRAWN
    end
    return x * 2
end, 4)
print(err.name)                                            -- OVERDRAWN
```
