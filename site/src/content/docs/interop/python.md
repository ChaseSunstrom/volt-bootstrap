---
title: Python
description: Calling Python from Volt with the interop/python package.
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
