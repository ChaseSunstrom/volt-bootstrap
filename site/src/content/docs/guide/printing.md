---
title: Strings and printing
description: str, cstr and std::string; formatted printing.
sidebar:
  order: 14
---

## Three kinds of text

| Type | What it is | Owns its bytes |
| --- | --- | --- |
| `str` | a UTF-8 view: pointer and length | no |
| `cstr` | a null-terminated C string | no |
| `std::string` | growable text | yes |

String literals are `str`s that also keep a hidden `\0`, so they convert to `cstr` for C. A `str`
indexes to bytes (`s[0]` is a `u8`), slices with `s[a..b]`, has `.len`, and compares with `==`.

```volt
use std::io;

fn main() -> void {
    val s = "hello, volt";
    val word = s[7..11];
    var count = 0;
    for (b) in s {
        if (b == 'l') {
            count += 1;
        }
    }
    std::println("{} {} {} {}", word, s.len, count, word == "volt");
}
// expect: volt 11 3 true
```

`std::string` owns and grows its text; `as_str()` views it as a `str`, and `c_str()` as a `cstr`.

```volt
use std::io;

fn main() -> void {
    var s = std::string::from("count: ");
    s.append_int(42);
    s.push('!');
    std::println("{} ({} bytes)", s, s.len());
}
// expect: count: 42! (10 bytes)
```

## Working with text

`std::text` gives `str` the usual tools as methods: searching (`find`, `rfind`, `contains`,
`starts_with`, `ends_with`, `count`), trimming (`trim`, `strip_prefix`, `strip_suffix`), splitting
(`split`, `split_once`, `lines`, `words`), new text (`replace`, `repeat`, `to_upper`, `to_lower`)
and parsing (`parse_int`, `parse_uint`, `parse_float`, `parse_bool`). Splitting gives views into the
text, so nothing is copied; the functions that make new text return a `std::string`. `parse_float`
gives the double nearest the text, ties to even, so it reads back exactly what printing wrote, however
many digits it has.

```volt
use std::io;
use std::text;

fn main() -> void {
    val line = "  name=Ada Lovelace ; born=1815  ";
    val fields = line.trim().split(";");
    for (f) in fields.items() {
        val kv = f.trim().split_once("=") ?? continue;
        std::print("[{}: {}] ", kv.0, kv.1.to_upper());
    }
    std::println("");
    val year = "1815".parse_int() catch 0;
    val bad = "18x5".parse_int();
    std::println("{} {} {}", year + 200, bad, "a-b-c".replace("-", "::"));
}
// expect: [name: ADA LOVELACE] [born: 1815] 
// expect: 2015 error.INVALID a::b::c
```

Text is UTF-8: `char_count`, `chars` and `char_at` read characters, and `is_utf8` checks that the
bytes are valid. On a `u8`, `is_digit`, `is_alpha`, `is_space` and friends classify ASCII.

## Printing

`std::println(format, args...)` prints a line; `std::print` leaves out the newline; `eprintln` and
`eprint` go to stderr. Each `{}` in the format takes the next argument; `{{` and `}}` print braces.
The format is checked while compiling: the count of `{}`s has to match the arguments.

```volt
use std::io;

struct point { x: i32; y: i32; }

enum dir { UP, DOWN }

fn main() -> void {
    val p: point = { x: 1, y: 2 };
    val xs: i32[] = { 1, 2, 3 };
    val maybe: i32? = null;
    std::println("{} {} {} {}", p, xs, dir::UP, maybe);
    std::println("{{literal braces}} {}", true);
    std::println(3.5);                  // one value, no format
}
// expect: point { x: 1, y: 2 } { 1, 2, 3 } UP null
// expect: {literal braces} true
// expect: 3.5
```

Everything prints: numbers, booleans, text, arrays and slices, tuples, structs (their fields),
enums (the variant and its payload), optionals, and error unions (`error.NAME` for an error). A
float prints as the shortest text that reads back as the same value (`0.1`, not
`0.10000000000000001`); infinities print as `inf` and `-inf`, and NaN as `nan`. A reference or
pointer prints the address it holds; print `*r` for the value.

```volt fail
use std::io;

fn main() -> void {
    std::println("{} and {}", 1);
}
// error: format string has 2 {} but 1 values were given
```

## Format specifiers

A `{}` can carry a spec after a colon, as in Rust: `{:[[fill]align][sign][#][0][width][.precision][type]}`.

| Part | Means |
| --- | --- |
| `<` `>` `^` | align left, right or centre in the width (numbers go right by default, text left) |
| fill | the character before an alignment pads with it: `{:*^9}` |
| `+` | always show the sign of a number |
| `#` | with `x`, `b` or `o`: the `0x`, `0b` or `0o` prefix |
| `0` | pad a number with zeros after its sign: `{:05}` makes `-0042` |
| width | at least this many characters |
| `.precision` | digits after the point for a float; at most this many characters of text |
| type | `x` `X` hex, `b` binary, `o` octal, `c` an integer as a character; `e` `E` a float with an exponent |

```volt
use std::io;

fn main() -> void {
    std::println("[{:6}] [{:<6}] [{:^6}] [{:*>6}]", 42, 42, "mid", "r");
    std::println("{:+} {:05} {:x} {:#X} {:08b} {:#o}", 7, -42, 255, 255, 5, 8);
    std::println("{:.2} {:8.3} {:e} {:.1e}", 3.14159, 2.5, 1500.0, 0.000123);
    std::println("[{:.3}] {:c}{:c}", "truncated", 'o', 107);
    val m: i8 = -1;
    std::println("{:x}", m);           // two's complement at the value's width
}
// expect: [    42] [42    ] [ mid  ] [*****r]
// expect: +7 -0042 ff 0xFF 00000101 0o10
// expect: 3.14    2.500 1.5e3 1.2e-4
// expect: [tru] ok
// expect: ff
```

A spec applies to numbers, `bool`, characters and text (`str`, `cstr`, and types that attach
`as_str`, like `std::string`); on anything else, or a spec that doesn't fit the value (`{:x}` on a
float, a precision on an integer), it's a compile error.

## Formatting into strings and writers

`std::format` returns the formatted text as a `std::string`, and `std::write(&out, ...)` appends it
to `out`. Both are in `std::fmt`, and take the same formats and specs as `println`.

```volt
use std::io;
use std::fmt;

fn main() -> void {
    val label = std::format("{}-{:03}", "item", 7);
    var log: std::string = {};
    std::write(&log, "[{}] ", label);
    std::write(&log, "{:.1}%", 99.25);
    std::println("{}", log);
}
// expect: [item-007] 99.2%
```

`std::write` works on any type that attaches `write_str(this: T&, s: str) -> void`: the compiler
hands it the text piece by piece. That's all a writer needs to be, so a library can make its own.

```volt
use std::io;
use std::fmt;

struct counter {
    chars: usize = 0;
}

attach fn write_str(this: counter&, s: str) -> void {
    this.chars += s.len;
}

fn main() -> void {
    var c: counter = {};
    std::write(&c, "{:>10}|{}", "abc", 12345);
    std::println("{}", c.chars);
}
// expect: 16
```
