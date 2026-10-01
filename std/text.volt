// std::text: searching, trimming, splitting, replacing and parsing text (methods on str), UTF-8,
// and ASCII character classes (methods on u8). What makes new text returns a std::string;
// splitting returns views into the text it split, as a std::vec<str>.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace text {
    // why parse_int, parse_uint, parse_float or parse_bool failed
    error parse_error {
        EMPTY,    // there was nothing to parse
        INVALID,  // it isn't a number (or true/false)
        OVERFLOW, // the number doesn't fit
    }

    // the parts with sep between them
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn join(parts: str[..], sep: str, allocator: A = {}) -> std::string<A> {
        var out = std::string::new_in(move allocator);
        for (p, i) in parts {
            if (i > 0) {
                out.append(sep);
            }
            out.append(p);
        }
        return move out;
    }

    // the parts with sep between them (owned strings, like std::fs::list_dir gives)
    <B: std::mem::t_allocator, A: std::mem::t_allocator = std::mem::default_allocator>
    fn join(parts: std::string<B>[..], sep: str, allocator: A = {}) -> std::string<A> {
        var out = std::string::new_in(move allocator);
        for (p&, i) in parts {
            if (i > 0) {
                out.append(sep);
            }
            out.append(p.as_str());
        }
        return move out;
    }

    internal extern "C" fn strtod(s: cstr, end: void*) -> f64;
}

// ---------- searching ----------

// where needle first starts, as a byte index (an empty needle is at 0)
attach fn find(this: str&, needle: str) -> usize? {
    val s = *this;
    if (needle.len > s.len) {
        return null;
    }
    for (i) in 0..(s.len - needle.len + 1) {
        if (s[i..i + needle.len] == needle) {
            return i;
        }
    }
    return null;
}

// where needle last starts
attach fn rfind(this: str&, needle: str) -> usize? {
    val s = *this;
    if (needle.len > s.len) {
        return null;
    }
    var i = s.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (s[i..i + needle.len] == needle) {
            return i;
        }
    }
    return null;
}

// is needle in it?
attach fn contains(this: str&, needle: str) -> bool {
    return this.find(needle) != null;
}

attach fn starts_with(this: str&, prefix: str) -> bool {
    val s = *this;
    return s.len >= prefix.len && s[0..prefix.len] == prefix;
}

attach fn ends_with(this: str&, suffix: str) -> bool {
    val s = *this;
    return s.len >= suffix.len && s[s.len - suffix.len..s.len] == suffix;
}

// how many times needle appears, not overlapping (an empty needle counts 0)
attach fn count(this: str&, needle: str) -> usize {
    val s = *this;
    if (needle.len == 0) {
        return 0;
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= s.len) {
        if (s[i..i + needle.len] == needle) {
            n += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return n;
}

// ---------- trimming ----------

// without the ASCII whitespace at either end
attach fn trim(this: str&) -> str {
    return this.trim_start().trim_end();
}

attach fn trim_start(this: str&) -> str {
    val s = *this;
    var i: usize = 0;
    while (i < s.len && s[i].is_space()) {
        i += 1;
    }
    return s[i..s.len];
}

attach fn trim_end(this: str&) -> str {
    val s = *this;
    var n = s.len;
    while (n > 0 && s[n - 1].is_space()) {
        n -= 1;
    }
    return s[0..n];
}

// the rest after prefix (null when it doesn't start with it)
attach fn strip_prefix(this: str&, prefix: str) -> str? {
    if (!this.starts_with(prefix)) {
        return null;
    }
    val s = *this;
    return s[prefix.len..s.len];
}

// what comes before suffix (null when it doesn't end with it)
attach fn strip_suffix(this: str&, suffix: str) -> str? {
    if (!this.ends_with(suffix)) {
        return null;
    }
    val s = *this;
    return s[0..s.len - suffix.len];
}

// ---------- splitting ----------

// the parts before and after the first sep (null when there's none)
attach fn split_once(this: str&, sep: str) -> (str, str)? {
    val i = this.find(sep) ?? return null;
    val s = *this;
    return (s[0..i], s[i + sep.len..s.len]);
}

// the parts between each sep ("a,,b" has an empty one in the middle); an empty sep splits into
// characters
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn split(this: str&, sep: str, allocator: A = {}) -> std::vec<str, A> {
    val s = *this;
    var out: std::vec<str, A> = { allocator: move allocator };
    if (sep.len == 0) {
        var i: usize = 0;
        while (i < s.len) {
            val n = utf8_width(s, i);
            out.push(s[i..i + n]) catch @panic("out of memory");
            i += n;
        }
        return move out;
    }
    var start: usize = 0;
    var i: usize = 0;
    while (i + sep.len <= s.len) {
        if (s[i..i + sep.len] == sep) {
            out.push(s[start..i]) catch @panic("out of memory");
            i += sep.len;
            start = i;
        } else {
            i += 1;
        }
    }
    out.push(s[start..s.len]) catch @panic("out of memory");
    return move out;
}

// the lines, without their \n or \r\n (a final newline doesn't start another line)
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn lines(this: str&, allocator: A = {}) -> std::vec<str, A> {
    val s = *this;
    var out: std::vec<str, A> = { allocator: move allocator };
    var start: usize = 0;
    for (i) in 0..s.len {
        if (s[i] == '\n') {
            var end = i;
            if (end > start && s[end - 1] == '\r') {
                end -= 1;
            }
            out.push(s[start..end]) catch @panic("out of memory");
            start = i + 1;
        }
    }
    if (start < s.len) {
        out.push(s[start..s.len]) catch @panic("out of memory");
    }
    return move out;
}

// the words: the parts between runs of ASCII whitespace
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn words(this: str&, allocator: A = {}) -> std::vec<str, A> {
    val s = *this;
    var out: std::vec<str, A> = { allocator: move allocator };
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len && s[i].is_space()) {
            i += 1;
        }
        val start = i;
        while (i < s.len && !s[i].is_space()) {
            i += 1;
        }
        if (i > start) {
            out.push(s[start..i]) catch @panic("out of memory");
        }
    }
    return move out;
}

// ---------- new text ----------

// every from replaced by to, left to right (an empty from changes nothing)
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn replace(this: str&, from: str, to: str, allocator: A = {}) -> std::string<A> {
    val s = *this;
    var out = std::string::new_in(move allocator);
    if (from.len == 0) {
        out.append(s);
        return move out;
    }
    var start: usize = 0;
    var i: usize = 0;
    while (i + from.len <= s.len) {
        if (s[i..i + from.len] == from) {
            out.append(s[start..i]);
            out.append(to);
            i += from.len;
            start = i;
        } else {
            i += 1;
        }
    }
    out.append(s[start..s.len]);
    return move out;
}

// n copies, one after another
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn repeat(this: str&, n: usize, allocator: A = {}) -> std::string<A> {
    var out = std::string::new_in(move allocator);
    for (i) in 0..n {
        out.append(*this);
    }
    return move out;
}

// ASCII letters in upper case (other bytes as they are)
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn to_upper(this: str&, allocator: A = {}) -> std::string<A> {
    var out = std::string::new_in(move allocator);
    for (b) in *this {
        out.push(b.to_upper());
    }
    return move out;
}

// ASCII letters in lower case
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn to_lower(this: str&, allocator: A = {}) -> std::string<A> {
    var out = std::string::new_in(move allocator);
    for (b) in *this {
        out.push(b.to_lower());
    }
    return move out;
}

// equal but for the case of ASCII letters?
attach fn eq_ignore_case(this: str&, other: str) -> bool {
    val s = *this;
    if (s.len != other.len) {
        return false;
    }
    for (i) in 0..s.len {
        if (s[i].to_lower() != other[i].to_lower()) {
            return false;
        }
    }
    return true;
}

// -1, 0 or 1: how it sorts against other, byte by byte (a prefix sorts first)
attach fn cmp(this: str&, other: str) -> i32 {
    val s = *this;
    var n = s.len;
    if (other.len < n) {
        n = other.len;
    }
    for (i) in 0..n {
        if (s[i] != other[i]) {
            if (s[i] < other[i]) {
                return -1;
            }
            return 1;
        }
    }
    if (s.len < other.len) {
        return -1;
    }
    if (s.len > other.len) {
        return 1;
    }
    return 0;
}

// ---------- parsing ----------

// a decimal integer with an optional sign: "42", "-7", "+3"
attach fn parse_int(this: str&) -> std::text::parse_error!i64 {
    val s = *this;
    if (s.len == 0) {
        return std::text::parse_error::EMPTY;
    }
    var neg = false;
    var body = s;
    if (s[0] == '-' || s[0] == '+') {
        neg = s[0] == '-';
        body = s[1..s.len];
    }
    if (body.len == 0) {
        return std::text::parse_error::INVALID;
    }
    var limit: u64 = 9223372036854775807;
    if (neg) {
        limit += 1;
    }
    var n: u64 = 0;
    for (c) in body {
        if (!c.is_digit()) {
            return std::text::parse_error::INVALID;
        }
        val d = (c - '0') as u64;
        if (n > (limit - d) / 10) {
            return std::text::parse_error::OVERFLOW;
        }
        n = n * 10 + d;
    }
    if (neg) {
        if (n == 9223372036854775808) {
            return -9223372036854775807 - 1;
        }
        return -@cast<i64>(n);
    }
    return @cast<i64>(n);
}

// a decimal integer that isn't negative: "42", "+3"
attach fn parse_uint(this: str&) -> std::text::parse_error!u64 {
    val s = *this;
    if (s.len == 0) {
        return std::text::parse_error::EMPTY;
    }
    var body = s;
    if (s[0] == '+') {
        body = s[1..s.len];
    }
    if (body.len == 0) {
        return std::text::parse_error::INVALID;
    }
    var n: u64 = 0;
    for (c) in body {
        if (!c.is_digit()) {
            return std::text::parse_error::INVALID;
        }
        val d = (c - '0') as u64;
        if (n > (18446744073709551615 - d) / 10) {
            return std::text::parse_error::OVERFLOW;
        }
        n = n * 10 + d;
    }
    return n;
}

// a decimal float: "3.5", "-1e3", ".5", "5.", "inf", "nan" (no spaces around it; too big is inf)
attach fn parse_float(this: str&) -> std::text::parse_error!f64 {
    val s = *this;
    if (s.len == 0) {
        return std::text::parse_error::EMPTY;
    }
    if (!float_syntax(s)) {
        return std::text::parse_error::INVALID;
    }
    var z = std::string::from(s);
    return std::text::strtod(z.c_str(), null);
}

// "true" or "false"
attach fn parse_bool(this: str&) -> std::text::parse_error!bool {
    val s = *this;
    if (s.len == 0) {
        return std::text::parse_error::EMPTY;
    }
    if (s == "true") {
        return true;
    }
    if (s == "false") {
        return false;
    }
    return std::text::parse_error::INVALID;
}

// [+-] digits [. digits] or [+-] . digits, then [e [+-] digits]; or inf, infinity, nan in any case
internal fn float_syntax(s: str) -> bool {
    var i: usize = 0;
    if (s[0] == '+' || s[0] == '-') {
        i = 1;
    }
    val rest = s[i..s.len];
    if (rest.eq_ignore_case("inf") || rest.eq_ignore_case("infinity") || rest.eq_ignore_case("nan")) {
        return true;
    }
    var digits: usize = 0;
    while (i < s.len && s[i].is_digit()) {
        i += 1;
        digits += 1;
    }
    if (i < s.len && s[i] == '.') {
        i += 1;
        while (i < s.len && s[i].is_digit()) {
            i += 1;
            digits += 1;
        }
    }
    if (digits == 0) {
        return false;
    }
    if (i < s.len && (s[i] == 'e' || s[i] == 'E')) {
        i += 1;
        if (i < s.len && (s[i] == '+' || s[i] == '-')) {
            i += 1;
        }
        var exp: usize = 0;
        while (i < s.len && s[i].is_digit()) {
            i += 1;
            exp += 1;
        }
        if (exp == 0) {
            return false;
        }
    }
    return i == s.len;
}

// ---------- UTF-8 ----------

// the character that starts at byte i, and its length in bytes; null when a valid one doesn't
// start there (i is inside one, or the bytes aren't UTF-8)
attach fn char_at(this: str&, i: usize) -> (u32, usize)? {
    val s = *this;
    if (i >= s.len) {
        return null;
    }
    val b = s[i] as u32;
    if (b < 0x80) {
        return (b, 1);
    }
    var n: usize = 0;
    var cp: u32 = 0;
    var least: u32 = 0;
    if (b >= 0xC2 && b <= 0xDF) {
        n = 2;
        cp = b & 0x1F;
        least = 0x80;
    } else if (b >= 0xE0 && b <= 0xEF) {
        n = 3;
        cp = b & 0x0F;
        least = 0x800;
    } else if (b >= 0xF0 && b <= 0xF4) {
        n = 4;
        cp = b & 0x07;
        least = 0x10000;
    } else {
        return null;
    }
    if (i + n > s.len) {
        return null;
    }
    for (k) in 1..n {
        val c = s[i + k] as u32;
        if ((c & 0xC0) != 0x80) {
            return null;
        }
        cp = (cp << 6) | (c & 0x3F);
    }
    // too long a form, a surrogate, or past U+10FFFF
    if (cp < least || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
        return null;
    }
    return (cp, n);
}

// is it valid UTF-8?
attach fn is_utf8(this: str&) -> bool {
    val s = *this;
    var i: usize = 0;
    while (i < s.len) {
        val c = s.char_at(i) ?? return false;
        i += c.1;
    }
    return true;
}

// how many characters (a byte that isn't valid UTF-8 counts as one)
attach fn char_count(this: str&) -> usize {
    val s = *this;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += utf8_width(s, i);
        n += 1;
    }
    return n;
}

// the characters as code points (a byte that isn't valid UTF-8 is U+FFFD)
<A: std::mem::t_allocator = std::mem::default_allocator>
attach fn chars(this: str&, allocator: A = {}) -> std::vec<u32, A> {
    val s = *this;
    var out: std::vec<u32, A> = { allocator: move allocator };
    var i: usize = 0;
    while (i < s.len) {
        val c = s.char_at(i);
        if (c) {
            out.push(c.0) catch @panic("out of memory");
            i += c.1;
        } else {
            out.push(0xFFFD) catch @panic("out of memory");
            i += 1;
        }
    }
    return move out;
}

// how many bytes the character at s[i] takes (1 when a valid one doesn't start there)
internal fn utf8_width(s: str, i: usize) -> usize {
    val c = s.char_at(i) ?? return 1;
    return c.1;
}

// ---------- ASCII classes ----------

attach fn is_digit(this: u8&) -> bool {
    return *this >= '0' && *this <= '9';
}

attach fn is_alpha(this: u8&) -> bool {
    val c = *this;
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

attach fn is_alnum(this: u8&) -> bool {
    return this.is_alpha() || this.is_digit();
}

// space, tab, newline, carriage return, vertical tab or form feed
attach fn is_space(this: u8&) -> bool {
    val c = *this;
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0B || c == 0x0C;
}

attach fn is_upper(this: u8&) -> bool {
    return *this >= 'A' && *this <= 'Z';
}

attach fn is_lower(this: u8&) -> bool {
    return *this >= 'a' && *this <= 'z';
}

attach fn is_hex_digit(this: u8&) -> bool {
    val c = *this;
    return this.is_digit() || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

// an ASCII letter in upper case (anything else as it is)
attach fn to_upper(this: u8&) -> u8 {
    if (this.is_lower()) {
        return *this - 32;
    }
    return *this;
}

// an ASCII letter in lower case
attach fn to_lower(this: u8&) -> u8 {
    if (this.is_upper()) {
        return *this + 32;
    }
    return *this;
}
