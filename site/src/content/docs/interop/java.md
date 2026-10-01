---
title: Java
description: Calling Java from Volt with the interop/java package.
sidebar:
  order: 6
---

The `interop/java` package (in the repository) starts a Java VM inside a Volt program through JNI's
invocation API. Depend on it and call Java methods with Volt values; its build file finds the JDK at
`$JAVA_HOME` (or the one whose `java` is on the PATH) and links `libjvm` with an rpath to it.

```toml
# bolt.toml
[dependencies]
java = { path = "../volt/interop/java" }
```

```volt ignore
use std::io;

fn run(vm: java::vm&) -> java::java_error!void {
    val math = try vm.find_class("java/lang/Math");
    std::println("{}", try math.call_static_int("max", "(II)I", 3, 9));          // 9

    val counter = try vm.find_class("Counter");      // Counter.class on the class path
    val c = try counter.new_object("(Ljava/lang/String;I)V", "volt", 10);
    std::println("{}", try c.call_int("bump", "(I)I", 5));                       // 15
    std::println("{}", try c.to_string());                                       // volt=15

    val bad = counter.call_static_int("divide", "(II)I", 1, 0);
    if (bad.err) {
        std::println("{}", bad.err);   // THROWN(java.lang.ArithmeticException: / by zero)
    }
}

fn main() -> !void {
    var vm = try java::start("classes:lib/gson.jar");   // the JVM stops when vm is deleted
    try run(&vm);
}
```

Methods are found by name and their JNI signature: `(II)I` takes two `int`s and returns one,
`(Ljava/lang/String;)V` takes a `String` and returns nothing. `javap -s Counter` prints them.

| | |
| --- | --- |
| `java::start(classpath)` | starts the JVM (a `vm`: deleting it stops it); once per process |
| `vm.find_class(name)` | a class: `"java/util/ArrayList"`, `"Counter"`, `"com/example/Thing"` |
| `vm.string(s)` | a new `java.lang.String` |
| `cls.call_static_void`, `_int`, `_long`, `_double`, `_bool`, `_object`, `_string` | a static method: `(name, signature, args...)` |
| `o.call_void`, `call_int`, `call_long`, `call_double`, `call_bool`, `call_object` | an instance method, the same way |
| `cls.new_object(signature, args...)` | a new instance: the constructor's signature, like `"(I)V"` |
| `o.to_string()` | `toString()`'s text |
| `o.is_null()` | whether a returned object is `null` |

Arguments are integers (`i8`, `i16`, `i32`, `i64`), `f32`, `f64`, `bool`, `str` (a new Java
`String`) and `java::object`. An object argument is lent to the call; pass `copy o` to keep using
`o` afterwards. A `java::object` is a global reference: copying it adds one and deleting it drops
it. Every call that can fail returns `java_error!T`, and a Java exception becomes
`java_error::THROWN` with its `toString()`.

The `vm` belongs to the thread that started it: call Java from that thread.
