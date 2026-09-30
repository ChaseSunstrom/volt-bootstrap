// std::json: JSON values, read from text (parse) and written back (text).
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace json {
    // a JSON value; an object keeps its members in order
    enum value {
        NULL,                // null
        BOOL: bool,          // true or false
        NUM: f64,            // a number (JSON has one kind)
        STR: std::string,    // a string, unescaped
        ARR: std::vec<value>, // an array
        OBJ: std::vec<member>, // an object: its members in order
    }

    // one member of an object
    struct member {
        name: std::string; // the key
        item: value;       // its value
    }

    // why parse failed
    error json_error {
        SYNTAX, // the text isn't JSON
    }

    internal extern "C" fn strtod(s: cstr, end: void*) -> f64;
    internal extern "C" fn snprintf(buf: u8*, n: usize, fmt: cstr, ...) -> i32;

    // ---------- reading ----------

    // the text parsed; whitespace around the value is fine, anything else after it isn't
    fn parse(text: str) -> json_error!value {
        var at: usize = 0;
        val v = try parse_value(text, &at, 0);
        skip_space(text, &at);
        if (at != text.len) {
            return json_error::SYNTAX;
        }
        return move v;
    }

    internal fn skip_space(t: str, at: usize&) -> void {
        while (*at < t.len && (t[*at] == ' ' || t[*at] == '\t' || t[*at] == '\n' || t[*at] == '\r')) {
            *at += 1;
        }
    }

    internal fn parse_value(t: str, at: usize&, depth: u32) -> json_error!value {
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
            var ms: std::vec<member> = {};
            skip_space(t, at);
            if (*at < t.len && t[*at] == '}') {
                *at += 1;
                return value::OBJ(move ms);
            }
            loop {
                skip_space(t, at);
                if (*at >= t.len || t[*at] != '"') {
                    return json_error::SYNTAX;
                }
                var name = try parse_string(t, at);
                skip_space(t, at);
                if (*at >= t.len || t[*at] != ':') {
                    return json_error::SYNTAX;
                }
                *at += 1;
                var item = try parse_value(t, at, depth + 1);
                ms.push({ name: move name, item: move item }) catch @panic("out of memory");
                skip_space(t, at);
                if (*at < t.len && t[*at] == ',') {
                    *at += 1;
                } else if (*at < t.len && t[*at] == '}') {
                    *at += 1;
                    return value::OBJ(move ms);
                } else {
                    return json_error::SYNTAX;
                }
            }
        }
        if (c == '[') {
            *at += 1;
            var xs: std::vec<value> = {};
            skip_space(t, at);
            if (*at < t.len && t[*at] == ']') {
                *at += 1;
                return value::ARR(move xs);
            }
            loop {
                var item = try parse_value(t, at, depth + 1);
                xs.push(move item) catch @panic("out of memory");
                skip_space(t, at);
                if (*at < t.len && t[*at] == ',') {
                    *at += 1;
                } else if (*at < t.len && t[*at] == ']') {
                    *at += 1;
                    return value::ARR(move xs);
                } else {
                    return json_error::SYNTAX;
                }
            }
        }
        if (c == '"') {
            return value::STR(try parse_string(t, at));
        }
        if (word(t, at, "true")) {
            return value::BOOL(true);
        }
        if (word(t, at, "false")) {
            return value::BOOL(false);
        }
        if (word(t, at, "null")) {
            return value::NULL;
        }
        // a number: JSON's grammar, then strtod for its value
        val start = *at;
        if (*at < t.len && t[*at] == '-') {
            *at += 1;
        }
        val digits_at = *at;
        while (*at < t.len && ((t[*at] >= '0' && t[*at] <= '9') || t[*at] == '.' || t[*at] == 'e' || t[*at] == 'E' || t[*at] == '+' || t[*at] == '-')) {
            *at += 1;
        }
        if (*at == digits_at) {
            return json_error::SYNTAX;
        }
        var n = std::string::from(t[start..*at]);
        return value::NUM(strtod(n.c_str(), null));
    }

    internal fn word(t: str, at: usize&, w: str) -> bool {
        if (*at + w.len <= t.len && t[*at..*at + w.len] == w) {
            *at += w.len;
            return true;
        }
        return false;
    }

    internal fn hex_digit(c: u8) -> u32? {
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
    internal fn hex4(t: str, at: usize) -> u32? {
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
    internal fn put_utf8(out: std::string&, cp: u32) -> void {
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
    internal fn parse_string(t: str, at: usize&) -> json_error!std::string {
        *at += 1;
        var out: std::string = {};
        while (*at < t.len) {
            val c = t[*at];
            if (c == '"') {
                *at += 1;
                return move out;
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
    attach fn text(this: value&) -> std::string {
        var out: std::string = {};
        this.write(&out);
        return move out;
    }

    // append the value to out as compact JSON text
    attach fn write(this: value&, out: std::string&) -> void {
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
                    xs.at(i).write(out);
                }
                out.push(']');
            },
            .OBJ(ms&) => {
                out.push('{');
                for (i) in 0..ms.len {
                    if (i > 0) {
                        out.push(',');
                    }
                    write_str(out, ms.at(i).name.as_str());
                    out.push(':');
                    ms.at(i).item.write(out);
                }
                out.push('}');
            },
        }
    }

    // a whole number exactly, anything else with 17 significant digits
    internal fn write_num(out: std::string&, x: f64) -> void {
        if (x == x && x >= -9007199254740992.0 && x <= 9007199254740992.0 && @cast<f64>(@cast<i64>(x)) == x) {
            out.append_int(@cast<i64>(x));
            return;
        }
        if (x != x || x > 1.7976931348623157e308 || x < -1.7976931348623157e308) {
            out.append("null"); // JSON has no NaN or infinity
            return;
        }
        var buf: u8[32];
        val n = snprintf(&buf[0], 32, "%.17g", x);
        out.append(@cast<str>(@slice(&buf[0], @cast<usize>(n))));
    }

    internal fn write_str(out: std::string&, s: str) -> void {
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
    // v.get("a").get("b").as_str() ?? "none"
    internal var missing: value = value::NULL;

    // an object's member called key (null when there's none)
    attach fn get(this: value&, key: str) -> value& {
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
        missing = value::NULL; // in case someone assigned to it
        return &missing;
    }

    // an array's element i (null when there's none)
    attach fn at(this: value&, i: usize) -> value& {
        match (*this) {
            .ARR(xs&) => {
                if (i < xs.len) {
                    return xs.at(i);
                }
            },
            default => {},
        }
        missing = value::NULL;
        return &missing;
    }

    // how many elements (an array) or members (an object)
    attach fn len(this: value&) -> usize {
        match (*this) {
            .ARR(xs&) => { return xs.len; },
            .OBJ(ms&) => { return ms.len; },
            default => { return 0; },
        }
    }

    // a string's text (null for anything else)
    attach fn as_str(this: value&) -> str? {
        match (*this) {
            .STR(s&) => { return s.as_str(); },
            default => { return null; },
        }
    }

    // a number (null for anything else)
    attach fn as_num(this: value&) -> f64? {
        match (*this) {
            .NUM(x) => { return x; },
            default => { return null; },
        }
    }

    // true or false (null for anything else)
    attach fn as_bool(this: value&) -> bool? {
        match (*this) {
            .BOOL(b) => { return b; },
            default => { return null; },
        }
    }

    // is it null? (a missing member or element is too)
    attach fn is_null(this: value&) -> bool {
        match (*this) {
            .NULL => { return true; },
            default => { return false; },
        }
    }

    // ---------- building ----------

    // an empty object (add members with set)
    fn object() -> value {
        return value::OBJ({});
    }

    // an empty array (add elements with add)
    fn array() -> value {
        return value::ARR({});
    }

    // a string value holding a copy of s
    fn string(s: str) -> value {
        return value::STR(std::string::from(s));
    }

    // a number value
    fn number(x: f64) -> value {
        return value::NUM(x);
    }

    // set an object's member (replacing one with the same name)
    attach fn set(this: value&, key: str, v: value) -> void {
        match (*this) {
            .OBJ(ms&) => {
                var found: usize? = null;
                for (i) in 0..ms.len {
                    if (ms.at(i).name.as_str() == key) {
                        found = i;
                    }
                }
                if (found) {
                    ms.at(found).item = move v;
                    return;
                }
                ms.push({ name: std::string::from(key), item: move v }) catch @panic("out of memory");
            },
            default => { @panic("json set: not an object"); },
        }
    }

    // add an element to an array
    attach fn add(this: value&, v: value) -> void {
        match (*this) {
            .ARR(xs&) => { xs.push(move v) catch @panic("out of memory"); },
            default => { @panic("json add: not an array"); },
        }
    }
}
