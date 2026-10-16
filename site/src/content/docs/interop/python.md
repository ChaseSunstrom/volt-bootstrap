---
title: Python
description: Calling a Python module from Volt by importing it like a header, and Volt from Python through generated bindings.
sidebar:
  order: 4
---

## Volt calls Python

A Python module is imported like a header: a `.py` file, or a package's directory (one with an
`__init__.py`). Nothing in the Python is written for Volt, and the Volt code has no interpreter
handles or object juggling: bolt asks Python what the module exports, typed by its annotations,
and writes Volt that calls it through Python's C API. Python starts the first time it's called.

```volt ignore
use std::io;
use { "geom.py" } as geom;

fn main() -> void {
    var p = geom::Point::new(3.0, 4.0);          // a class (a dataclass here): Point(3.0, 4.0)
    p.scale(2.0);                                 // a method
    p.set_y(1.5);                                 // an attribute: y() and set_y(v)
    std::println("{} {}", p.x(), geom::upper("quiet"));             // 6 QUIET
    std::println("{} {}", geom::add(40), geom::greet("volt", true)); // defaults, keyword-only arguments
    val xs: i64[3] = { 5, 7, 9 };
    std::println("{}", geom::find(xs[..], 9) ?? -1);                 // int | None is i64?: 2
}
```

| Python | Volt |
| --- | --- |
| a function | `fn f(...)`; simple defaults stay defaults, keyword-only parameters are ordinary ones |
| a parameter with no annotation | its default's type (`n=1` is an `i64`), or with no default a type parameter: `show(3)`, `show("s")`, `show(&shape)` each convert as their type does (a type with no conversion is an error at the call) |
| `*args: T`, `**kwargs: T` | a trailing `T[..]`, and a trailing `std::map<std::string, T>&` passed as keyword arguments |
| a class | a handle: a reference to the object (a copy refers to the same one); `is_null()` for `None` |
| `__init__` | `T::new(...)` |
| methods, `@staticmethod`, `@classmethod` | methods, and `T::f(...)` |
| a property, an annotated attribute (a dataclass's fields) | `x()` and, unless it's read-only, `set_x(v)` |
| a base class `B` of the module | `as_B()`: the same object, as a `B` |
| an `Enum` | a Volt enum (its int values kept) |
| `int`, `float`, `bool` | `i64`, `f64`, `bool` |
| `str` | `str` in, `std::string` out |
| `bytes` | `u8[..]` in, `std::vec<u8>` out |
| `list[int]`, `list[float]`, `list[bool]`, `list[str]` | `T[..]` in (what Python changes in the list comes back, but for `str`), `std::vec<T>` out |
| `X \| None`, `Optional[X]` | `X?`; for a class, an empty handle is `None` |
| `dict[str, V]`, `dict[int, V]` (V a number, `bool` or `str`) | `std::map<K, V>&` in, `std::map<K, V>` out: copies |
| `tuple[int, str, float]` and the like | a Volt tuple `(i64, str, f64)` in, `(i64, std::string, f64)` out |
| `Callable[[int], int]` and the like (numbers, `bool`s, `str`s) | a Volt fn value (`\|\| (x: i64) -> i64 { ... }`), which Python may keep and call later; it's freed with the callable |
| no return annotation, `-> None` | `void` |
| an `UPPER_CASE` constant (a number, `bool` or string) | a `val` |

An exception stops the program with its type and message, as a Volt panic does (Python declares
none to make an error of). What the table doesn't cover — a dict of lists, a tuple of classes, a
callable taking a class — is left out, listed in a comment of the generated declarations
(`VOLT_SHOW_IMPORT=1 voltc check main.volt` prints them). Calls hold the GIL, so any thread can make them. bolt runs
`python3` (or `$PYTHON`) to read the module and `python3-config` (or `$PYTHON_CONFIG`) for
`Python.h` and the library; it needs Python 3.12 or later.

## The interop/python package

The `interop/python` package (in the repository) embeds the Python interpreter for calls made by
hand. Depend on it and
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
| `python::value(x)` | a Volt value as a Python object: integers, `f64`, `f32`, `bool`, `str`, `std::string`, and objects as they are |
| `o.get(name)`, `o.item(key)` | `o.name`, `o[key]` |
| `o.call(args...)`, `o.call_method(name, args...)` | calls, each argument converted with `value`; an object argument moves into the call, so pass `copy x` to keep `x` |
| `o.to_i64()`, `to_f64()`, `to_bool()`, `to_string()`, `repr()` | back to Volt |
| `o.is_none()`, `python::none()` | whether it's `None`; `None` |

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

`bolt build` writes the library to `target/debug/libgreet.so` (`libgreet.dylib` on macOS,
`greet.dll` on Windows) and the module to `target/debug/bindings/greet.py`, which finds the library
one directory up, so point Python at the module:

```sh
bolt build
PYTHONPATH=target/debug/bindings python3 main.py
```

The module loads the library from `$VOLT_NAME_LIB` (the package's name in capitals), else
`libNAME.so` (`libNAME.dylib`, `NAME.dll`) from next to itself or the directory above. An error set becomes an exception class deriving from the module's `Error`, raised
with the error's name (its `code` and `name` say which, and the class has the codes: for `error
math_error { NEGATIVE }`, `greet.math_error.NEGATIVE`). Structs are `ctypes` structures made from
their fields (`greet.vec2(1, 2)`), and what Volt changes in one it takes by reference comes back;
an enum is a class of its values; slices are lists, optionals are the value or `None`, and a
callback is any callable. A number by reference (`n: i32*`, `x: f64&`) takes a `ctypes` number,
`ctypes.c_int32(7)`, whose `value` gets what Volt writes (`None` is a null `i32*`). The module
takes [every shape](/volt-bootstrap/interop/other-languages/#every-shape):
owned text and objects go in (an object given to Volt is Python's no longer; a closed or lent one
is refused with `ValueError` before anything is given, and so is closing or giving away one that a
call that hasn't returned holds, as its callback might), a Volt trait is a class to subclass (any
object with its fns passes), a callback can take and give text and objects and raise an error
set's class for `E!T` (any other exception comes out of the call once Volt returns), a closure Volt
gives back is a callable (`close()` or a `with` block frees it, else the garbage collector), and a
`std::vec` comes back as a `list`.

A Python project can install a Volt library with `pip install`, which runs bolt: see
[pip install and npm install](/volt-bootstrap/interop/other-languages/#pip-install-and-npm-install).
