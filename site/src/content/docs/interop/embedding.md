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
cd voltc/embed && bolt build      # target/debug/libvoltvm.so (.dylib on macOS, voltvm.dll on Windows), and bindings/voltvm.{h,hpp,rs,py,pyi}
```

It needs LLVM 23, as voltc does, and runs on x86-64 and aarch64 (the hosts voltc's LLVM backend
compiles for).

## A VM

| | |
| --- | --- |
| `volt_vm_new(std_dir)` | a VM whose scripts see the std package in `std_dir` (`""`: no std at all) |
| `volt_vm_load(vm, name, source)` | compiles `source` and adds it, as the package its file names (`util.volt` is `util`); errors name the file `name` |
| `volt_vm_find(vm, name)` | the address of an `export fn`, or of a host function (0 when there's none) |
| `volt_vm_define(vm, name, address)` | a host function the scripts can call |
| `volt_vm_allow(vm, symbol)` | makes the VM a sandbox that reaches `symbol` (and only what it's given); before its first load |
| `volt_vm_release(vm, on)` | optimize scripts, with overflow wrapping as in `--release` |
| `volt_vm_error(vm)` | what the last failure was: the compiler's diagnostics, or LLVM's message |
| `volt_vm_free(vm)` | frees the VM and the code it compiled |

A script is an ordinary Volt file without a `main`. Its `export fn`s have the C calling convention
and their own names, so the host casts what `volt_vm_find` gives it to a function pointer of the
same C signature and calls it. Each script is a package, named for its file, that the scripts
loaded after it can use ([below](#scripts-as-packages)); only an `export fn` name can clash between
scripts. A script's globals are set up when it loads.

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

## Scripts as packages

A script is the package its file names: the name `volt_vm_load` is given, without its directories
and extension (`scripts/util.volt` is `util`). A script loaded later reaches its `public` types,
functions, generics and globals as `util::...`, as a program reaches a package:

```c
volt_vm_load(vm, S("util.volt"),
    "public struct point { x: i32; y: i32; }\n"
    "public var made: i32 = 0;\n"
    "public fn make(x: i32, y: i32) -> point { made += 1; return { x: x, y: y }; }\n");
volt_vm_load(vm, S("main_script.volt"),
    "export fn run() -> i32 { val p = util::make(3, 4); return p.x + p.y + util::made; }\n");
```

The later script is compiled against what the VM already has of the earlier one: `util::make` is
the code util's load compiled, and `util::made` is util's own global, not a copy (a generic is
made for the script that uses it, from util's source). In a sandbox that's no symbol the host has
to allow: scripts' code meets inside the VM.

Loading a name again replaces that script, when no script loaded since uses it; when one does, the
load is refused naming it (`can't load util.volt again: main_script uses it`), and the earlier
script stays. A load that fails to compile changes nothing; one that fails to link (a symbol that
isn't there) leaves nothing of itself behind, no package and no code, and a script it was replacing
is gone too (its code makes way before the new code is added). A file whose name can't be a package's (`my-util.volt`, a keyword, or
`std`) is refused, and so is a second file of one name (`b/init.volt` after `a/init.volt`). A
script whose C or C++ imports were built into a library (outside a sandbox) can't be loaded again:
the library stays loaded, and the new code's symbols would come from it.

A later script that uses an earlier one importing C or C++ runs no compiler for those imports: the
earlier load built them, and its headers' text is kept (read again when a file the headers read,
the ones they include among them, changed on disk; the C compiler lists them with `-H`; with one that
doesn't, such as tcc, only the headers the imports name are watched, not those they include). Only what the later script's own code calls
(a header's function, a C++ wrapper, through its own imports or a generic made for it) is built for
it. A C++ header doing `import std;` has the C++ library's std module built once, by the first load
that needs it, for the VM's later loads.

An earlier script's global holding a trait's values (`public var held: shape? = null;`) was laid out,
and that script's code built, for the types attached to the trait when it loaded. A later script
attaching the trait to another type is refused, naming the trait and the global (`the global
shapes::held holds shape's union, ...: a later script can't attach shape to another type`); one that
only uses the global loads. For the same reason a script attaching the trait before the global's
script loaded can't be loaded again (`can't load cube.volt again: the global tank::held holds
solid's union, ..., cube's among them`): the union's tags would change.

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

A sandbox's script imports C and C++ headers too, but their code isn't a library the VM loads (a
library's code would reach past the sandbox): clang compiles it to LLVM bitcode, and the JIT runs
it with the script, so what it calls goes through the same allowances. `$CC` and `$CXX` (else
`clang` and `clang++`) must be clang of the LLVM the VM runs (23): anything else is refused,
naming clang:

```text
a sandbox's script imports C++ through clang++ (LLVM bitcode, run by the JIT under the sandbox), and $CXX is g++
```

The host allows the C functions a script's imports call (`strlen` for `use { "string.h" }`), and
for C++ what the header's code needs from the C++ library: on Linux with libstdc++, a header with a
`std::vector` member needs `_Znwm` and `_ZdlPvm` (new and delete), its errors
(`_ZSt20__throw_length_errorPKc`, `_ZSt28__throw_bad_array_new_lengthv`,
`_ZSt17__throw_bad_allocv`, and `_ZSt21__glibcxx_assert_failPKciS0_S0_` for an unoptimized
build's checks) and exceptions (`__gxx_personality_v0`, `__cxa_begin_catch`, `__cxa_end_catch`,
`__cxa_rethrow`, `_Unwind_Resume`, `_ZSt9terminatev`, `_ZSt17current_exceptionv`,
`_ZTVN10__cxxabiv117__class_type_infoE`), and every C++ import's glue `fprintf`, `stderr` (a C++
exception reaching Volt stops the program, printing it) and `longjmp` (one leaving a call C++ made
into Volt). Clang's own helpers for 128-bit arithmetic and thread locals (`__udivti3`,
`__emutls_get_address`, ...) are allowed with the memory functions. The libraries an import names
aren't loaded (loading one runs its code); their symbols come from what the process already has.

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
import voltvm   # from target/debug/bindings; it finds target/debug's library itself

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

- A script imports C and C++ headers (and C++ modules) when the compilers are on `PATH` (`$CC`, and
  `$CXX` for C++): what the imports need (a header's functions, the calls made per use, C++'s
  wrappers) is compiled into a library the VM loads with the script, linked with the libraries the
  imports name. In a sandbox it's LLVM bitcode clang writes ([above](#sandboxes)), and C++ modules
  can't be imported (a module's interface is native code).
- A panic in a script (a failed bounds check, an overflow in a debug VM, `@panic`) ends the
  process, as it would in a Volt program.
- A script's code stays until it's loaded again or its VM is freed; a script that others use can't
  be replaced, so a new version of it goes in a new VM. Two scripts' `export fn`s can't share a name.
