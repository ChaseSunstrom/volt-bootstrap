// std::derive: what @derive(...) attaches. Each derive is a trait with no functions, and its methods
// below are generic over the types that attach it: a comptime for over the type's fields, through
// @field. A derive of your own is written the same way: a trait, and methods bounded on it.
// (copy needs no derive: every struct copies field by field with `copy x`.)
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace derive {
    // eq(other: T&): every field equal (by its own eq); == and != on the type call it
    trait eq {}
    // hash(): the fields' hashes, combined (a map key)
    trait hash {}
    // to_string(): the text println prints for the value
    trait fmt {}
    // to_json(): a JSON object with a member each field
    trait json {}
}

<T: std::derive::eq>
attach fn eq(this: T&, other: T&) -> bool {
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                if (!@field(this, f.name).eq(&@field(other, f.name))) {
                    return false;
                }
            }
            return true;
        },
        .ENUM(e) => {
            comptime for (v) in e.1 {
                comptime if (v.payload != null) {
                    @compile_error("@derive(eq) on an enum with payloads isn't supported yet");
                }
            }
            return @cast<i64>(*this) == @cast<i64>(*other);
        },
        default => {
            @compile_error("@derive(eq) goes on a struct or an enum");
        },
    }
}

<T: std::derive::hash>
attach fn hash(this: T&) -> u64 {
    var h: u64 = 14695981039346656037;
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                h = (h ^ @field(this, f.name).hash()) *% 1099511628211;
            }
        },
        .ENUM(e) => {
            comptime for (v) in e.1 {
                comptime if (v.payload != null) {
                    @compile_error("@derive(hash) on an enum with payloads isn't supported yet");
                }
            }
            h = std::map_mix(@cast<u64>(@cast<i64>(*this)));
        },
        default => {
            @compile_error("@derive(hash) goes on a struct or an enum");
        },
    }
    return h;
}

// println already prints any struct field by field: this gives that text as a string
<T: std::derive::fmt>
attach fn to_string(this: T&) -> std::string {
    return std::fmt::format("{}", *this);
}

<T: std::derive::json>
attach fn to_json(this: T&) -> std::json::value {
    var o = std::json::object();
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                o.set(f.name, @field(this, f.name).to_json());
            }
        },
        .ENUM(e) => {
            // an enum without payloads: its variant's name
            comptime for (v) in e.1 {
                comptime if (v.payload != null) {
                    @compile_error("@derive(json) on an enum with payloads isn't supported yet");
                }
            }
            return std::json::string(std::fmt::format("{}", *this).as_str());
        },
        default => {
            @compile_error("@derive(json) goes on a struct or an enum");
        },
    }
    return o;
}

// what a field's to_json is for the types std knows: numbers, bool, text, optionals and vectors. One
// each number type (there's no trait for numbers); a JSON number is an f64, so an integer past 2^53
// loses its low bits
attach fn to_json(this: i8&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: i16&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: i32&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: i64&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: u8&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: u16&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: u32&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: u64&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: usize&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: f32&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
attach fn to_json(this: f64&) -> std::json::value { return std::json::number(*this); }
attach fn to_json(this: bool&) -> std::json::value { return std::json::boolean(*this); }
attach fn to_json(this: str&) -> std::json::value { return std::json::string(*this); }

<A: std::mem::allocator>
attach fn to_json(this: std::string<A>&) -> std::json::value {
    return std::json::string(this.as_str());
}

<T: type>
attach fn to_json(this: T?&) -> std::json::value {
    if (*this) {
        return this.value.to_json();
    }
    return std::json::null_value();
}

<T: type, A: std::mem::allocator>
attach fn to_json(this: std::vec<T, A>&) -> std::json::value {
    var out = std::json::array();
    for (x&) in this.items() {
        out.add(x.to_json());
    }
    return out;
}

// optionals and vectors as map keys (and fields of a derived hash)
<T: type>
attach fn hash(this: T?&) -> u64 {
    if (*this == null) {
        return 0;
    }
    return std::map_mix(this.value.hash() + 1);
}

<T: type, A: std::mem::allocator>
attach fn hash(this: std::vec<T, A>&) -> u64 {
    var h: u64 = 14695981039346656037;
    for (x&) in this.items() {
        h = (h ^ x.hash()) *% 1099511628211;
    }
    return h;
}
