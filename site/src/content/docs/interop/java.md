---
title: Java
description: Calling Java classes from Volt by importing them like a header, and Volt from Java through generated bindings.
sidebar:
  order: 6
---

## Volt calls Java

Java sources, jars and class directories are imported like a header. Nothing in the Java code is
written for Volt, and there are no signatures, start calls or VM values in the Volt code: bolt
compiles the sources with `javac`, asks the JVM what the classes export, and writes Volt that calls
them through JNI. The JVM starts the first time Java is called.

```volt ignore
use std::io;
use { "geo/Point.java", "geo/Color.java" } as geo;    // or { "lib.jar" }, or use java { "classes" }

fn main() -> !void {
    var p = geo::Point::new(3.0, 4.0);               // a constructor (overloads stay overloads)
    p.scale(2.0);                                     // a method
    p.set_y(1.5);                                     // a public field: y() and set_y(v)
    std::println("{} {}", p.x(), p.toString());       // 6 (6.0, 1.5)
    val q = try geo::Point::parse("1, 2");            // it declares an exception: java_error!Point
    std::println("{}", geo::Color::GREEN.next().lower());   // an enum and its methods: blue
}
```

| Java | Volt |
| --- | --- |
| a public class, interface or abstract class | a handle: a reference to the object (a copy refers to the same one); `is_null()` for a `null` one |
| `new T(...)` | `T::new(...)`, one per public constructor |
| a public method | a method, or `T::f(...)` for a static one; overloads stay overloads |
| a public field | `x()` and, unless it's `final`, `set_x(v)`; `T::x()` for a static one |
| an imported supertype `S` | `as_S()`: the same object, as an `S` |
| an `enum` | a Volt enum with the same constants, and the enum's methods |
| `boolean`, `byte`, `char`, `short`, `int`, `long`, `float`, `double` | `bool`, `i8`, `u16`, `i16`, `i32`, `i64`, `f32`, `f64` |
| `String` | `str` in, `std::string` out (`null` is `""`) |
| arrays of those and of `String` | `T[..]` in (what Java changes in it comes back), `std::vec<T>` out |
| a method that declares exceptions (`throws`) | `java_error!T`; `java_error::THROWN` holds the exception's `toString()` |

An exception a method doesn't declare stops the program with its text, as a Volt panic does. A
method whose types aren't in the table (generic ones, collections, other libraries' classes) is
left out, listed in a comment of the generated declarations. Each import loads its classes through
a class loader of its own, so a program can import several, and they share the process's JVM.

bolt needs a JDK: `$JAVA_HOME`, else the one whose `javac` is on the PATH (for `javac` and its
`jni.h`). The program links its `libjvm` with an rpath to it.

## The interop/java package

The `interop/java` package (in the repository) starts a Java VM inside a Volt program through JNI's
invocation API, for calls made by hand. Depend on it and call Java methods with Volt values; its build file finds the JDK at
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
size, as `int` for `u32`; slices and lists (`std::vec`) are arrays, optionals the value or `null`,
and a callback is a functional interface. An export struct a program doesn't close is freed by a
`Cleaner`.

Java takes [every shape](/volt-bootstrap/interop/other-languages/#every-shape):
- **Owned values as parameters.** A `std::string` parameter takes a `String` (Volt copies it); an
  export struct by value takes its object, which gives its handle up (closing it after does
  nothing).
- **Traits.** A Volt trait is a Java interface: any object implementing it can be lent (`s:
  shape&`) or given (`s: shape`; Volt closes it when it's done, when it's `AutoCloseable`). A Volt
  value of the trait comes back as `volt_shape`, which implements the interface and is
  `AutoCloseable`.
- **Callbacks taking and giving text and handles.** A lambda gets `String`s and the objects (one
  Volt lends is never closed by Java) and gives them back; one for an `E!T` callback throws
  `VoltException.of(code)` to give that error.
- **Closures given back** are `AutoCloseable` objects with a `call` method.
- **Lists and arrays of text and handles.** A `std::vec<T>` comes back as an array (`String[]`, or
  the objects, which the caller closes); `String[]` and object arrays go in for `std::string[..]`,
  slices of handles and lists; an optional text or handle is the value or `null`.

For a library `shapes` with a trait `shape` (`area`, `name`, `grow`), `describe(s: shape&) ->
std::string`, `make_square(side: f64) -> shape` and `owners(xs: account&[..]) ->
std::vec<std::string>`:

```java
class Circle implements shapes.shape, AutoCloseable {
    double r = 1;
    public double area() { return 3 * r * r; }
    public String name() { return "circle"; }
    public void grow(double by) { r += by; }
    public void close() {}
}

System.out.println(shapes.describe(new Circle()));                 // circle of area 3
try (var sq = shapes.make_square(2)) {                             // Volt's own shape
    System.out.println(sq.name() + " " + sq.area());               // square 4.0
}
String[] names = shapes.owners(new shapes.account[] {a, b});       // a std::vec<std::string>
```
