---
title: Python
description: Calling Python from Volt with the interop/python package, and Volt from Python through generated bindings.
sidebar:
  order: 4
---

The `interop/python` package (in the repository) embeds the Python interpreter. Depend on it and
call Python with Volt values; its build file asks `python3-config` (or `$PYTHON_CONFIG`) for the
headers and the library, and bolt passes them to your program.

```toml
# bolt.toml
[dependencies]
python = { path = "../volt/interop/python" }
```

```volt ignore
use std::io;

fn run() -> python::python_error!void {
    val math = try python::import("math");
    val root = try (try math.call_method("sqrt", 2.0)).to_f64();
    std::println("{:.4}", root);                                   // 1.4142

    try python::exec("def greet(who):\n    return 'hi ' + who\n");
    val greet = try python::eval("greet");
    std::println("{}", try (try greet.call("volt")).to_string());  // hi volt

    val bad = python::eval("1 / 0");
    if (bad.err) {
        std::println("{}", bad.err);   // EXCEPTION(ZeroDivisionError: division by zero)
    }
}

fn main() -> !void {
    var py = python::start();          // Python stops when py is deleted
    try run();
}
```

| | |
| --- | --- |
| `python::start()` | starts the interpreter (an `interpreter`: deleting it stops Python) |
| `python::import(name)` | a module |
| `python::eval(expr)`, `python::exec(code)` | an expression's value; statements run in `__main__` |
| `python::value(x)` | a Volt value as a Python object: integers, `f64`, `f32`, `bool`, `str`, `std::string` |
| `o.get(name)`, `o.item(key)` | `o.name`, `o[key]` |
| `o.call(args...)`, `o.call_method(name, args...)` | calls, each argument converted with `value` |
| `o.to_i64()`, `to_f64()`, `to_bool()`, `to_string()`, `repr()` | back to Volt |
| `o.is_none()` | whether it's `None` |

A `python::object` holds one reference: copying it adds one and deleting it drops it. Every call
that can fail returns `python_error!T`, and a Python exception becomes
`python_error::EXCEPTION("Type: message")`.

## Threads and the GIL

The thread that called `start()` holds Python's lock (the GIL). Another thread takes it with
`python::gil()`, which holds it until it's deleted, while the first lets go of it inside
`py.without_gil(f)`:

```volt ignore
var total: std::thread::atomic_i64 = {};
py.without_gil(|total&| () {
    var t = std::thread::spawn(|total&| () {
        val g = python::gil();
        val r = python::eval("sum(range(101))") catch return;
        total.store(r.to_i64() catch 0);
    }) catch return;
    t.join();
});
```

## Python calls Volt

A Volt library that lists `python` among its bindings gets a Python module from `bolt build`
(`target/debug/bindings/NAME.py`): one file over `ctypes`, with no C to compile. `pyi` adds its type
stubs.

The examples here use `greet`, the library every client in
[examples/interop/calls-volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt)
calls: `export fn add(a: i64, b: i64) -> i64`, `export fn hello(name: str) -> std::string`, and an
`export struct tally` with `tally_new`, `tally_add` and `tally_name`. What `export` means, and what
crosses as what, is in [They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt).

```toml
# bolt.toml of the Volt library
[lib]
kind = ["shared"]
bindings = ["python", "pyi"]
```

```python
import greet                        # bindings/greet.py

print("add", greet.add(2, 3))       # add 5
print(greet.hello("volt"))          # hello, volt: owned text comes back as a str
with greet.tally("clicks") as c:    # an export struct is a class; with (or close()) frees it
    c.add(1)
    print(c.name(), c.add(2))       # clicks 3
```

`bolt build` writes the library to `target/debug/libgreet.so` and the module to
`target/debug/bindings/greet.py`, so point Python at both:

```sh
bolt build
PYTHONPATH=target/debug/bindings VOLT_GREET_LIB=target/debug/libgreet.so python3 main.py
```

The module loads `libNAME.so` from `$VOLT_NAME_LIB` (the package's name in capitals), else from
next to itself. An error set becomes an exception class deriving from the module's `Error`, raised
with the error's name; slices are lists, optionals are the value or `None`, and a callback is any
callable.
