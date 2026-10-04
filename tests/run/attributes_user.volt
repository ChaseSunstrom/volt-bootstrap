// A library's own attributes are plain structs, written in @attributes next to the builtins (a
// struct's name called like a function fills its fields in order); @typeinfo gives them, for the
// type and for each field, as a tuple a comptime for looks through
use std::io;

namespace ser {
    struct rename {
        to: str;
    }

    struct skip {}

    struct table {
        name: str;
        version: i32 = 1;
    }
}

@attributes([ser::table("users"), @deprecated("use account")])
struct user {
    @attributes([ser::rename("user_id")])
    id: u32;
    name: str;
    @attributes([ser::skip()])
    password: str;
}

// a JSON writer that honours rename and skip
<T: type>
fn to_text(v: T&) -> std::string {
    var out = std::string::from("{");
    var first = true;
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                comptime var key = f.name;
                comptime var skipped = false;
                comptime for (a) in f.attributes {
                    comptime if (@typeof(a) == ser::rename) {
                        key = a.to;
                    } else comptime if (@typeof(a) == ser::skip) {
                        skipped = true;
                    }
                }
                comptime if (!skipped) {
                    if (!first) {
                        out.append(",");
                    }
                    first = false;
                    std::fmt::write(&out, "\"{}\":{}", key, @field(v, f.name).to_json().text());
                }
            }
        },
        default => {},
    }
    out.append("}");
    return move out;
}

<T: type>
fn table_of() -> str {
    comptime for (a) in @typeinfo(T).attributes {
        comptime if (@typeof(a) == ser::table) {
            std::println("version {}", a.version);
            return a.name;
        }
    }
    return "?";
}

struct plain {
    n: i32;
}

// a comptime value by name, on an enum, and a generic struct's field attributes
comptime val LEGACY: ser::table = { name: "old", version: 0 };

@attributes([LEGACY])
enum level {
    LOW,
    HIGH,
}

<T: type>
struct boxed {
    @attributes([ser::rename("v")])
    value: T;
}

fn main() -> void {
    val u: user = { id: 7, name: "ada", password: "-" };
    std::println("{}", to_text(&u));
    std::println("{} {}", table_of<user>(), table_of<plain>());
    std::println("{}", table_of<level>());
    val b: boxed<i32> = { value: 3 };
    std::println("{}", to_text(&b));
}
// expect: {"user_id":7,"name":"ada"}
// expect: version 1
// expect: users ?
// expect: version 0
// expect: old
// expect: {"v":3}
