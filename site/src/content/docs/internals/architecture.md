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
| `check.volt`, `program.volt`, `util.volt` | the checker's state, collecting, the whole-program walk, and its helpers |
| `types.volt`, `resolve.volt` | interned types; types, instances and constants from syntax |
| `expr.volt`, `stmt.volt`, `places.volt`, `operators.volt`, `calls.volt` | checking and lowering code |
| `generics.volt` | templates: inference and overload resolution |
| `ownership.volt` | what needs deleting, drop and copy glue, moves |
| `lends.volt`, `borrows.volt` | what can't change through references; the borrow warnings |
| `errors.volt`, `enums.volt`, `matching.volt` | error unions and optionals, enums, match |
| `closures.volt`, `asyncs.volt`, `comptime.volt` | closures, async frames, the comptime interpreter |
| `print.volt` | checked format strings |
| `cimport.volt`, `cuse.volt`, `cppimport.volt`, `clang.volt` | C and C++ headers (libclang for layouts, C++, and C macros and varargs calls per use) |
| `langimport.volt`, `rustgen.volt` | `use` of code in other languages (bolt imports it), and instances of its generics |
| `ir.volt` | the typed IR |
| `cgen.volt`, `lgen.volt` | the C and LLVM backends |
| `target.volt` | bare metal (`--target`): the targets and voltc's start code |
| `diag.volt`, `suggest.volt` | diagnostics and "did you mean" |
| `bindings.volt`, `doc.volt`, `lsp.volt`, `lsp_inline.volt` | bindings for other languages, `voltc doc`, the language server |
| `vm.volt` | Volt embedded in another program (`voltc/embed`), run by LLVM's JIT |
| `main.volt` | the command line |
| `sys.volt` | what voltc asks of the system where std has no call for it (build directories, canonical paths, the language server's streams), on Unix and Windows |
| `runtime_c.volt` | the C runtime's text, generated from `runtime/` |

## The rest of the repository

| Path | |
| --- | --- |
| `runtime/` | the C prelude and runtime every hosted program includes |
| `std/` | the standard library package |
| `bolt/` | the build tool (Rust) and its build-file API package (`bolt/api`) |
| `interop/` | packages for using Python, Lua, Java and .NET from Volt and writing Node addons in it, and the helpers that build a Volt package from Cargo, Zig, npm and pip |
| `examples/` | example programs (the golden tests run them), bare metal and interop examples |
| `bench/` | the [benchmark](/volt-bootstrap/internals/benchmarks/) programs, in Volt, C, C++, Rust and Zig |
| `editors/vscode/` | the VS Code extension |
| `site/` | this website |
| `assets/logo/` | the logo generator |
| `tests/` | the test suites: see [Testing](/volt-bootstrap/internals/testing/) |
