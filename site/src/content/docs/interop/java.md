---
title: Java
description: Calling Java from Volt with the interop/java package, and Volt from Java through generated bindings.
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

## Java calls Volt

A Volt library that lists `java` among its bindings gets one Java class from `bolt build`
(`target/debug/bindings/NAME.java`), for Java 22 or later. It calls the library through the FFM API
(`java.lang.foreign`), so there is no JNI and no C to compile.

The examples here use `greet`, the library every client in
[examples/interop/calls-volt](https://github.com/ChaseSunstrom/volt-bootstrap/tree/main/examples/interop/calls-volt)
calls: `export fn add(a: i64, b: i64) -> i64`, `export fn hello(name: str) -> std::string`, and an
`export struct tally` with `tally_new`, `tally_add` and `tally_name`. What `export` means, and what
crosses as what, is in [They call Volt](/volt-bootstrap/interop/other-languages/#they-call-volt).

```toml
# bolt.toml of the Volt library
[lib]
kind = ["shared"]
bindings = ["java"]
```

```java
public class Main {
    public static void main(String[] args) {
        System.out.println("add " + greet.add(2, 3));    // add 5
        System.out.println(greet.hello("volt"));         // hello, volt
        try (var c = new greet.tally("clicks")) {        // AutoCloseable
            c.add(1);
            System.out.println(c.name() + " " + c.add(2));   // clicks 3
        }
    }
}
```

```sh
javac -d classes target/debug/bindings/greet.java Main.java
LD_LIBRARY_PATH=target/debug java --enable-native-access=ALL-UNNAMED -cp classes Main
```

The class loads `libNAME.so` (or the library `-Dvolt.NAME.lib` names). An error set becomes a
`VoltException` subclass, thrown with the error's name. Structs are mutable classes: what Volt
changes through a `T&` comes back to the object. Unsigned integers use the Java type of the same
size, as `int` for `u32`; slices are arrays, optionals the value or `null`, and a callback is a
functional interface. An export struct a program doesn't close is freed by a `Cleaner`.
