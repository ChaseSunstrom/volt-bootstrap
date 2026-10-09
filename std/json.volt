// std::json: JSON values, read from text (parse) and written back (text).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace json {
    // a JSON value; an object keeps its members in order. Its strings and arrays come from A
    <A: std::mem::allocator = std::mem::default_allocator>
    public enum value {
        NULL,                       // null
        BOOL: bool,                 // true or false
        NUM: f64,                   // a number (JSON has one kind)
        STR: std::string<A>,        // a string, unescaped
        ARR: std::vec<value<A>, A>, // an array
        OBJ: std::vec<member<A>, A>, // an object: its members in order
    }

    // one member of an object
    <A: std::mem::allocator = std::mem::default_allocator>
    public struct member {
        name: std::string<A>; // the key
        item: value<A>;       // its value
    }

    // why parse failed
    public error json_error {
        SYNTAX, // the text isn't JSON
    }


    // ---------- reading ----------

    // the text parsed; whitespace around the value is fine, anything else after it isn't
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn parse(text: str, allocator: A = {}) -> json_error!value<A> {
        var at: usize = 0;
        val v = try parse_value(text, &at, 0, &allocator);
        skip_space(text, &at);
        if (at != text.len) {
            return json_error::SYNTAX;
        }
        return v;
    }

    fn skip_space(t: str, at: usize&) -> void {
        while (*at < t.len && (t[*at] == ' ' || t[*at] == '\t' || t[*at] == '\n' || t[*at] == '\r')) {
            *at += 1;
        }
    }

    <A: std::mem::allocator>
    fn parse_value(t: str, at: usize&, depth: u32, a: A&) -> json_error!value<A> {
        if (depth > 512) {
            return json_error::SYNTAX; // nested too deep to be anything but an attack
        }
        skip_space(t, at);
        if (*at >= t.len) {
            return json_error::SYNTAX;
        }
        val c = t[*at];
        if (c == '{') {
            *at += 1;
            var ms: std::vec<member<A>, A> = { allocator: copy *a };
            skip_space(t, at);
            if (*at < t.len && t[*at] == '}') {
                *at += 1;
                return value<A>::OBJ(move ms);
            }
            loop {
                skip_space(t, at);
                if (*at >= t.len || t[*at] != '"') {
                    return json_error::SYNTAX;
                }
                var name = try parse_string(t, at, a);
                skip_space(t, at);
                if (*at >= t.len || t[*at] != ':') {
                    return json_error::SYNTAX;
                }
                *at += 1;
                var item = try parse_value(t, at, depth + 1, a);
                ms.push({ name: move name, item: move item }) catch @panic("out of memory");
                skip_space(t, at);
                if (*at < t.len && t[*at] == ',') {
                    *at += 1;
                } else if (*at < t.len && t[*at] == '}') {
                    *at += 1;
                    return value<A>::OBJ(move ms);
                } else {
                    return json_error::SYNTAX;
                }
            }
        }
        if (c == '[') {
            *at += 1;
            var xs: std::vec<value<A>, A> = { allocator: copy *a };
            skip_space(t, at);
            if (*at < t.len && t[*at] == ']') {
                *at += 1;
                return value<A>::ARR(move xs);
            }
            loop {
                var item = try parse_value(t, at, depth + 1, a);
                xs.push(move item) catch @panic("out of memory");
                skip_space(t, at);
                if (*at < t.len && t[*at] == ',') {
                    *at += 1;
                } else if (*at < t.len && t[*at] == ']') {
                    *at += 1;
                    return value<A>::ARR(move xs);
                } else {
                    return json_error::SYNTAX;
                }
            }
        }
        if (c == '"') {
            return value<A>::STR(try parse_string(t, at, a));
        }
        if (word(t, at, "true")) {
            return value<A>::BOOL(true);
        }
        if (word(t, at, "false")) {
            return value<A>::BOOL(false);
        }
        if (word(t, at, "null")) {
            return value<A>::NULL;
        }
        // a number: the characters one can have, then its exact value (trailing junk is an error)
        val start = *at;
        while (*at < t.len && ((t[*at] >= '0' && t[*at] <= '9') || t[*at] == '.' || t[*at] == 'e' || t[*at] == 'E' || t[*at] == '+' || t[*at] == '-')) {
            *at += 1;
        }
        if (t[start] == '+') {
            return json_error::SYNTAX;
        }
        val x = std::decimal_to_f64(t[start..*at]) ?? return json_error::SYNTAX;
        return value<A>::NUM(x);
    }

    fn word(t: str, at: usize&, w: str) -> bool {
        if (*at + w.len <= t.len && t[*at..*at + w.len] == w) {
            *at += w.len;
            return true;
        }
        return false;
    }

    fn hex_digit(c: u8) -> u32? {
        if (c >= '0' && c <= '9') {
            return @cast<u32>(c - '0');
        }
        if (c >= 'a' && c <= 'f') {
            return @cast<u32>(c - 'a') + 10;
        }
        if (c >= 'A' && c <= 'F') {
            return @cast<u32>(c - 'A') + 10;
        }
        return null;
    }

    // \uXXXX's four hex digits at t[at..]
    fn hex4(t: str, at: usize) -> u32? {
        if (at + 4 > t.len) {
            return null;
        }
        var v: u32 = 0;
        var i: usize = 0;
        while (i < 4) {
            v = v * 16 + (hex_digit(t[at + i]) ?? return null);
            i += 1;
        }
        return v;
    }

    // the code point cp as UTF-8
    <A: std::mem::allocator>
    fn put_utf8(out: std::string<A>&, cp: u32) -> void {
        if (cp < 0x80) {
            out.push(@cast<u8>(cp));
        } else if (cp < 0x800) {
            out.push(@cast<u8>(0xC0 | (cp >> 6)));
            out.push(@cast<u8>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push(@cast<u8>(0xE0 | (cp >> 12)));
            out.push(@cast<u8>(0x80 | ((cp >> 6) & 0x3F)));
            out.push(@cast<u8>(0x80 | (cp & 0x3F)));
        } else {
            out.push(@cast<u8>(0xF0 | (cp >> 18)));
            out.push(@cast<u8>(0x80 | ((cp >> 12) & 0x3F)));
            out.push(@cast<u8>(0x80 | ((cp >> 6) & 0x3F)));
            out.push(@cast<u8>(0x80 | (cp & 0x3F)));
        }
    }

    // a string literal at t[at] (the opening quote), unescaped
    <A: std::mem::allocator>
    fn parse_string(t: str, at: usize&, a: A&) -> json_error!std::string<A> {
        *at += 1;
        var out = std::string::new_in(copy *a);
        while (*at < t.len) {
            val c = t[*at];
            if (c == '"') {
                *at += 1;
                return out;
            }
            if (c < 0x20) {
                return json_error::SYNTAX;
            }
            if (c != '\\') {
                out.push(c);
                *at += 1;
                continue;
            }
            if (*at + 1 >= t.len) {
                return json_error::SYNTAX;
            }
            val e = t[*at + 1];
            *at += 2;
            if (e == 'n') {
                out.push('\n');
            } else if (e == 't') {
                out.push('\t');
            } else if (e == 'r') {
                out.push('\r');
            } else if (e == 'b') {
                out.push(8);
            } else if (e == 'f') {
                out.push(12);
            } else if (e == '"' || e == '\\' || e == '/') {
                out.push(e);
            } else if (e == 'u') {
                var cp = hex4(t, *at) ?? return json_error::SYNTAX;
                *at += 4;
                // a surrogate pair is one code point
                if (cp >= 0xD800 && cp < 0xDC00 && *at + 6 <= t.len && t[*at] == '\\' && t[*at + 1] == 'u') {
                    val lo = hex4(t, *at + 2) ?? return json_error::SYNTAX;
                    if (lo >= 0xDC00 && lo < 0xE000) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        *at += 6;
                    }
                }
                put_utf8(&out, cp);
            } else {
                return json_error::SYNTAX;
            }
        }
        return json_error::SYNTAX;
    }

    // ---------- writing ----------

    // the value as compact JSON text
    <A: std::mem::allocator, B: std::mem::allocator = std::mem::default_allocator>
    public attach fn text(this: value<A>&, allocator: B = {}) -> std::string<B> {
        var out = std::string::new_in(move allocator);
        this.write(&out);
        return out;
    }

    // append the value to out as compact JSON text
    <A: std::mem::allocator, B: std::mem::allocator>
    public attach fn write(this: value<A>&, out: std::string<B>&) -> void {
        match (*this) {
            .NULL => { out.append("null"); },
            .BOOL(b) => {
                if (b) {
                    out.append("true");
                } else {
                    out.append("false");
                }
            },
            .NUM(x) => { write_num(out, x); },
            .STR(s&) => { write_str(out, s.as_str()); },
            .ARR(xs&) => {
                out.push('[');
                for (i) in 0..xs.len {
                    if (i > 0) {
                        out.push(',');
                    }
                    xs[i].write(out);
                }
                out.push(']');
            },
            .OBJ(ms&) => {
                out.push('{');
                for (i) in 0..ms.len {
                    if (i > 0) {
                        out.push(',');
                    }
                    write_str(out, ms[i].name.as_str());
                    out.push(':');
                    ms[i].item.write(out);
                }
                out.push('}');
            },
        }
    }

    // a whole number exactly, anything else with 17 significant digits
    <B: std::mem::allocator>
    fn write_num(out: std::string<B>&, x: f64) -> void {
        if (x == x && x >= -9007199254740992.0 && x <= 9007199254740992.0 && @cast<f64>(@cast<i64>(x)) == x) {
            out.append_int(@cast<i64>(x));
            return;
        }
        if (x != x || x > 1.7976931348623157e308 || x < -1.7976931348623157e308) {
            out.append("null"); // JSON has no NaN or infinity
            return;
        }
        var buf: u8[32];
        val n = std::fmt::shortest(&buf[0], x, false); // reads back as the same double
        out.append(@cast<str>(@slice(&buf[0], n)));
    }

    <B: std::mem::allocator>
    fn write_str(out: std::string<B>&, s: str) -> void {
        val hex: str = "0123456789abcdef";
        out.push('"');
        for (c) in s {
            if (c == '"') {
                out.append("\\\"");
            } else if (c == '\\') {
                out.append("\\\\");
            } else if (c == '\n') {
                out.append("\\n");
            } else if (c == '\r') {
                out.append("\\r");
            } else if (c == '\t') {
                out.append("\\t");
            } else if (c < 0x20) {
                out.append("\\u00");
                out.push(hex[c >> 4]);
                out.push(hex[c & 15]);
            } else {
                out.push(c);
            }
        }
        out.push('"');
    }

    // ---------- looking inside ----------

    // what get and at give for a member or element that isn't there: null, so lookups chain,
    // v.get("a").get("b").as_str() ?? "none". One buffer serves every value<A> (a null has no
    // payload); it's made null again on each use, so assigning through it changes nothing
    var missing_bytes: u64[32];

    <A: std::mem::allocator>
    fn missing() -> value<A>& {
        comptime if (@sizeof(value<A>) > 256 || @alignof(value<A>) > 8) {
            @compile_error("std::json: values with this allocator are too big for a missing lookup's null");
        }
        val p = @cast<value<A>*>(&missing_bytes);
        @write(p, value<A>::NULL);
        return @cast<value<A>&>(p);
    }

    // an object's member called key (null when there's none)
    <A: std::mem::allocator>
    public attach fn get(this: value<A>&, key: str) -> value<A>& {
        match (*this) {
            .OBJ(ms&) => {
                for (m&) in ms.items() {
                    if (m.name.as_str() == key) {
                        return &m.item;
                    }
                }
            },
            default => {},
        }
        return missing<A>();
    }

    // an array's element i (null when there's none)
    <A: std::mem::allocator>
    public attach fn at(this: value<A>&, i: usize) -> value<A>& {
        match (*this) {
            .ARR(xs&) => {
                if (i < xs.len) {
                    return &xs[i];
                }
            },
            default => {},
        }
        return missing<A>();
    }

    // how many elements (an array) or members (an object)
    <A: std::mem::allocator>
    public attach fn len(this: value<A>&) -> usize {
        match (*this) {
            .ARR(xs&) => { return xs.len; },
            .OBJ(ms&) => { return ms.len; },
            default => { return 0; },
        }
    }

    // a string's text (null for anything else)
    <A: std::mem::allocator>
    public attach fn as_str(this: value<A>&) -> str? {
        match (*this) {
            .STR(s&) => { return s.as_str(); },
            default => { return null; },
        }
    }

    // a number (null for anything else)
    <A: std::mem::allocator>
    public attach fn as_num(this: value<A>&) -> f64? {
        match (*this) {
            .NUM(x) => { return x; },
            default => { return null; },
        }
    }

    // true or false (null for anything else)
    <A: std::mem::allocator>
    public attach fn as_bool(this: value<A>&) -> bool? {
        match (*this) {
            .BOOL(b) => { return b; },
            default => { return null; },
        }
    }

    // is it null? (a missing member or element is too)
    <A: std::mem::allocator>
    public attach fn is_null(this: value<A>&) -> bool {
        match (*this) {
            .NULL => { return true; },
            default => { return false; },
        }
    }

    // ---------- building ----------

    // an empty object (add members with set)
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn object(allocator: A = {}) -> value<A> {
        val ms: std::vec<member<A>, A> = { allocator: move allocator };
        return value<A>::OBJ(move ms);
    }

    // an empty array (add elements with add)
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn array(allocator: A = {}) -> value<A> {
        val xs: std::vec<value<A>, A> = { allocator: move allocator };
        return value<A>::ARR(move xs);
    }

    // a string value holding a copy of s
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn string(s: str, allocator: A = {}) -> value<A> {
        return value<A>::STR(std::string::from(s, move allocator));
    }

    // a number value (the allocator only picks which value<A> it is)
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn number(x: f64, allocator: A = {}) -> value<A> {
        return value<A>::NUM(x);
    }

    // true or false (the allocator only picks which value<A> it is)
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn boolean(b: bool, allocator: A = {}) -> value<A> {
        return value<A>::BOOL(b);
    }

    // null (the allocator only picks which value<A> it is)
    <A: std::mem::allocator = std::mem::default_allocator>
    public fn null_value(allocator: A = {}) -> value<A> {
        return value<A>::NULL;
    }

    // set an object's member (replacing one with the same name)
    <A: std::mem::allocator>
    public attach fn set(this: value<A>&, key: str, v: value<A>) -> void {
        match (*this) {
            .OBJ(ms&) => {
                var found: usize? = null;
                for (i) in 0..ms.len {
                    if (ms[i].name.as_str() == key) {
                        found = i;
                    }
                }
                if (found) {
                    ms[found].item = move v;
                    return;
                }
                ms.push({ name: std::string::from(key, copy ms.allocator), item: move v }) catch @panic("out of memory");
            },
            default => { @panic("json set: not an object"); },
        }
    }

    // add an element to an array
    <A: std::mem::allocator>
    public attach fn add(this: value<A>&, v: value<A>) -> void {
        match (*this) {
            .ARR(xs&) => { xs.push(move v) catch @panic("out of memory"); },
            default => { @panic("json add: not an array"); },
        }
    }
}
