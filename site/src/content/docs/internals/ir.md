---
title: The typed IR
description: What the checker hands the backends.
sidebar:
  order: 2
---

The checker lowers every function instance to a small typed IR (`voltc/src/ir.volt`), which both
backends read. The IR has already been through everything language-specific: templates are
instantiated, overloads resolved, moves and deletes made explicit, closures turned into structs,
async functions into state machines, and comptime code evaluated.

## Nodes

Nodes live in one arena, and a node is a `u32`. Every node has a type (a checker type id). A pure
value may be shared by several parents.

**Values and places:** `INT`, `FLOAT`, `BOOL`, `STR`, `CSTR`, `NULLPTR`, `ZERO`; `LOCAL` and
`GLOBAL` (places); `FIELD`, `DEREF`, `ADDR` and `INDEX`; `FN` (a function as a pointer) and `RT` (a
runtime function by name).

**Operations:** `UNARY`, `BINARY` (integers wrap, division truncates), `CHECKED` (add, subtract or
multiply that panics on overflow, with its source location), `CONV` and `BITCAST`, `CALL`, `AGG` (a
struct or other aggregate, fields by number), `ARRAY_LIT`, `COND`, `SEQ` (statements, then a value),
`SIZEOF`, `ALIGNOF`, `OFFSETOF`.

**Statements:** `DECL`, `ASSIGN`, `IF`, `LOOP`, `LABEL` and `GOTO`, `SWITCH` (no fallthrough),
`RETURN`, `BLOCK`, `UNREACHABLE`.

## Aggregates

Everything that isn't a scalar is an aggregate with numbered fields, so the backends need one
lowering for all of them:

| Type | Fields |
| --- | --- |
| struct, tuple | field or element `i` |
| closure | capture `i` |
| optional (not a pointer) | 0 the value, 1 whether there is one |
| slice, `str` | 0 pointer, 1 length |
| range | 0 low, 1 high |
| error union | 0 the error code, 1 the value |
| enum with payloads | 0 the tag, `1 + i` the payload of variant `i` |
| trait union | 0 the tag, `1 + i` member `i` |
| `fn(...)` value | 0 the function, 1 its environment |
| async frame | 0 state, 1 cancel, 2 result, `3 + i` slot `i` |

## Functions

An IR function has its parameters, locals, return type, a body, and a linkage: `STATIC` (private to
the unit), `EXPORTED` (visible to other units: `export fn`, package code in a library) or
`EXTERNAL` (declared here, defined elsewhere).
