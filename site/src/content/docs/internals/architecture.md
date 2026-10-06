---
title: Architecture
description: The two compilers, the pipeline, and where each part lives.
sidebar:
  order: 1
---

Volt has one compiler, and a second that builds it the first time:

- **voltc** (`voltc/src/`): the compiler, written in Volt. It generates C or, through LLVM, native
  code, and adds the C++ importer, the language server, bindings and docs. The language changes
  here.
- **voltc-bootstrap** (`bootstrap/`): the stage0 compiler, in Rust with no crates, generating C.
  It exists to build voltc from `voltc/src`, and it's frozen: it compiles what voltc's own sources
  use, not features added since (see [Bootstrapping](/volt-bootstrap/internals/bootstrap/)).

## The pipeline

```
source ─▶ lexer ─▶ parser ─▶ checker ─▶ typed IR ─┬─▶ cgen ─▶ C ─▶ cc ─▶ executable
                                                   └─▶ lgen ─▶ LLVM ─▶ object ─▶ cc (link)
```

1. **Lexing and parsing** turn each file into a syntax tree. The files of a package are wrapped in
   its namespace.
2. **Collecting** declares every item in its namespace and imports C (and C++) headers.
3. **Checking** starts from the roots (`main`, and every non-generic function), resolves types,
   instantiates templates as they're used, runs comptime code, checks ownership, and lowers each
   function instance to the IR. An error ends one function; the others go on.
4. **A backend** turns the IR into C or LLVM IR.

## voltc's sources

| File | What it does |
| --- | --- |
| `lexer.volt`, `parser.volt`, `parser_expr.volt`, `ast.volt` | source to syntax tree |
| `sexp.volt` | the canonical tree text (`parse --sexp`) |
| `check.volt`, `program.volt` | the checker's state, collecting, and the whole-program walk |
| `types.volt`, `resolve.volt` | interned types; types, instances and constants from syntax |
| `expr.volt`, `stmt.volt`, `places.volt`, `operators.volt`, `calls.volt` | checking and lowering code |
| `generics.volt` | templates: inference and overload resolution |
| `ownership.volt` | what needs deleting, drop and copy glue, moves |
| `errors.volt`, `enums.volt`, `matching.volt` | error unions and optionals, enums, match |
| `closures.volt`, `asyncs.volt`, `comptime.volt` | closures, async frames, the comptime interpreter |
| `print.volt` | checked format strings |
| `cimport.volt`, `cppimport.volt`, `clang.volt` | C and C++ headers (libclang for layouts and C++) |
| `ir.volt` | the typed IR |
| `cgen.volt`, `lgen.volt` | the C and LLVM backends |
| `diag.volt`, `suggest.volt` | diagnostics and "did you mean" |
| `bindings.volt`, `doc.volt`, `lsp.volt` | bindings for other languages, `voltc doc`, the language server |
| `main.volt` | the command line |
| `runtime_c.volt` | the C runtime's text, generated from `runtime/` |

## The rest of the repository

| Path | |
| --- | --- |
| `runtime/` | the C prelude and runtime every program includes |
| `std/` | the standard library package |
| `bolt/` | the build tool (Rust) and its build-file API package (`bolt/api`) |
| `editors/vscode/` | the VS Code extension |
| `site/` | this website |
| `assets/logo/` | the logo generator |
| `tests/` | the test suites: see [Testing](/volt-bootstrap/internals/testing/) |
