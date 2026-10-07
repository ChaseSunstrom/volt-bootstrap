---
title: Code that writes code
description: "Small comptime programs that build types and functions: a struct of arrays, an enum's name table, getters and an argument parser, a struct from a schema file, register blocks, a state machine, and code from the fns attached to any type."
sidebar:
  order: 12
---

A comptime function can build a type and declare the functions that go with it (see
[Types built at compile time](/volt-bootstrap/guide/comptime/#types-built-at-compile-time)). Each
section below shows code you'd otherwise write by hand, then a comptime function that writes it
for any type or list you give it. Every program here runs in the site's tests.

## A struct of arrays

A struct of arrays keeps each field in its own vector, so a loop over one field reads memory in
order. By hand, it's a second struct and a `push` that have to change whenever the first one does:

```volt ignore
struct particles {
    x: std::vec<f32> = {};
    y: std::vec<f32> = {};
    alive: std::vec<bool> = {};
}

attach fn push(this: particles&, p: particle) -> void {
    this.x.push(p.x);
    this.y.push(p.y);
    this.alive.push(p.alive);
}
```

`soa(T)` builds both from `T`'s fields:

```volt
use std::io;

struct particle {
    x: f32;
    y: f32;
    alive: bool;
}

comptime fn soa(T: type) -> type {
    val S = struct {
        comptime for (f) in @typeinfo(T).fields {
            f.name: std::vec<f.field_type> = {};
        }
    };
    attach fn push(this: S&, v: T) -> void {
        comptime for (f) in @typeinfo(T).fields {
            @field(this, f.name).push(@field(v, f.name));
        }
    }
    return S;
}

fn main() -> void {
    var ps: soa(particle) = {};
    ps.push({ x: 1.0, y: 2.0, alive: true });
    ps.push({ x: 3.0, y: 4.0, alive: false });
    var sum: f32 = 0.0;
    for (x) in ps.x.items() {
        sum += x;
    }
    std::println("{} {}", ps.y.len, sum);
}
// expect: 2 4
```

## An enum and its name table

An enum whose values are printed or read back needs a table of names next to it, and the two
drift apart:

```volt ignore
enum color { red, green, blue }

attach fn name(this: color) -> str {
    match (this) {
        .red => { return "red"; },
        .green => { return "green"; },
        .blue => { return "blue"; },
    }
}
```

From one list of names, `named_enum` builds the enum, `name()` and `parse()`:

```volt
use std::io;

comptime fn named_enum(names: str[]) -> type {
    val E = enum {
        comptime for (n) in names {
            (n),
        }
    };
    attach fn name(this: E) -> str {
        comptime for (v) in @typeinfo(E).variants {
            if (this == @field(E, v.name)) {
                return v.name;
            }
        }
        return "";
    }
    attach fn parse(static this: E, text: str) -> E? {
        comptime for (v) in @typeinfo(E).variants {
            if (text == v.name) {
                return @field(E, v.name);
            }
        }
        return null;
    }
    return E;
}

type color = named_enum({ "red", "green", "blue" });

fn main() -> void {
    val c = color::parse("blue") ?? color::red;
    std::println("{} {} {}", c.name(), color::green.name(), color::parse("pink") == null);
}
// expect: blue green true
```

## Getters and an argument parser

Getters, and a command line read into a struct, repeat each field's name and type once more for
every field:

```volt ignore
attach fn get_width(this: options&) -> i64 {
    return this.width;
}
// ...one per field

if (flag == "--width") {
    out.width = try value.parse_int();
} else if (flag == "--verbose") {
    out.verbose = try value.parse_bool();
} // ...one per field
```

`comptime f(args);` runs a comptime function for the functions it declares. These two write the
getters and a `from_args` for any struct, parsing each value by its field's type:

```volt
use std::io;
use std::text;

struct options {
    width: i64 = 80;
    height: i64 = 24;
    verbose: bool = false;
    title: str = "untitled";
}

// get_NAME() for each field, named after it
comptime fn getters(T: type) -> void {
    for (f) in @typeinfo(T).fields {
        attach fn ("get_" + f.name)(this: T&) -> f.field_type {
            return @field(this, f.name);
        }
    }
}

// --NAME VALUE for each field; a field not given keeps its default
comptime fn args_of(T: type) -> void {
    attach fn from_args(static this: T, args: str[..]) -> std::text::parse_error!T {
        var out: T = {};
        var i: usize = 0;
        while (i + 1 < args.len) {
            val (flag, value) = (args[i], args[i + 1]);
            comptime for (f) in @typeinfo(T).fields {
                if (flag.len > 2 && flag[2..flag.len] == f.name) {
                    comptime if (f.field_type == i64) {
                        @field(out, f.name) = try value.parse_int();
                    } else if (f.field_type == bool) {
                        @field(out, f.name) = try value.parse_bool();
                    } else {
                        @field(out, f.name) = value;
                    }
                }
            }
            i += 2;
        }
        return out;
    }
}

comptime getters(options);
comptime args_of(options);

fn main() -> void {
    val given: str[4] = { "--width", "120", "--verbose", "true" };
    val o = options::from_args(given[..]) catch |e| {
        std::println("bad arguments");
        return;
    };
    std::println("{} {} {} {}", o.get_width(), o.get_height(), o.get_verbose(), o.get_title());
}
// expect: 120 24 true untitled
```

## A struct from a schema file

A struct that mirrors a file another tool owns, such as a JSON schema, has to be edited each time
the file changes. `@embed` reads the file while compiling, so the struct can come from it. Here
it's `user.schema.json`, beside the program:

```json
{
  "properties": {
    "name": { "type": "string" },
    "age": { "type": "integer" },
    "admin": { "type": "boolean" }
  }
}
```

```volt
use std::io;

// "string" | "integer" | "number" | "boolean" → a Volt type
comptime fn json_type(t: str) -> type {
    if (t == "string") {
        return std::string;
    }
    if (t == "integer") {
        return i64;
    }
    if (t == "number") {
        return f64;
    }
    return bool;
}

// the k-th "..." in text (from 0), without its quotes; "" past the last
comptime fn nth_str(text: str, k: usize) -> str {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"') {
            var j = i + 1;
            while (text[j] != '"') {
                j += 1;
            }
            if (seen == k) {
                return text[i + 1..j];
            }
            seen += 1;
            i = j;
        }
        i += 1;
    }
    return "";
}

comptime fn count(json: str) -> usize {
    var n: usize = 0;
    while (nth_str(json, 1 + 3 * n) != "") {
        n += 1;
    }
    return n;
}

// after "properties", each property is three strings: its name, "type" and its type
comptime fn from_schema(json: str) -> type {
    return struct {
        comptime for (i) in 0..count(json) {
            (nth_str(json, 1 + 3 * i)): json_type(nth_str(json, 3 + 3 * i));
        }
    };
}

type user = from_schema(@embed("user.schema.json"));

fn main() -> void {
    val u: user = { name: std::string::from("ada"), age: 36, admin: true };
    std::println("{} {} {}", u.name.as_str(), u.age, u.admin);
}
// expect: ada 36 true
```

The scanner only reads this flat shape; it's ordinary comptime Volt, so a fuller one is more of the
same.

## Register blocks from a spec

A device's registers are words at fixed offsets from a base address. Each one wants a read and a
write that the compiler keeps exactly as written (`@volatile_read` and `@volatile_write`), and an
offset typed by hand is easy to get wrong:

```volt ignore
attach fn get_status(this: uart&) -> u32 {
    return @volatile_read(&this.words[1]);
}
attach fn set_control(this: uart&, v: u32) -> void {
    @volatile_write(&this.words[2], v);
}
// ...two per register
```

`registers` writes them from a list of names and byte offsets:

```volt
use std::io;

comptime fn registers(spec: (str, usize)[]) -> type {
    val R = struct {
        words: u32*;
    };
    for (r) in spec {
        attach fn ("get_" + r.0)(this: R&) -> u32 {
            return @volatile_read(&this.words[r.1 / 4]);
        }
        attach fn ("set_" + r.0)(this: R&, v: u32) -> void {
            @volatile_write(&this.words[r.1 / 4], v);
        }
    }
    return R;
}

type uart = registers({ ("data", 0), ("status", 4), ("control", 8) });

fn main() -> void {
    // on a board, the device's address: val u: uart = { words: @cast<u32*>(0x40001000) };
    var mem: u32[3] = { 0, 1, 0 };
    val u: uart = { words: &mem[0] };
    u.set_control(5);
    u.set_data(65);
    std::println("{} {} {}", u.get_status(), mem[2], u.get_data());
}
// expect: 1 5 65
```

## A state machine from a table

A state machine by hand is an enum and a `match` over every (state, event) pair, with the table
itself only in a comment:

```volt ignore
enum door { closed, open, locked }

attach fn next(this: door, event: str) -> door? {
    match (this) {
        .closed => {
            if (event == "open") { return door::open; }
            if (event == "lock") { return door::locked; }
        },
        // ...
    }
    return null;
}
```

`machine` takes the table and writes both:

```volt
use std::io;

// a state for each name, and next(event) from (from, event, to) moves
comptime fn machine(states: str[], moves: (str, str, str)[]) -> type {
    val S = enum {
        comptime for (s) in states {
            (s),
        }
    };
    attach fn next(this: S, event: str) -> S? {
        comptime for (m) in moves {
            if (this == @field(S, m.0) && event == m.1) {
                return @field(S, m.2);
            }
        }
        return null;
    }
    return S;
}

type door = machine({ "closed", "open", "locked" }, {
    ("closed", "open", "open"),
    ("open", "close", "closed"),
    ("closed", "lock", "locked"),
    ("locked", "unlock", "closed"),
});

fn main() -> void {
    var d = door::closed;
    val events: str[4] = { "lock", "open", "unlock", "open" };
    for (e) in events {
        val n = d.next(e);
        if (n) {
            d = n;
            std::print("{} ", e);
        } else {
            std::print("({} refused) ", e);
        }
    }
    std::println("{}", d == door::open);
}
// expect: lock (open refused) unlock open true
```

## Code from the fns attached to any type

A function can be attached to any type, not only one you declared: `i32`, `str`, std's types, a C
struct or a C++ class from an import. Comptime code reads a type's attached fns
(`@typeinfo(T).methods`) as it reads its fields, and calls one by a name it works out
(`@field(v, name)(...)`), so a layer over every type that has some kind of fn is one comptime
function. Zig generates code from a type's fields too, but it can't add a method to a type it
doesn't own; here `i32` gets one, and a command dispatcher comes from whatever `cmd_` fns a type
has:

```volt
use std::io;

attach fn kib(this: i32) -> i32 {
    return this * 1024;
}

struct lamp {
    on: bool;
    level: i32;
}

attach fn cmd_toggle(this: lamp&) -> void {
    this.on = !this.on;
}

attach fn cmd_brighter(this: lamp&) -> void {
    this.level += 10;
}

// run(cmd) calls T's cmd_ fn of that name; commands() lists them. Nothing here names lamp's fns
comptime fn commands(T: type) -> void {
    attach fn run(this: T&, cmd: str) -> bool {
        comptime for (m) in @typeinfo(T).methods {
            comptime if (m.name.len > 4 && m.name[0..4] == "cmd_") {
                if (cmd == m.name[4..]) {
                    @field(this, m.name)();
                    return true;
                }
            }
        }
        return false;
    }
    attach fn commands(static this: T) -> std::string {
        var out = std::string::from("commands:");
        comptime for (m) in @typeinfo(T).methods {
            comptime if (m.name.len > 4 && m.name[0..4] == "cmd_") {
                out.append(" ");
                out.append(m.name[4..]);
            }
        }
        return out;
    }
}

comptime commands(lamp);

fn main() -> void {
    var l: lamp = { on: false, level: 0 };
    val script: str[] = { "toggle", "brighter", "fly" };
    for (cmd) in script {
        if (!l.run(cmd)) {
            std::println("no {}", cmd);
        }
    }
    val n: i32 = 4;
    std::println("{} {} {} {}", lamp::commands(), l.on, l.level, n.kib());
}
// expect: no fly
// expect: commands: toggle brighter true 10 4096
```

One call can write a lot. [examples/units.volt](https://github.com/ChaseSunstrom/volt-bootstrap/blob/main/examples/units.volt)
gives `conversions` 40 units and their lengths in meters, and it attaches a fn to `f64` for every
pair (`d.km_to_mi()`, 1560 of them) and declares `convert(v, "km", "mi")` over all of them:
`voltc expand examples/units.volt` lists every fn the call declared. [examples/attach_anything.volt](https://github.com/ChaseSunstrom/volt-bootstrap/blob/main/examples/attach_anything.volt)
adds `str` and `std::vec<T>` and a field printer, and
[attach-foreign](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/volt-calls/attach-foreign)
attaches fns to a C struct and C++ classes.
