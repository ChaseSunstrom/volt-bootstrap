---
title: JSON
description: "std::json: parsing JSON text into values, reading them, and building and printing new ones."
sidebar:
  order: 8
---

`std::json::value` is one JSON value: an enum of `NULL`, `BOOL`, `NUM` (an `f64`: JSON has one kind
of number), `STR` (a `std::string`), `ARR` (a `std::vec` of values) and `OBJ` (its members, in the
order the text had them). It owns everything in it, from the allocator it was made with.

## Reading

`std::json::parse` reads a whole text: whitespace around the value is fine, anything else after it
fails with `SYNTAX`, as does nesting deeper than 512. `get(key)` reaches an object's member and
`at(i)` an array's element; either gives a `null` value when there's none, so a chain like
`doc.get("a").at(0).get("b")` never fails, and its end says whether it found anything.
`as_str`, `as_num` and `as_bool` give the value when it's that kind, and null when it isn't:

```volt
use std::io;
use std::json;

fn main() -> !void {
    val text = "{ \"name\": \"volt\", \"tags\": [\"fast\", \"small\"], \"stars\": 5, \"license\": null }";
    val doc = try std::json::parse(text);
    std::println("{} {}", doc.get("name").as_str() ?? "?", doc.get("stars").as_num() ?? 0.0);
    for (i) in 0..doc.get("tags").len() {
        std::println("tag {}", doc.get("tags").at(i).as_str() ?? "?");
    }
    std::println("{} {}", doc.get("license").is_null(), doc.get("missing").at(3).is_null());
    val broken = std::json::parse("{ \"a\": 1 } x");
    std::println("{}", broken.err);
}
// expect: volt 5
// expect: tag fast
// expect: tag small
// expect: true true
// expect: SYNTAX
```

`len()` is an array's element count or an object's member count. To walk an object's members,
match on the value: `.OBJ(ms&)` gives the `std::vec` of members, each with its `name` and `item`.

```volt
use std::io;
use std::json;

fn main() -> !void {
    val doc = try std::json::parse("{ \"x\": 1, \"y\": [true, false] }");
    match (doc) {
        .OBJ(ms&) => {
            for (m&) in ms.items() {
                std::println("{} has {} items", m.name, m.item.len());
            }
        },
        default => {},
    }
}
// expect: x has 0 items
// expect: y has 2 items
```

## Building and printing

`std::json::object()` and `array()` start empty; `set(key, v)` adds a member (or replaces the one
with that key) and `add(v)` appends an element. `string`, `number`, `boolean` and `null_value` make
the rest. `text()` prints a value as compact JSON, escaping what JSON needs escaped, and `write`
appends it to a `std::string` that exists:

```volt
use std::io;
use std::json;

fn main() -> void {
    var tags = std::json::array();
    tags.add(std::json::string("fast"));
    tags.add(std::json::string("say \"hi\""));
    var doc = std::json::object();
    doc.set("name", std::json::string("volt"));
    doc.set("stars", std::json::number(5.0));
    doc.set("tags", move tags);
    doc.set("draft", std::json::boolean(false));
    std::println("{}", doc.text());
}
// expect: {"name":"volt","stars":5,"tags":["fast","say \"hi\""],"draft":false}
```

A value made from a `std::mem::arena` (`parse(text, arena.allocator())`) puts all of its strings and
arrays in the arena, which frees them together; see [Allocators](/volt-bootstrap/std/allocators/).
