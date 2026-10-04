// Generating code: quote { ... } is Volt source with $(...) splices, a comptime str; @emit(...)
// declares what it holds. Getters over any struct's fields, and a small DSL of named constants
use std::io;

struct point {
    x: i32;
    y: f64;
}

// get_x(), get_y(): one getter per field, of the field's type
comptime fn getters(T: type) -> str {
    var out = "";
    match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            for (f) in s.0 {
                out = quote {
                    $(out)
                    attach fn get_$(f.name)(this: $(T)&) -> $(f.field_type) {
                        return this.$(f.name);
                    }
                };
            }
        },
        default => {},
    }
    return out;
}

@emit(getters(point));

// a DSL: names and values become constants and a lookup
comptime fn codes(names: str[3], base: i32) -> str {
    var out = "";
    var lookup = "";
    for (i) in 0..3 {
        val v = base + i;
        out = quote {
            $(out)
            val $(names[i]): i32 = $v;
        };
        lookup = quote {
            $lookup
            if (n == $v) {
                return true;
            }
        };
    }
    return quote {
        namespace status {
            $out
            fn known(n: i32) -> bool {
                $lookup
                return false;
            }
        }
    };
}

@emit(codes({ "OK", "MOVED", "GONE" }, 200));

// an emitted @emit runs too; a bool splices as written
@emit(quote { @emit(quote { fn twice(n: i32) -> i32 { return n * 2; } }); });
@emit(quote { val CHECKED: bool = $(1 < 2); });

fn main() -> void {
    val p: point = { x: 3, y: 1.5 };
    std::println("{} {}", p.get_x(), p.get_y());
    std::println("{} {} {} {}", status::OK, status::GONE, status::known(201), status::known(203));
    std::println("{} {}", twice(21), CHECKED);
}
// expect: 3 1.5
// expect: 200 202 true false
// expect: 42 true
