// std::derive: what @derive(...) attaches. Each derive is a trait with no functions, and its methods
// below are generic over the types that attach it: a comptime for over the type's fields, through
// @field. A derive of your own is written the same way: a trait, and methods bounded on it.
// (copy needs no derive: every struct copies field by field with `copy x`.)
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace derive {
    // eq(other: T&): every field equal (by its own eq); == and != on the type call it
    public trait eq {}
    // hash(): the fields' hashes, combined (a map key)
    public trait hash {}
    // to_string(): the text println prints for the value
    public trait fmt {}
    // to_json(): a JSON object with a member each field
    public trait json {}

    // a variant's payload compared, hashed or made JSON: a tuple's element by element (a tuple has
    // none of these of its own)
    <P: type>
    public fn payload_eq(a: P&, b: P&) -> bool {
        comptime match (@typeinfo(P).kind) {
            .TUPLE(ts) => {
                comptime for (t, i) in ts {
                    if (!@field(a, i).eq(&@field(b, i))) {
                        return false;
                    }
                }
                return true;
            },
            default => {
                return a.eq(b);
            },
        }
    }

    <P: type>
    public fn payload_hash(a: P&) -> u64 {
        comptime match (@typeinfo(P).kind) {
            .TUPLE(ts) => {
                var h: u64 = 14695981039346656037;
                comptime for (t, i) in ts {
                    h = (h ^ @field(a, i).hash()) *% 1099511628211;
                }
                return h;
            },
            default => {
                return a.hash();
            },
        }
    }

    <P: type>
    public fn payload_json(a: P&) -> std::json::value {
        comptime match (@typeinfo(P).kind) {
            .TUPLE(ts) => {
                var out = std::json::array();
                comptime for (t, i) in ts {
                    out.add(@field(a, i).to_json());
                }
                return out;
            },
            default => {
                return a.to_json();
            },
        }
    }

    // ---------- from_json's parts ----------

    // e with step (.name or [i]) in front of its path: from_json adds the path on the way out, so a
    // value that fits costs nothing for it
    public fn within(e: std::json::decode_error, step: str) -> std::json::decode_error {
        match (e) {
            .INVALID(m&) => {
                val s = m.as_str();
                if (s.len > 0 && (s[0] == '.' || s[0] == '[')) {
                    return std::json::decode_error::INVALID(std::fmt::format("{}{}", step, s));
                }
                return std::json::decode_error::INVALID(std::fmt::format("{}: {}", step, s));
            },
        }
    }

    // "expected what, got ...": the value itself when it's short (a number, true, null, a short
    // string), its kind when it isn't
    <A: std::mem::allocator>
    public fn mismatch(what: str, v: std::json::value<A>&) -> std::json::decode_error {
        match (*v) {
            .STR(s&) => {
                if (s.len() > 40) {
                    return std::json::decode_error::INVALID(std::fmt::format("expected {}, got a string", what));
                }
                return std::json::decode_error::INVALID(std::fmt::format("expected {}, got \"{}\"", what, s.as_str()));
            },
            .ARR(xs&) => { return std::json::decode_error::INVALID(std::fmt::format("expected {}, got an array", what)); },
            .OBJ(ms&) => { return std::json::decode_error::INVALID(std::fmt::format("expected {}, got an object", what)); },
            default => { return std::json::decode_error::INVALID(std::fmt::format("expected {}, got {}", what, v.text().as_str())); },
        }
    }

    // text from the input for an error message: at most 40 bytes, control characters as ?
    public fn brief(s: str) -> std::string {
        var out: std::string = {};
        for (i) in 0..s.len {
            if (i == 40) {
                out.append("...");
                break;
            }
            val c = s[i];
            if (c < 32 || c == 127) {
                out.push('?');
            } else {
                out.push(c);
            }
        }
        return out;
    }

    // an integer of type T: a whole number in T's range
    <T: type, A: std::mem::allocator>
    public fn whole(v: std::json::value<A>&, what: str) -> std::json::decode_error!T {
        val x = v.as_num() ?? return std::derive::mismatch(what, v);
        var lo: f64 = 0.0;
        var hi: f64 = 1.0; // 2^bits, or 2^(bits-1) signed: the first number past T's range
        comptime match (@typeinfo(T).kind) {
            .INT(k) => {
                for (i) in 0..k.1 {
                    hi *= 2.0;
                }
                if (k.0) {
                    hi /= 2.0;
                    lo = -hi;
                }
                // a 64-bit type's largest values print as the f64 nearest them, 2^63 (2^64 unsigned),
                // which reads back as the largest
                comptime if (k.1 == 64) {
                    if (x == hi) {
                        comptime if (k.0) {
                            return 9223372036854775807;
                        } else {
                            return 18446744073709551615;
                        }
                    }
                }
            },
            default => { @compile_error("std::derive::whole is for integer types"); },
        }
        // (past 2^53 every f64 is whole; NaN fails the range test)
        if (!(x >= lo && x < hi) || (x > -9007199254740992.0 && x < 9007199254740992.0 && @cast<f64>(@cast<i64>(x)) != x)) {
            return std::derive::mismatch(what, v);
        }
        return @cast<T>(x);
    }

    // a struct's field read from v's member called name; one that isn't there is only fine for a
    // type that takes null (an optional): from_json gives a field with a default its default first
    <F: type, A: std::mem::allocator>
    public fn member(v: std::json::value<A>&, name: str) -> std::json::decode_error!F {
        return F::from_json(v.get(name)) catch |e| {
            if (!v.has(name)) {
                return std::json::decode_error::INVALID(std::fmt::format(".{}: missing", name));
            }
            return std::derive::within(e, std::fmt::format(".{}", name).as_str());
        };
    }

    // a variant's payload read back: a tuple's from an array of its elements
    <P: type, A: std::mem::allocator>
    public fn payload_from_json(v: std::json::value<A>&) -> std::json::decode_error!P {
        comptime match (@typeinfo(P).kind) {
            .TUPLE(ts) => {
                match (*v) {
                    .ARR(xs&) => {
                        if (xs.len != ts.len) {
                            return std::json::decode_error::INVALID(std::fmt::format("expected {} elements, got {}", ts.len, xs.len));
                        }
                    },
                    default => { return std::derive::mismatch("an array", v); },
                }
                var mem: std::mem::default_allocator = {};
                val p: P* = mem.malloc<P>() catch @panic("out of memory");
                var made: usize = 0;
                errdefer std::derive::unmake<P>(p, made);
                comptime for (t, i) in ts {
                    val x = std::derive::payload_from_json<t, A>(v.at(i)) catch |e| {
                        return std::derive::within(e, std::fmt::format("[{}]", i).as_str());
                    };
                    @write(&@field(*p, i), x);
                    made += 1;
                }
                val out = @read(p);
                mem.free(p);
                return out;
            },
            default => {
                return P::from_json(v);
            },
        }
    }

    // a value from_json was making in raw memory deleted: its first made fields, then the memory
    <T: type>
    public fn unmake(p: T*, made: usize) -> void {
        comptime match (@typeinfo(T).kind) {
            .TUPLE(ts) => {
                comptime for (t, i) in ts {
                    if (i < made) {
                        val dropped = @read(&@field(*p, i)); // deleted here
                    }
                }
            },
            default => {
                comptime for (f, i) in @typeinfo(T).fields {
                    if (i < made) {
                        val dropped = @read(&@field(*p, f.name)); // deleted here
                    }
                }
            },
        }
        var mem: std::mem::default_allocator = {};
        mem.free(p);
    }
}

<T: std::derive::eq>
public attach fn eq(this: T&, other: T&) -> bool {
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
            // the same variant, and the same payload
            if (@discriminant(this) != @discriminant(other)) {
                return false;
            }
            comptime for (v) in e.1 {
                comptime if (v.payload != null) {
                    if (@discriminant(this) == v.discriminant.value) {
                        return std::derive::payload_eq(&@field(this, v.name), &@field(other, v.name));
                    }
                }
            }
            return true;
        },
        default => {
            @compile_error("@derive(eq) goes on a struct or an enum");
        },
    }
}

<T: std::derive::hash>
public attach fn hash(this: T&) -> u64 {
    var h: u64 = 14695981039346656037;
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                h = (h ^ @field(this, f.name).hash()) *% 1099511628211;
            }
        },
        .ENUM(e) => {
            h = std::map_mix(@cast<u64>(@discriminant(this)));
            comptime for (v) in e.1 {
                comptime if (v.payload != null) {
                    if (@discriminant(this) == v.discriminant.value) {
                        h = (h ^ std::derive::payload_hash(&@field(this, v.name))) *% 1099511628211;
                    }
                }
            }
        },
        default => {
            @compile_error("@derive(hash) goes on a struct or an enum");
        },
    }
    return h;
}

// println already prints any struct field by field: this gives that text as a string
<T: std::derive::fmt>
public attach fn to_string(this: T&) -> std::string {
    return std::fmt::format("{}", *this);
}

<T: std::derive::json>
public attach fn to_json(this: T&) -> std::json::value {
    var o = std::json::object();
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            comptime for (f) in s.0 {
                o.set(f.name, @field(this, f.name).to_json());
            }
        },
        .ENUM(e) => {
            // a variant with a payload: an object with one member, the variant's name; one without:
            // its name
            comptime for (v) in e.1 {
                comptime if (v.payload != null) {
                    if (@discriminant(this) == v.discriminant.value) {
                        o.set(v.name, std::derive::payload_json(&@field(this, v.name)));
                        return o;
                    }
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

// T::from_json(v): what to_json made, read back. A struct's fields come from the members of the
// same names (others are ignored); a member that isn't there leaves its field's default, or null
// for an optional. An enum is its variant's name, or {"NAME": payload}. A value that doesn't fit
// fails with decode_error::INVALID, saying where: .items[2].name: expected a string, got 5
<T: std::derive::json, A: std::mem::allocator>
public attach fn from_json(static this: T, v: std::json::value<A>&) -> std::json::decode_error!T {
    comptime match (@typeinfo(T).kind) {
        .STRUCT(s) => {
            match (*v) {
                .OBJ(ms&) => {},
                default => { return std::derive::mismatch("an object", v); },
            }
            // made in place, field by field (a literal would need every field at once); on an
            // error the fields made so far are deleted
            var mem: std::mem::default_allocator = {};
            val p: T* = mem.malloc<T>() catch @panic("out of memory");
            var made: usize = 0;
            errdefer std::derive::unmake<T>(p, made);
            comptime for (f) in s.0 {
                comptime if (f.default_expr != null) {
                    if (v.has(f.name)) {
                        @write(&@field(*p, f.name), try std::derive::member<f.field_type, A>(v, f.name));
                    } else {
                        @write(&@field(*p, f.name), @field_default(T, f.name));
                    }
                } else {
                    @write(&@field(*p, f.name), try std::derive::member<f.field_type, A>(v, f.name));
                }
                made += 1;
            }
            val out = @read(p);
            mem.free(p);
            return out;
        },
        .ENUM(e) => {
            match (*v) {
                .STR(name&) => {
                    comptime for (x) in e.1 {
                        if (name.as_str() == x.name) {
                            comptime if (x.payload == null) {
                                return @field(T, x.name);
                            } else {
                                return std::json::decode_error::INVALID(std::fmt::format("{} takes a payload: {{\"{}\": ...}}", x.name, x.name));
                            }
                        }
                    }
                    return std::json::decode_error::INVALID(std::fmt::format("{} has no variant {}", @typeinfo(T).short_name, std::derive::brief(name.as_str()).as_str()));
                },
                .OBJ(ms&) => {
                    if (ms.len == 1) {
                        val name = ms[0].name.as_str();
                        comptime for (x) in e.1 {
                            if (name == x.name) {
                                comptime if (x.payload == null) {
                                    return std::json::decode_error::INVALID(std::fmt::format("{} takes no payload: \"{}\"", x.name, x.name));
                                } else {
                                    val p = std::derive::payload_from_json<x.payload.value, A>(&ms[0].item) catch |err| {
                                        return std::derive::within(err, std::fmt::format(".{}", x.name).as_str());
                                    };
                                    return @field(T, x.name)(p);
                                }
                            }
                        }
                        return std::json::decode_error::INVALID(std::fmt::format("{} has no variant {}", @typeinfo(T).short_name, std::derive::brief(name).as_str()));
                    }
                },
                default => {},
            }
            return std::derive::mismatch(std::fmt::format("a variant of {}", @typeinfo(T).short_name).as_str(), v);
        },
        default => {
            @compile_error("@derive(json) goes on a struct or an enum");
        },
    }
}

// what a field's to_json is for the types std knows: numbers, bool, text, optionals and vectors. One
// each number type (there's no trait for numbers); a JSON number is an f64, so an integer past 2^53
// loses its low bits
public attach fn to_json(this: i8&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: i16&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: i32&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: i64&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: u8&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: u16&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: u32&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: u64&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: usize&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: f32&) -> std::json::value { return std::json::number(@cast<f64>(*this)); }
public attach fn to_json(this: f64&) -> std::json::value { return std::json::number(*this); }
public attach fn to_json(this: bool&) -> std::json::value { return std::json::boolean(*this); }
public attach fn to_json(this: str&) -> std::json::value { return std::json::string(*this); }

<A: std::mem::allocator>
public attach fn to_json(this: std::string<A>&) -> std::json::value {
    return std::json::string(this.as_str());
}

<T: type>
public attach fn to_json(this: T?&) -> std::json::value {
    if (*this) {
        return this.value.to_json();
    }
    return std::json::null_value();
}

<T: type, A: std::mem::allocator>
public attach fn to_json(this: std::vec<T, A>&) -> std::json::value {
    var out = std::json::array();
    for (x&) in this.items() {
        out.add(x.to_json());
    }
    return out;
}

// what from_json reads for the types std knows: numbers (an integer whole and in its range), bool,
// text, optionals (null, or a member that isn't there) and vectors (an array)
<A: std::mem::allocator>
public attach fn from_json(static this: i8, v: std::json::value<A>&) -> std::json::decode_error!i8 { return std::derive::whole<i8, A>(v, "an i8"); }
<A: std::mem::allocator>
public attach fn from_json(static this: i16, v: std::json::value<A>&) -> std::json::decode_error!i16 { return std::derive::whole<i16, A>(v, "an i16"); }
<A: std::mem::allocator>
public attach fn from_json(static this: i32, v: std::json::value<A>&) -> std::json::decode_error!i32 { return std::derive::whole<i32, A>(v, "an i32"); }
<A: std::mem::allocator>
public attach fn from_json(static this: i64, v: std::json::value<A>&) -> std::json::decode_error!i64 { return std::derive::whole<i64, A>(v, "an i64"); }
<A: std::mem::allocator>
public attach fn from_json(static this: u8, v: std::json::value<A>&) -> std::json::decode_error!u8 { return std::derive::whole<u8, A>(v, "a u8"); }
<A: std::mem::allocator>
public attach fn from_json(static this: u16, v: std::json::value<A>&) -> std::json::decode_error!u16 { return std::derive::whole<u16, A>(v, "a u16"); }
<A: std::mem::allocator>
public attach fn from_json(static this: u32, v: std::json::value<A>&) -> std::json::decode_error!u32 { return std::derive::whole<u32, A>(v, "a u32"); }
<A: std::mem::allocator>
public attach fn from_json(static this: u64, v: std::json::value<A>&) -> std::json::decode_error!u64 { return std::derive::whole<u64, A>(v, "a u64"); }
<A: std::mem::allocator>
public attach fn from_json(static this: usize, v: std::json::value<A>&) -> std::json::decode_error!usize { return std::derive::whole<usize, A>(v, "a usize"); }

<A: std::mem::allocator>
public attach fn from_json(static this: f32, v: std::json::value<A>&) -> std::json::decode_error!f32 {
    val x = v.as_num() ?? return std::derive::mismatch("an f32", v);
    if (x >= 3.4028235677973366e38 || x <= -3.4028235677973366e38) {
        return std::derive::mismatch("an f32", v);
    }
    return @cast<f32>(x);
}

<A: std::mem::allocator>
public attach fn from_json(static this: f64, v: std::json::value<A>&) -> std::json::decode_error!f64 {
    return v.as_num() ?? return std::derive::mismatch("a number", v);
}

<A: std::mem::allocator>
public attach fn from_json(static this: bool, v: std::json::value<A>&) -> std::json::decode_error!bool {
    return v.as_bool() ?? return std::derive::mismatch("true or false", v);
}

<B: std::mem::allocator, A: std::mem::allocator>
public attach fn from_json(static this: std::string<B>, v: std::json::value<A>&) -> std::json::decode_error!std::string<B> {
    val s = v.as_str() ?? return std::derive::mismatch("a string", v);
    var b: B = {};
    return std::string::from(s, move b);
}

// (a str would point into the value, which may not outlive it)
<A: std::mem::allocator>
public attach fn from_json(static this: str, v: std::json::value<A>&) -> std::json::decode_error!str {
    @compile_error("from_json can't read a str: it would point into the JSON value; make it a std::string");
}

<T: type, A: std::mem::allocator>
public attach fn from_json(static this: T?, v: std::json::value<A>&) -> std::json::decode_error!(T?) {
    if (v.is_null()) {
        return null;
    }
    return try T::from_json(v);
}

<T: type, B: std::mem::allocator, A: std::mem::allocator>
public attach fn from_json(static this: std::vec<T, B>, v: std::json::value<A>&) -> std::json::decode_error!std::vec<T, B> {
    var out: std::vec<T, B> = {};
    match (*v) {
        .ARR(xs&) => {
            for (i) in 0..xs.len {
                val x = T::from_json(&xs[i]) catch |e| {
                    return std::derive::within(e, std::fmt::format("[{}]", i).as_str());
                };
                out.push(x);
            }
        },
        default => { return std::derive::mismatch("an array", v); },
    }
    return out;
}

// optionals and vectors as map keys (and fields of a derived hash)
<T: type>
public attach fn hash(this: T?&) -> u64 {
    if (*this == null) {
        return 0;
    }
    return std::map_mix(this.value.hash() + 1);
}

<T: type, A: std::mem::allocator>
public attach fn hash(this: std::vec<T, A>&) -> u64 {
    var h: u64 = 14695981039346656037;
    for (x&) in this.items() {
        h = (h ^ x.hash()) *% 1099511628211;
    }
    return h;
}
