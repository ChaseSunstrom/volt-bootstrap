---
title: Diagnostics
description: How voltc reports errors, the three output formats, and what it checks past an error.
sidebar:
  order: 2
---

An error shows the code it's about, underlines the exact place, labels other places that explain
it, and adds notes and suggestions:

```
error: 'items' was moved earlier (by move, an assignment, an argument or a return), so it can't be used here
   ┌─ app.volt:10:30
   │
 9 │     val n = consume(items);
   │                     ----- moved here
10 │     std::println("{} {}", n, items.len);
   │                              ^^^^^
```

```
error: point has no field 'z'
  ┌─ app.volt:5:19
  │
5 │     val d = p.x + p.z;
  │                   ^^^
  │
  = help: did you mean 'x'?
```

A misspelled name gets the closest real one as a suggestion. Checking doesn't stop at the first
error: an error ends the function it's in, and the other functions are still checked. Parsing works
the same way: a syntax error ends the item it's in (a function, a struct), and the parser picks up
again at the next item, using the indentation to find it. So one run finds every independent error;
it shows the first 20 in source order, and the summary line says how many there were.
`--error-limit N` shows N instead (`0`: all of them). Warnings (like using a `@deprecated`
function) print the same way and don't fail the build.

## Formats

`--message-format` picks one:

**human** (the default): the form above, coloured on a terminal.

**short**: one line per diagnostic, for editors and grep:

```
app.volt:5:19: error: point has no field 'z'
```

**json**: one JSON object per line, for tools:

```json
{"severity":"error","message":"point has no field 'z'","file":"app.volt","line":5,"column":19,"end_line":5,"end_column":22,"labels":[],"notes":["help: did you mean 'x'?"]}
```

Each label has its own file, line, column and message. Lines and columns start at 1.

## Colour

`--color auto` (the default) colours output on a terminal unless `NO_COLOR` is set or `TERM` is
`dumb`; `always` and `never` force it.

In colour, a type mismatch highlights where the two types differ: in `expected std::vec<i32>, found
std::vec<i64>`, only `i32` and `i64` light up, however long the rest of the types is.

## In editors

The [language server](/volt-bootstrap/editors/lsp/) reports the same diagnostics as you type, and
the VS Code extension's `$volt` problem matcher links the human format to the code in build tasks.
