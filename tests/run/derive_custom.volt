// A derive of your own is a trait and methods bounded on it, the way std's are: @derive(name)
// attaches it, so the methods apply to that type and no other
use std::io;

namespace audit {
    trait fields {}
}

// "account: id owner"
<T: audit::fields>
attach fn field_names(this: T&) -> std::string {
    var out = std::string::from(@typeinfo(T).short_name);
    out.append(":");
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                std::fmt::write(&out, " {}", f.name);
            }
        },
        default => {},
    }
    return move out;
}

@attributes([@derive(audit::fields, eq)])
struct account {
    id: u32;
    owner: str;
}

struct plain {
    n: i32;
}

fn main() -> void {
    val a: account = { id: 7, owner: "ada" };
    val b: account = { id: 7, owner: "bob" };
    std::println("{} {}", a.field_names(), a == b);
    val p: plain = { n: 1 };
    std::println("{}", @has_method(account, "field_names") && !@has_method(plain, "field_names"));
}
// expect: account: id owner false
// expect: true
