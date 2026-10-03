---
title: Embedding Volt
description: libvoltvm runs Volt inside another program, as Lua does, compiling source in memory through LLVM's JIT with no C compiler.
sidebar:
  order: 10
---

`libvoltvm` puts Volt inside another program, the way Lua is embedded: the host makes a VM, hands
it Volt source text, and calls the functions that text exports. The library holds the compiler
itself and compiles in memory, through LLVM's ORC JIT, so nothing runs a C compiler or writes a
file. Its interface is a C one, and `bolt build` also writes it for C++, Rust and Python.

```sh
cd voltc/embed && bolt build      # target/debug/libvoltvm.so, and bindings/voltvm.{h,hpp,rs,py,pyi}
```

It needs LLVM 22, as voltc does, and runs on x86-64 for now (the hosts voltc's LLVM backend
compiles for).

## A VM

| | |
| --- | --- |
| `volt_vm_new(std_dir)` | a VM whose scripts see the std package in `std_dir` (`""`: no std at all) |
| `volt_vm_load(vm, name, source)` | compiles `source` and adds it; errors name the file `name` |
| `volt_vm_find(vm, name)` | the address of an `export fn` (0 when there's none) |
| `volt_vm_define(vm, name, address)` | a host function the scripts can call |
| `volt_vm_allow(vm, symbol)` | makes the VM a sandbox that reaches `symbol` (and only what it's given); before its first load |
| `volt_vm_release(vm, on)` | optimize scripts, with overflow wrapping as in `--release` |
| `volt_vm_error(vm)` | what the last failure was: the compiler's diagnostics, or LLVM's message |
| `volt_vm_free(vm)` | frees the VM and the code it compiled |

A script is an ordinary Volt file without a `main`. Its `export fn`s have the C calling convention
and their own names, so the host casts what `volt_vm_find` gives it to a function pointer of the
same C signature and calls it. Each load is compiled on its own, with the parts of std it uses, so
two scripts can't see each other's names, and only an `export fn` name can clash. A script's
globals are set up when it loads.

```c
#include <stdio.h>
#include <string.h>
#include "voltvm.h"

static volt_str S(const char *s) { return (volt_str){ (const uint8_t *)s, strlen(s) }; }

static long long host_twice(long long x) { return 2 * x; }   // given to the script

int main(void) {
    voltvm_volt_vm *vm = volt_vm_new(S("/usr/lib/volt/std"));
    volt_vm_define(vm, S("host_twice"), (size_t)host_twice);
    const char *src =
        "use std::io;\n"
        "extern \"C\" fn host_twice(x: i64) -> i64;\n"
        "export fn add(a: i64, b: i64) -> i64 { return host_twice(a) + b; }\n"
        "export fn hello() -> void { std::println(\"hello from volt\"); }\n";
    if (volt_vm_load(vm, S("script.volt"), S(src)).error) {
        volt_str e = volt_vm_error(vm);                  // the diagnostics, as voltc prints them
        fprintf(stderr, "%.*s", (int)e.len, (const char *)e.ptr);
        return 1;
    }
    long long (*add)(long long, long long) = (void *)volt_vm_find(vm, S("add"));
    printf("%lld\n", add(20, 2));                        // 42
    ((void (*)(void))volt_vm_find(vm, S("hello")))();    // hello from volt
    volt_vm_free(vm);
}
```

```sh
cc host.c -I target/debug/bindings -L target/debug -lvoltvm -Wl,-rpath,$PWD/target/debug
```

## Host functions

A script declares a host function as it would a C one, `extern "C" fn name(...) -> R;`, and
`volt_vm_define` gives that name an address before the script loads. Arguments and results cross
as they do for C: integers, floats, `bool`, pointers, structs of those, and `str` as a pointer and a
length ([what crosses as what](/volt-bootstrap/interop/other-languages/#they-call-volt)).

## Sandboxes

By default a script reaches what the process can: the C library and every exported symbol, as a
program linked with it would. The first `volt_vm_allow` makes the VM a sandbox instead: from the
process it reaches only the symbols allowed this way, plus what the runtime needs. That is the
runtime's own functions (not the rest of what libvoltvm exports, so a script can't make a VM of its
own), the memory functions LLVM calls by itself (`memcpy`, `memmove`, `memset`, `memcmp`), and the C
functions the runtime is built on: `malloc`, `realloc`, `free`, `strlen`, `strtod`, the `printf`
family (`printf`, `dprintf`, `snprintf` and their `v` forms), `fwrite`, `fwrite_unlocked`, `stdout`
and `exit`. A script that declares anything else fails to load:

```text
Symbols not found: [ getpid ] (this VM is a sandbox: it reaches only the symbols volt_vm_allow gave it)
```

The std a script sees is the other half: a std directory with only some modules in it is a smaller
std, and `""` is none, so a script has only its own code and the host's functions. A sandbox's
allowances are fixed at its first load; `volt_vm_allow` after that is an error.

A sandbox decides what a script can name, not what it can do with memory: Volt has raw pointers and
`@cast`, so a script that means harm can still reach past it. It keeps scripts you trust to their
part of the program; it isn't a boundary against code you don't.

## Python

The generated module wraps the VM in a class; `ctypes` turns a found address into something
callable, and a Python function into a host function:

```python
import ctypes
import voltvm   # target/debug/bindings, with VOLT_VOLTVM_LIB=target/debug/libvoltvm.so

@ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)
def square(x):
    return x * x

with voltvm.volt_vm("/usr/lib/volt/std") as vm:
    vm.define("host_square", ctypes.cast(square, ctypes.c_void_p).value)
    vm.load("calc.volt", """
extern "C" fn host_square(x: i64) -> i64;
export fn sum_squares(n: i64) -> i64 {
    var total: i64 = 0;
    for (i) in 1..n + 1 {
        total += host_square(i);
    }
    return total;
}
""")
    sum_squares = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(vm.find("sum_squares"))
    print(sum_squares(10))          # 385
    try:
        vm.load("bad.volt", "export fn broken() -> i32 { return nope; }\n")
    except voltvm.vm_error as e:    # e.name is "COMPILE"
        print(vm.error())           # error: unknown name 'nope' ...
```

## Rust

The generated `voltvm.rs` has the same class, with `Result`s:

```rust
#[path = "voltvm.rs"]
mod voltvm;

extern "C" fn cube(x: i64) -> i64 {
    x * x * x
}

fn main() {
    let vm = voltvm::volt_vm::new("/usr/lib/volt/std");
    vm.define("host_cube", cube as extern "C" fn(i64) -> i64 as usize).unwrap();
    vm.load("cubes.volt", "extern \"C\" fn host_cube(x: i64) -> i64;\n\
                           export fn cube_of(n: i64) -> i64 { return host_cube(n); }\n").unwrap();
    let cube_of: extern "C" fn(i64) -> i64 = unsafe { std::mem::transmute(vm.find("cube_of")) };
    println!("{}", cube_of(4));   // 64
}
```

```sh
rustc --edition 2021 main.rs -L target/debug -l voltvm
```

## Limits

- A script can't import C headers or code in other languages: those need a C compiler or bolt at
  run time.
- A panic in a script (a failed bounds check, an overflow in a debug VM, `@panic`) ends the
  process, as it would in a Volt program.
- A script's code stays until its VM is freed; loading again with the same `export fn` names is an
  error, so a new version of a script goes in a new VM.
