// use a::b::c makes c's members reachable through the first namespace: std::println.
// the full path (std::io::println) keeps working. two imports giving the same name under std::
// merge into one overload set
use std::io;

// import C headers into a C namespace
use { "stdio.h", "string.h" } as c;
// use { "test.hpp", "test2.hpp" } as cpp; // C++ headers too (read with libclang; the self-hosted voltc, not the bootstrap one)

// c::some_fn();
// cpp::some_template<i32>(1);
//

// a tiny file type over the C import above (C pointers come in as raw pointers that may be null: FILE*)
namespace fs {
    error fs_error { NOT_FOUND }
    struct file { handle: c::FILE&; }
    fn open(path: cstr, mode: cstr) -> fs_error!file {
        val h = c::fopen(path, mode) ?? return fs_error::NOT_FOUND;
        return { handle: h };
    }
    attach fn close(this: file&) -> void { c::fclose(this.handle); }
}

/*
 * No runtime: no GC, no vtables, no RTTI (typeinfo is comptime only), no exceptions or unwinding,
 * no scheduler. Every call is resolved at compile time (direct and inlinable), except calls through
 * a fn(...) value, which are one plain C function pointer call
 *
 * Types:
 *    i8, i16, i32, i64, i128
 *    u8, u16, u32, u64, u128
 *        f16, f32, f64, f128
 *    bool
 *    isize, usize,
 *    void,  // no value
 *    never, // never returns (@panic, exit, infinite loop), coerces to any type
 *    type,  // the type of types, comptime only (generic anytype)
 *    str    // u8[..] UTF-8 slice (ptr + len), not null terminated
 *    cstr   // null terminated, for C. string literals are str but keep a hidden \0, so they also coerce to cstr
 *    void*  // opaque pointer (C's void*), may be null, has to be @cast before use
 *
 *    T[N]  // Array, fixed length N
 *    T[]   // Array, length inferred from the initializer: var a: i32[] = { 1, 2 }; // i32[2]
 *    T[..] // Slice (ptr + len), a view into an array
 *    T&    // Reference: never null, `.` reaches through it, can't be optional. Never owns: nothing is deleted through a T&
 *    T*    // Pointer: raw, may be null. p->x reaches through it, p + n / p - q / p[i] (unchecked) like C.
 *          // `if (p)` or `p ?? x` turns it into a T&. A T& converts to a T* by itself
 *    T?    // Optional
 *    box<T>   // owned heap pointer (std::mem::box), used like a T&. Deleted (and freed) automatically
 *    some_trait  // a trait used as a type: tagged union of every type that attaches it (see shape below)
 *    E!T   // Error union: an error from set E, or a T.  !T = error!T: an error from any set
 *    (T, ...) // tuple
 *    fn(T, ...) -> R          // function type, can hold a closure (fat: fn ptr + captures). each closure
 *                             // literal also has its own unique type, so generics can call it directly
 *    extern "C" fn(T) -> R    // thin C function pointer, for C callbacks (no captures)
 *    std::simd::f32x4         // SIMD vector (i32x8, ..., vec(T, n) for any other; over the comptime @vector(T, n)), math lane by lane
 *
 * Literals:
 *    1_000_000, 0xFF, 0b1010, 0o17, 1.5e3, 'a' (u8), "text" (str), r"raw" (no escapes), """ (multi-line), true, false, null
 *
 * Operators (the non-C ones):
 *    a ?? b      // value of optional a, or b if a is null. b can also be return/break/@panic(...)
 *    x as T      // safe conversion (widening, int -> float, bool/enum -> int, T& -> T*, T& -> void*), compile error otherwise
 *    a..b a..=b  // ranges, exclusive / inclusive
 *    arr[a..b]   // slicing, gives T[..] without copying. arr[..] = whole thing, arr[a..] / arr[..b] too
 *    &x, *p      // address of (gives T&), deref (a null T* panics in debug builds)
 *    p->x        // field or method through a pointer: (*p).x
 *    x++, x--    // statements only, not expressions (no C style i = i++ puzzles)
 *    +% -% *%    // wrapping arithmetic. plain + - * panic on overflow in debug builds, wrap in release
 *    x & 1 == 1  // & | ^ bind tighter than comparisons: (x & 1) == 1, unlike C
 *    a == b      // on a struct: its eq (attached or @derive(eq)). attach operator gives a struct or enum
 *                // + - * / % +% -% *% & | ^ << >> - ~ < == [] (see the guide's structs page)
 *
    // comptime-only typeinfo record, returned by @typeinfo(T). a sketch: typeinfo and the types below
    // have no names in code, but their fields read as shown (comptime val ti = @typeinfo(T); works,
    // a runtime val doesn't). payloads hold types, not typeinfos: @typeinfo(t) on one gives more.
    // kind is a tagged enum: per-kind data lives in its payload, instead of is_* flags
    // and nullable fields that all have to agree with each other
    comptime struct typeinfo {
        id: u128;               // the type's number in this build (@typeid(T) is the same in every build)

        // names
        canonical_name: str;    // e.g. "std::mem::box<i32, std::mem::default_allocator>"
        short_name: str;        // e.g. "box"
        module_path: str;       // e.g. "std::mem" ("" at the top level)

        // kind + everything specific to that kind (fields, variants, elem type, ...)
        kind: type_kind;
        fields: field_info[..];     // a struct's fields (as in kind's STRUCT), empty for other kinds
        variants: variant_info[..]; // an enum's or error set's variants (as in kind's), empty for other kinds

        // layout / ABI info (useful even at comptime)
        size: usize?;           // @sizeof(T) in bytes, null if it has no layout
        align: usize?;          // @alignof(T)
        stride: usize?;         // stride when used in arrays (its size)
        is_pod: bool;           // plain-old-data: nothing to delete
        borrows: bool;          // a value points into what it doesn't own (a reference or slice in it,
                                // a closure's capture by reference)
        is_comptime_only: bool; // true for type

        generic_args: type[..]; // an instance's generic args (a const arg is its value, a pack a tuple of types)

        // the fns attached to this type with a this (not static ones), inherent and trait ones, in
        // declaration order, any type's (i32's too). the hooks (delete, copy, eq, hash) are entries in here
        methods: method_info[..];

        attributes: (...);     // a library's attribute values, a tuple: (ser::rename("id"),). The builtins aren't listed
        visibility: visibility;  // PUBLIC for now
    }

    enum type_kind {
        VOID,
        NEVER,
        BOOL,
        TYPE,
        INT: (bool, u16),                       // signed, bits
        FLOAT: u16,                             // bits
        REFERENCE: type,                        // T&
        POINTER: type,                          // T*
        ARRAY: (type, usize),                   // T[N]
        VECTOR: (type, usize),                  // @vector(T, n): lane type, lanes
        SLICE: type,                            // T[..] (str is SLICE(u8))
        OPTIONAL: type,                         // T?
        ERROR_UNION: (type, type),              // E!T: E (error for !T), T
        ERROR_SET: variant_info[..],
        RANGE: type,                            // a..b, a..=b: the element type
        TUPLE: type[..],
        STRUCT: (field_info[..], struct_layout),
        ENUM: (type, variant_info[..]),         // tag type, variants
        FUNCTION: (type[..], type, bool, bool, str), // params, ret, varargs, is_async, calling convention:
                                                // false, false, "C" for now (fn(...) and extern "C" fn)
        CLOSURE: type[..],                      // its captures' types
        TRAIT_UNION: (str, type[..]),           // some_trait used as a type: its name, the types that attach it
        UNKNOWN,                                // the rest: cstr, void*, error, an async frame
    }

    enum struct_layout {
        C,      // every struct: declaration order, C padding rules (extern struct only marks one for C)
    }

    // helper sub-structures
    comptime struct field_info { // comptime struct: a compile-time-only record here (on a real struct voltc ignores comptime)
        name: str;
        field_type: type;        // size/align come from its typeinfo
        offset: usize?;          // offset in bytes
        default_expr: str?;      // null for now
        visibility: visibility;  // PUBLIC for now
        attributes: (...);       // a library's attribute values, a tuple (as on the type)
    }

    comptime struct variant_info {
        name: str;
        discriminant: i64?;      // its value: explicit, or the one before + 1 (an error's: its code in the program)
        payload: type?;          // payload type (a tuple for multi-value variants), null for unit variants
        attributes: (...)[..];   // empty for now
    }

    comptime struct method_info { // @field(v, m.name)(args) calls one
        name: str;
        trait: str;              // the trait it's attached for, "" when attached directly
        params: str[..];         // its parameters' names, after this
    }

    enum visibility {
        PUBLIC,
        INTERNAL // its package's own
    }

    // the builtin attributes @attributes([...]) takes. only these exist, so an unknown @name is a compile error.
    // @inline is attribute::INLINE, @opt(3) is attribute::OPT(3). a library's own attributes are plain
    // structs, written without @: @attributes([ser::rename("id")])
    enum attribute {
        INLINE,
        NOINLINE,
        UNCHECKED,        // no bounds checks in the fn's body
        INVALIDATES,      // a method that may move or free its receiver's storage
        OPT: u8,          // @opt(0..3)
        SECTION: str,     // @section(".text")
        ALIGN: usize,     // @align(16)
        DEPRECATED: str,  // @deprecated("use x instead")
        OWNS: str,        // @owns("ptr"): the struct owns what that field points at, like box
        THREAD_LOCAL,     // a global var each thread has its own copy of
        CFG: (str, str),  // @cfg("os", "linux") or @cfg("key"): only in builds where it holds
        DERIVE: (...),    // @derive(eq, hash, fmt, json): attach those traits
        OPTIONAL,         // a trait fn an attach block may leave out
        CLOSED,           // a trait whose attach blocks hold its fns only
        ATTACH_AS: str,   // @attach_as("trait"): the struct stands for that trait (a C++ class's virtuals)
        EXPORT_TEXT: str, // @export_text("method"): the struct is text to other languages
        INSTANCE: (...),  // @instance(i32): a generic export fn's instance to export
        STANDARD: str,    // @standard("c++17") on a use { "x.h" }
        CPP_TYPE: str, CPP_HANDLE: str, CPP_CALL: str, // what use cpp writes
        RUST_GENERIC: str,              // what use rust, use zig and use go write
        INTRINSIC: str, RUNTIME: str,   // std's and libraries' own files only
    }

 *
 *
 *
 * Keywords (never a name; the type names above aren't keywords: val i32 = 5; compiles):
 *    var, val, static, (val is immutable)
 *    // ownership: a value is deleted automatically when its owner leaves scope (reverse declaration order).
 *    // move hands ownership to someone else (no delete at the old place), copy makes a second owner.
 *    // heap memory is owned through box<T>, never through a plain T&
 *    public, internal, // visibility: a package's declarations are its own unless public; a program's files
 *                      // need no public (internal keeps one to the program). struct fields go with their
 *                      // struct (internal on one hides nothing yet), enum/error variants take neither
 *    attach, struct, enum, fn, error, trait,
 *    comptime, async, await, suspend, resume,
 *    extern, export,
 *    namespace, use, as, this, move, copy,
 *    if, else, for, in, while, loop, break, continue, return, match, default,
 *    try, catch, defer, errdefer,
 *    true, false, null
 *    // not reserved, only special where they start something: type (type x = T; an alias),
 *    // operator (attach operator +), test (test "name" { }), _ (a match arm, like default)
 */

// C varargs use ... (only allowed on extern "C" fns)
extern "C" fn printf(fmt: cstr, ...) -> i32;

// Volt varargs are variadic templates: Args is a pack of types, args the matching values.
// comptime params must be known at compile time (std::println, a compiler intrinsic, checks its format string then too)
namespace demo {
    <Args: type...>
    fn print_all(comptime sep: str, args: Args...) -> void {
        comptime for (arg) in args { // unrolled at compile time, arg has a different type each time
            std::print("{}{}", arg, sep);
        }
        std::println("");
    }
}

// export = C ABI + unmangled name, callable from C
export fn volt_add(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> !i32 { // !i32 so try/return e below can propagate errors (non-zero exit + message)

    var x = 0; // implicit i32

    val closure = |x&| () { // takes x by reference (|x| copies, |move x| moves)
         x++;
    };

    // full form: |captures| (params) -> ret { body }. type is fn(i32) -> i32
    val add_x: fn(i32) -> i32 = |x| (a: i32) -> i32 { return a + x; };

    val array: i32[] = 0..4; // exclusive range, length known at comptime -> i32[4]

    for (value, i) in array => value * 2 { // => expr gets ran at the start of each iteration, and replaces value

       closure();

       std::println(value);
       std::println(i); // half of value

      /* formatted:
       * std::println("Value: {}", value);
       * std::println("I: {}", i);
       */
    }

    val middle: i32[..] = array[1..3]; // slice, no copy
    val (first, second) = (middle[0], middle[1]); // tuple destructuring

    // we can also do this with errors
    var maybe_err: error!i32 = 0;
    if (maybe_err.err) {
        return 1;
    }

    // optionals
    var maybe: i32? = null;
    val or_zero = maybe ?? 0;
    maybe = 5;
    val or_leave = maybe ?? return 1; // right side can leave the scope

    // delete is automatic, so defer is for other cleanup (close, unlock, ...).
    // defer runs at scope exit (in reverse order), errdefer only if the scope exits with an error
    var null_dev: cstr = "/dev/null";
    comptime if (@cfg("os", "windows")) {
        null_dev = "NUL";
    }
    val file = try fs::open(null_dev, "w");
    defer file.close();
    errdefer std::println("main failed");

    val some_loop_assign =
        for (value, i) in array => value * 2 [ var result: i32 = 0 ]  // [ followed by var/val is the accumulator, not indexing. assigns some_loop_assign to result at the last iteration (needs a start value for 0 iterations)
    {

       closure();

      /* formatted:
       * std::println("Value: {}", value);
       * std::println("I: {}", i);
       */

       result += x;
    };

    // labels are ":name", on loops and blocks. break/continue take the label
    :outer for (i) in 0..100 {
        :inner for (j) in 0..=99  {
              if (j == 10) {
                  continue :outer;
              }
              if (i == 50) {
                  break :outer;
              }
        }
    }

    // break can carry a value, which makes loop and labeled blocks expressions
    val found = loop {
        if (x > 10) { break x; }
        x++;
    };
    val clamped = :blk {
        if (x > 100) { break :blk 100; }
        break :blk x;
    };

    while (true) { break; }

    loop { /* forever until break */ break; }

    var some_value = some_failing_func() catch |e| {
          return e; // block form has to leave the scope (return/break)
    };
    val or_default = some_failing_func() catch 0; // expression form: value to use on error

    var propagated = try some_failing_func(); // would propagate error
    var as_union = some_failing_func(); // as_union would become some_error!i32

    // ---- the rest of the tour, with output ----
    std::println("x {} found {} clamped {} sum {}", x, found, clamped, some_loop_assign);
    std::println("slice {} {} or_zero {} or_leave {}", first, second, or_zero, or_leave);
    std::println("apply {} {}", apply(add_x, 1), apply_any(add_x, 2));
    demo::print_all(", ", 1, "two", 3.5);
    shapes();
    std::println("{} {} {}", type_name(1.5), type_name(true), type_name(some_reg_enum::OTHER_VALUE));
    std::println("overloads {} {}", overload_test(1), overload_test(1, 2));
    std::println("{} {} {}", describe(.TUPLE_VALUE(2, 3)), describe_num(5), describe_num(50));
    std::println("pointers {}", pointer_array());
    std::println("async {}", async_caller());
    val sum: i32 = comp(); // two comptime comp()s differ only by return type: the i32 one runs
    std::println("comptime {} {} {}", sum, comp<1>(), sum_range(10));

    val e = try example::new(1, 2.5);
    std::println("example {} {} {}", e.member, e.member2, e.member3);
    val z: u8 = u8::new();                  // picks -> T
    val zb: std::mem::box<u8> = u8::new(); // picks -> box<T>
    std::println("new {} {}", z, zb);
    {
        val quiet: demo_alloc::noisy = {};
        val nb = try i32::new(42, quiet);   // box<i32, noisy>
        std::println("noisy box {}", nb);
    }                                       // freed here, through noisy
    some_generic_error() catch |err| {
        std::println("error {}", err);
    };
    as_union = 9;
    std::println("union {} value {}", as_union, try as_union);
    return 0;
}

fn some_failing_func() -> some_error!i32 {
    return 5;
}

// each closure has its own type, so this makes a copy per closure with a direct, inlinable call
<F: type>
fn apply(f: F, v: i32) -> i32 {
    return f(v);
}

// fn(...) types are for storing different fns/closures together, one C function pointer call each
fn apply_any(f: fn(i32) -> i32, v: i32) -> i32 {
    return f(v);
}

struct example {
    member: i32;
    member2: f64;
    member3: std::mem::box<u8>; // owned, so it's deleted with the example
} // 24 bytes (4 + 4 padding + 8 + 8). Every struct is laid out as C would: declaration order, C padding

extern struct c_example { // the same layout; extern only marks a struct that crosses into C
    member: i32;
    member2: f64;
}

// Methods are attached outside the struct. Here this has to name the type (preferred),
// inside an "attach trait -> type" block it can be left off (see demo_alloc below)
// "static this" only marks the fn as static (called as example::new(...)). this has no value
// inside it, so build the struct and return it
attach fn new(static this: example, member: i32, member2: f64) -> !example {
  return {
        member,
        member2,
        member3: try u8::new(3) // std's T::new(value): allocation can fail
  };
}

// this: example& so delete works on the original, not a copy.
// Called automatically when an example goes out of scope, never by hand.
// Runs first, then each member is deleted automatically (reverse field order)
attach fn delete(this: example&) -> void {
  // only needed for cleanup the members cant do themselves. member3 is deleted automatically after this
}

fn overload_test(x: i32) -> i32 {
    return x;
}

fn overload_test(x: i32, y: i32) -> i32 {
    return x + y;
}

async fn test_async() -> i32 {
    var sum: i32 = 0;
    var i: i32 = 0;
    while (i < 10) {
        sum = sum + i;
        i++;
    }
    return sum;  // Returns 45
}

async fn async_factorial(n: i32) -> i32 {
    if (n <= 1) {
        return 1;
    }
    var result: i32 = 1;
    var i: i32 = 2;
    while (i <= n) {
        result = result * i;
        i++;
    }
    return result;
}

async fn test_suspend_resume() -> i32 {
    var result: i32 = 0;

    // First computation phase
    result = 10;
    suspend;  // Yield control, preserve state

    // Resume here - state preserved
    result = result + 5;  // result is still 10
    suspend;

    // Resume again
    result = result * 2;  // result is now 30
    return result;
}

// frames are driven by hand (async/resume/await), no scheduler. a frame is a plain value with a size
// known at compile time, stored in the variable (no heap). an event loop can be a std library on top later
async fn async_caller() -> i32 {
    val a = await test_async();              // call and wait for the result

    val frame = async test_suspend_resume(); // start it without waiting, runs until its first suspend
    resume frame;                            // runs until the next suspend
    resume frame;                            // runs to the end
    return a + await frame;                  // 45 + 30
}

// Generics are templates, like C++: every distinct set of args makes its own copy of the fn/struct,
// and the body is only type checked when it gets instantiated. So a <T: type> body can use anything,
// and it compiles for every T that has it (duck typing):
<T: type>
fn total_area(a: T&, b: T&) -> f64 {
    return a.area() + b.area(); // fine for any T with an area fn, no trait needed
}

// Full specialization: <...> after the name says which args it covers. Used instead of the generic one
<T: type>
fn type_name(v: T) -> str { return @typeinfo(T).short_name; }

fn type_name<bool>(v: bool) -> str { return "a bool"; }

// Traits are constraints, like C++20 concepts (<T: allocator>).
// Gets ran when a generic uses it and requires all constraints to be true, or an error will occur (compile time).
// That gives a clear error at the call site, but doesnt limit what the body is allowed to use
trait allocator {
    // count = number of T's. std::mem::allocator (std/mem.volt) is this same trait
    <T: type> fn malloc(this, count: usize = 1) -> std::mem::mem_error!(T*);
    // the caller says how big the block is (old, count), so an allocator needn't remember
    <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> std::mem::mem_error!(T*);
    <T: type> fn free(this, ptr: T*, count: usize = 1) -> void;
}

// If we want to use the same type for this:
<T: type>
trait pool_allocator {
    fn malloc(this, count: usize = 1) -> std::mem::mem_error!(T*);
    fn realloc(this, ptr: T*, old: usize, count: usize) -> std::mem::mem_error!(T*);
    fn free(this, ptr: T*, count: usize = 1) -> void;
}
// attached as: <T: type> attach pool_allocator<T> -> some_pool<T> { ... }

// Traits as types, with no vtable: the compiler sees the whole program, so it knows every type that
// attaches shape. Using shape as a type makes a tagged union of all of them (circle | square here).
// A call is a switch on the tag, then a direct (inlinable) call. Values are stored inline, no heap.
trait shape {
    fn area(this) -> f64;
    fn name(this) -> str;
}

struct circle { r: f64; }
struct square { side: f64; }

attach shape -> circle {
    fn area(this) -> f64 { return 3.14159 * this.r * this.r; }
    fn name(this) -> str { return "circle"; }
}

attach shape -> square {
    fn area(this) -> f64 { return this.side * this.side; }
    fn name(this) -> str { return "square"; }
}

// one type at a time: use a generic, a copy per type, no tag at all
<T: shape>
fn print_shape(s: T&) -> void {
    std::println("{}: {}", s.name(), s.area());
}

fn shapes() -> void {
    val c: circle = { r: 1.0 };
    val q: square = { side: 3.0 };
    print_shape(&c);

    // mixed types: a flat array of shape, each element is the largest member + a tag
    val list: shape[] = { c, q }; // circle -> shape, square -> shape
    for (s&) in list { // (s&) binds by reference, like closure captures
        print_shape(s); // shape itself satisfies <T: shape>, the calls inside switch on the tag
    }

    match (list[0]) { // get the real type back
        circle(ci) => std::println("r = {}", ci.r),
        square(sq) => std::println("side = {}", sq.side),
    }
}

// Rules:
//  - size of shape = largest member + tag. One huge member makes every shape huge, so box that member
//  - generic trait fns work too (instantiated per member), only static this fns cant be called through it
//  - the member list is closed at compile time. fine for whole-program builds (one C program),
//    but a precompiled Volt library cant add members to it later

// std::mem (std/mem.volt) has the allocator trait, box<T, Allocator> and the blanket T::new(value).
// A custom allocator is any type that attaches std::mem::allocator:
namespace demo_alloc {
    use { "stdlib.h" } as libc;

    struct noisy; // empty struct: a box<T, noisy> is still just a pointer

    attach std::mem::allocator -> noisy {
        // inside an "attach trait -> type" block, this can leave off its type
        <T: type> fn malloc(this, count: usize = 1) -> std::mem::mem_error!(T*) {
            std::println("noisy: alloc {} bytes", count * @sizeof(T));
            val raw = libc::malloc(count * @sizeof(T)) ?? return std::mem::mem_error::OUT_OF_MEMORY; // C gives void*
            return @cast<T*>(raw); // @cast is unchecked (any -> any); "as" only does safe conversions
        }

        // the caller says how big the block was (old T's), so an allocator needn't remember
        <T: type> fn realloc(this, ptr: T*, old: usize, count: usize) -> std::mem::mem_error!(T*) {
            val raw = libc::realloc(ptr as void*, count * @sizeof(T)) ?? return std::mem::mem_error::OUT_OF_MEMORY;
            return @cast<T*>(raw);
        }

        <T: type> fn free(this, ptr: T*, count: usize = 1) -> void {
            std::println("noisy: free");
            libc::free(ptr as void*);
        }
    }
}

// u8::new(5): a box<u8> holding 5 (std's new)
// With a custom allocator:
// u8::new<my::allocator>(5)
// or by value, which infers Allocator: u8::new(5, my_alloc)
//
// u8::new<...> works by checking u8 for attached functions and implicitly passing it in as T (as it is the first one used),
// so <my::allocator> is the next one. An attached fn is only reached through a type or value: new<u8>(5) is an unknown name
// f<T>(...) is only parsed as a generic call when f names a generic, otherwise < is less-than
//

// Generics can also be inside of structs and enums:

<T: type, C: i32 = 0> // C will default to 0 if theres nothing passed into it
struct some_struct {
  member1: i32 = C; // Default values, allows non initialization of them during construction
  member2: T*; // implicitly defaults to null
  member3: T&;
}

fn some_fn() -> void {
    var n: i32 = 5;
    var s: some_struct<i32> = { member3: &n }; // member1 = C = 0, member2 = null
    // var s: some_struct<i32>; // default some_struct, will error because member3 cant be defaulted (its a reference)
}

<T: type>
struct holder {
    value: T;
}

// Partial specialization: used instead of the one above for every holder<T&>
<T: type>
struct holder<T&> {
    value: T*; // store references as pointers (nullable)
}

// attaching methods is similar to above, however they must be passed into this

<T: type, C: i32>
attach fn new(static this: some_struct<T, C>) -> some_struct<T, C> {}

// Enums are similar to rust enums
enum some_reg_enum: u8 { // optional backing type, default = smallest that fits
  VALUE,           // 0
  OTHER_VALUE = 5, // explicit discriminant
}

<T: type>
enum generic_enum {
    VALUE: T,
    SOME_OTHER: i32,
    TUPLE_VALUE: (i32, i32),
    NAMED_TUPLE_VALUE: (x: i32, y: i32),
    NO_VALUE
}

// match is an expression and must be exhaustive (or have default).
// .VARIANT is short for generic_enum<i32>::VARIANT when the type is known
fn describe(e: generic_enum<i32>) -> i32 {
    return match (e) {
        .VALUE(v) => v,
        .SOME_OTHER(n) if n > 10 => 10, // guard
        .SOME_OTHER(n) => n,
        .TUPLE_VALUE(a, b) => a + b,
        .NAMED_TUPLE_VALUE(x, y) => x * y,
        .NO_VALUE => 0,
    };
}

fn describe_num(n: i32) -> str {
    return match (n) {
        0 => "zero",
        1..=9 => "small", // range patterns
        default => "big",
    };
}

// Error enum:
error some_error {
    BLAH,
    BLAHBLAH
}

<T: type>
error some_error2 {
    STRING_MSG: cstr,
    ERROR_TYPE: T
}

// Error function:
fn some_error_thrower() -> some_error!void {
    if (true) { // This will get evaluated at comptime, as its a constexpr. conditions must be bool (an optional or a pointer is a null check)
       return some_error::BLAH;
    } else {
       return;
    }
}

fn some_generic_error() -> some_error2<cstr>!void {
    if (true) {
        return some_error2::STRING_MSG("HI");
    } else {
        // return error; // compile error: a bare error only fits the any-error type (error!T, like main's maybe_err)
        return some_error2::ERROR_TYPE("other");
    }
}

fn pointer_array() -> i32 {
    var arr: i32[] = { 5, 10, 15, 20 }; // Array initialization
    var p0: i32& = &(arr[0]);
    var p1: i32& = &(arr[1]);
    var p2: i32& = &(arr[2]);

    return *p0 + *p1 + *p2;  // 5 + 10 + 15 = 30
}

<T: type>
attach fn new(static this: generic_enum<T>) -> void {} // Redundant new


<T: type>
attach fn new(static this: T) -> T { // Attaches this function to every type, T::new(): a zero value
    var v: T;
    return v;
}

<T: type>
attach fn new(static this: T) -> std::mem::box<T> { // overload on return type, requires a context or its ambigious
    return T::new(T::new()) catch @panic("out of memory"); // the inner T::new() gives a T: std's new(value: T) says so
}
// val a: u8 = u8::new();   // picks -> T
// val b: box<u8> = u8::new(); // picks -> box<T>
// val c = u8::new();       // error: ambiguous, add a type


<T: type, U: type>
attach fn new(static this: T) -> void {} // Overloaded generic function. U cant be inferred, so it must be given: T::new<U>()

comptime fn comp() -> type {
    return i32; // type literal can be returned, which allows us to use it in a generic definition:
    /*
        <T: comp()>
        fn some_generic_fn() -> T {}
    */
}

comptime fn comp() -> i32 { // everything in here runs at comptime
    var result = 0; // implicit i32
    for (i) in 0..100 {
        result += i;
    }
    return result;
}

<C: i32>
fn comp() -> i32 {
    // runs at comptime
    comptime var determined_type: type;
    comptime if (C > 0) {
        determined_type = i32;
    } else {
        determined_type = i8;
    } // an instance that leaves it unassigned is an error where it's used
    // a better option would be to match:
    comptime match (C) {
        c if c > 0 => determined_type = i32,
        default => { determined_type = i8; }, // match also allows block syntax
    }

    var result: determined_type = 0;
    for (i) in 0..100 {
        result += i; // NOTE: overflows when determined_type is i8 (sum is 4950): panics in debug, wraps in release. use +%= to wrap on purpose
    }
    return result;
}

// params are immutable (val) by default, "var" makes a mutable copy
fn optional(var some_op: i32?) -> void {
    if (some_op) { // same as !some_op.none. always a presence check, even for a bool? holding false
        some_op += 1; // no need to do some_op.value (as we know it has one from the above if)
    } else {

    }
}

internal fn some_internal() -> void { } // only this program's files can name it (a package's fns are its own unless public)

@attributes([@inline, @opt(3), @section(".text")]) // @ attributes are builtins (see enum attribute), so typos are compile errors
public comptime fn sum_range(n: i32) -> i32 {
    var sum: i32 = 0;
    var i: i32 = 0;
    while (i < n) {
        sum = sum + i;
        i++;
    }
    return sum;
}


// Enum values are accessed like:
// var value = generic_enum::NO_VALUE;
// var some_other = generic_enum::SOME_OTHER(1);
// var generic = generic_enum<f32>::VALUE(1.23);
// var tuple = generic_enum::TUPLE_VALUE(1, 2);

// Builtins:
/*
@typeinfo(T) -> typeinfo
@typeof(expr) -> type
@typeid(T) -> u64           // the same in every build; for a trait value, the id of the type it holds
@cast<new_type>(variable)   // unchecked, any -> any. prefer "as"
@bitcast<T>(x) -> T         // the same bits as another type of the same size
@sizeof(T) -> usize
@alignof(T) -> usize
@offsetof(T, field) -> usize
@field(v, "name"), @has_field(T, "name"), @has_method(T, "name"), @attaches(T, trait) // comptime reflection
@discriminant(v) -> i64     // which variant an enum value holds
@vector(T, n) -> type       // SIMD vector type
@embed("path") -> str       // a file's bytes, read at compile time
@expand(expr)               // expr, noting at compile time what it became
@cfg("key", "value") -> bool // --cfg settings and the target (os, arch, ...)
@slice(ptr, len), @read(ptr), @write(ptr, v), @volatile_read(ptr), @volatile_write(ptr, v) // raw memory
@cpp<R>("expr", args...)    // call C++ code, in a file that imports C++ headers
@compile_error(msg)         // fail compilation, for custom generic constraint errors
@panic(msg) -> never
@inline, @opt(n), ...        // attributes, only valid inside @attributes([...]). full list: enum attribute
*/

// the tour's output (checked by tests/golden.rs)
// expect: 0
// expect: 0
// expect: 2
// expect: 1
// expect: 4
// expect: 2
// expect: 6
// expect: 3
// expect: x 11 found 11 clamped 11 sum 26
// expect: slice 1 2 or_zero 0 or_leave 5
// expect: apply 1 2
// expect: 1, two, 3.5, 
// expect: circle: 3.14159
// expect: circle: 3.14159
// expect: square: 9
// expect: r = 1
// expect: f64 a bool some_reg_enum
// expect: overloads 1 3
// expect: 5 small big
// expect: pointers 30
// expect: async 75
// expect: comptime 4950 4950 45
// expect: example 1 2.5 3
// expect: new 0 0
// expect: noisy: alloc 4 bytes
// expect: noisy box 42
// expect: noisy: free
// expect: error STRING_MSG(HI)
// expect: union 9 value 9
