// a built type's names have to be identifiers, once each, worked out from a str; struct { } is a
// value only at compile time

comptime fn spaced() -> type {
    return struct {
        ("not a name"): i32;
    };
}

comptime fn twice() -> type {
    return struct {
        comptime for (n) in 0..2 {
            ("x"): i32;
        }
    };
}

comptime fn numbered() -> type {
    return struct {
        (1 + 2): i32;
    };
}

fn uses_spaced() -> void {
    val a: spaced() = {};
}

fn uses_twice() -> void {
    val b: twice() = {};
}

fn uses_numbered() -> void {
    val c: numbered() = {};
}

comptime fn keyword() -> type {
    return struct {
        ("fn"): i32;
    };
}

comptime fn dup_variant() -> type {
    return enum {
        A,
        ("A"),
    };
}

comptime fn text_value() -> type {
    return enum {
        A = "a",
    };
}

comptime fn not_bool() -> type {
    return struct {
        comptime if (1) {
            x: i32;
        }
    };
}

comptime fn three() -> i32 {
    return 3;
}

comptime fn not_type() -> type {
    return struct {
        x: three();
    };
}

comptime fn wrap(T: type) -> type {
    return struct {
        v: T;
    };
}

fn uses_keyword() -> void {
    val a: keyword() = {};
}

fn uses_dup_variant() -> void {
    val b: dup_variant() = .A;
}

fn uses_text_value() -> void {
    val c: text_value() = .A;
}

fn uses_not_bool() -> void {
    val d: not_bool() = {};
}

fn uses_not_type() -> void {
    val e: not_type() = {};
}

// a built type is named after its call in errors
fn named_in_errors() -> void {
    val w: wrap(i32) = 5;
}

// at the top level, a type is named with type name = ...
val S = struct {
    x: i32;
};

fn runtime() -> i32 {
    val s = struct {
        x: i32;
    };
    return 0;
}

fn main() -> void {}
// error: 'not a name' isn't a name: a letter or _, then letters, digits and _
// error: 'x' is already a field of this struct
// error: a computed name is a str, found i32
// error: struct { } makes a type, a value only at compile time: return it from a comptime fn or name it with type name = struct { ... };
// error: 'fn' is a keyword, so it can't be a name
// error: 'A' is already a variant of this enum
// error: an enum value is a number
// error: comptime if needs a bool
// error: this doesn't give a type
// error: wrap(i32)
