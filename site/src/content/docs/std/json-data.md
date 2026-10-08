---
title: JSON
description: "std::json: parsing JSON text into values, reading them, and building and printing new ones; std::html templates rendered from them."
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

## HTML templates

`std::html::escaped(s)` is `s` with `&`, `<`, `>`, `"` and `'` as entities, safe in an element's
text and in a quoted attribute (`escape(s, &out)` appends it). A `std::html::template` is HTML with
tags in it, parsed once (`template::parse(text)`, or `template::read(path)` for a file) and rendered
from a JSON value as often as needed:

- `{{path}}` is the value at path, escaped: a string, a number, `true` or `false`.
- `{{{path}}}` is the value as it is, for HTML made elsewhere.
- `{{for x in path}}...{{end}}` is the body once per element of the array at path, as `x`.
- `{{if path}}...{{else}}...{{end}}` is the first part when the value is `true`, a non-empty string,
  array or object, or a number other than 0, and the second (optional) part when it isn't.

A path is names joined by dots (`p.name`); its first name is a loop's variable or a member of the
value. A template's text can't hold a `{{` of its own (a script's, say): give it as a value. `render` fails with `template_error::MISSING` for a slot or a loop the value doesn't have,
`parse` with `template_error::SYNTAX` for a tag it can't read (an unclosed `{{for}}`, an `{{end}}`
with nothing open, a path that isn't one) and `read` with `template_error::READ` for a file it can't
read. The site's pages are templates like this (`site/theme`).

```volt
use std::io;
use std::html;
use std::json;

fn main() -> !void {
    val list = try std::html::template::parse("<h1>{{title}}</h1><ul>{{for p in pages}}<li{{if p.new}} class=\"new\"{{end}}>{{p.name}}</li>{{end}}</ul>");
    val data = try std::json::parse("{\"title\": \"Fish & chips\", \"pages\": [{\"name\": \"<menu>\", \"new\": true}, {\"name\": \"prices\"}]}");
    var out: std::string = {};
    try list.render(&data, &out);
    std::println("{}", out.as_str());
}
// expect: <h1>Fish &amp; chips</h1><ul><li class="new">&lt;menu&gt;</li><li>prices</li></ul>
```
