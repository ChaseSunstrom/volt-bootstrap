---
title: Text and strings
description: str and std::string, searching, splitting and parsing text, building it with format, and UTF-8.
sidebar:
  order: 2
---

Text is bytes, UTF-8 by convention. A `str` is a view: a pointer and a length that owns nothing
and can't be changed through, as a string literal is. A `std::string` owns its bytes and grows;
`as_str()` views it as a `str` until it changes. Functions that read text take a `str`, so a
literal, a slice of one and a `std::string` all go in the same way.

## Searching, trimming and splitting

`std::text` attaches its methods to `str`. `find`, `contains`, `starts_with`, `trim`,
`strip_prefix`, `split_once` and the rest give answers or views into the same bytes, without
copying; `split`, `lines` and `words` give a `std::vec<str>` of views.

```volt
use std::io;
use std::text;

fn main() -> void {
    val line = "  name = volt ; tags = fast,small  ";
    for (field) in line.trim().split(";").items() {
        val (key, value) = field.split_once("=") ?? continue;
        std::println("{}: {}", key.trim(), value.trim());
    }
    val rest = line.trim().strip_prefix("name") ?? "";
    std::println("{} {} {}", "fast,small".split(",").len, line.contains("volt"), rest.find("tags") ?? 0);
}
// expect: name: volt
// expect: tags: fast,small
// expect: 2 true 10
```

Byte indexes and slices (`s[2..5]`) work on a `str` too; a slice that cuts a UTF-8 character in
half is still bytes, so split on what you searched for.

## Building text

A `std::string` grows with `append`, `push` (a byte), `push_char` (a character, as UTF-8) and
`append_int`; `s[i]` is its byte `i` (a `u8`, not a character), a place like a vec's element.
`std::format` builds one from a format string, with the same `{}` and specifiers as
[printing](/volt-bootstrap/guide/printing/); `std::write` adds to one that exists. `replace`,
`repeat`, `to_upper` and `to_lower` make a new one from a `str`, and `std::join` puts parts
together:

```volt
use std::io;
use std::text;
use std::fmt;

fn main() -> void {
    var s = std::string::from("volt");
    s.append(" ");
    s.append_int(42);
    s.push('!');
    s[0] = 'V';
    val f = std::format("{}-{:>5}|{:.2}", "a", 7, 3.14159);
    val parts: str[3] = { "x", "y", "z" };
    std::println("{} {} {}", s, f, std::join(parts[..], "+"));
    std::println("{} {} {}", "a-b-c".replace("-", "/"), "ab".repeat(3), "Volt".to_upper());
}
// expect: Volt 42! a-    7|3.14 x+y+z
// expect: a/b/c ababab VOLT
```

A `std::string` is a writer, so anything that writes text (`std::write`, a type's own `write`
hook) can write into one.

## Numbers and booleans from text

`parse_int`, `parse_uint`, `parse_float` and `parse_bool` read the whole `str` and fail with a
`std::text::parse_error`: `EMPTY`, `INVALID` (a character that doesn't belong, spaces included) or
`OVERFLOW`:

```volt
use std::io;
use std::text;

fn main() -> void {
    val n = "42".parse_int() catch 0;
    val x = "2.5e3".parse_float() catch 0.0;
    val big = "99999999999999999999".parse_int() catch |e| {
        std::println("{}", e);
        return;
    };
    std::println("{} {} {}", n + 1, x, big);
}
// expect: OVERFLOW
```

## Characters and UTF-8

`len` counts bytes. `char_count` counts characters, `chars` lists them as code points, and
`char_at(i)` decodes the one starting at byte `i` with its length. `is_utf8` checks text that came
from outside (a file, the network), and `utf8_error` says where it goes wrong. On a byte, `u8`
has the ASCII classes: `is_digit`, `is_alpha`, `is_space`, `to_upper` and the rest.

```volt
use std::io;
use std::text;

fn main() -> void {
    val word = "héllo";
    var digits = 0;
    for (b) in "a1b22" {
        if (b.is_digit()) {
            digits += 1;
        }
    }
    val (c, n) = word.char_at(1) ?? (0, 0);
    std::println("{} {} {} {} {}", word.len, word.char_count(), word.is_utf8(), c, n);
    std::println("{}", digits);
}
// expect: 6 5 true 233 2
// expect: 3
```
