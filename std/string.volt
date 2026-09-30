// std::string: an owned, growable UTF-8 string.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// Owned, growable text: bytes (UTF-8 by convention, not checked). Prints as its text.
struct string {
    bytes: std::vec<u8> = {}; // the text's bytes
}

// a string holding a copy of s
attach fn from(static this: std::string, s: str) -> std::string {
    var out: std::string = {};
    out.append(s);
    return move out;
}

// the text (valid until the string changes)
attach fn as_str(this: std::string&) -> str {
    return @cast<str>(this.bytes.items());
}

// the length in bytes
attach fn len(this: std::string&) -> usize {
    return this.bytes.len;
}

// append one byte
attach fn push(this: std::string&, byte: u8) -> void {
    this.bytes.push(byte) catch @panic("out of memory");
}

// append s
attach fn append(this: std::string&, s: str) -> void {
    this.bytes.reserve(this.bytes.len + s.len) catch @panic("out of memory");
    for (b) in s {
        this.bytes.push(b) catch @panic("out of memory");
    }
}

// decimal digits of v
attach fn append_int(this: std::string&, v: i64) -> void {
    if (v < 0) {
        this.push(45); // '-'
        // -(i64 min) doesn't fit: go through u64
        this.append_uint(@cast<u64>(0 -% v));
        return;
    }
    this.append_uint(@cast<u64>(v));
}

// decimal digits of v
attach fn append_uint(this: std::string&, v: u64) -> void {
    var digits: u8[20];
    var n: usize = 0;
    var x = v;
    loop {
        digits[n] = @cast<u8>(x % 10) + 48;
        n += 1;
        x = x / 10;
        if (x == 0) {
            break;
        }
    }
    while (n > 0) {
        n -= 1;
        this.push(digits[n]);
    }
}

// is it empty?
attach fn is_empty(this: std::string&) -> bool {
    return this.bytes.len == 0;
}

// make it empty (the memory stays for reuse)
attach fn clear(this: std::string&) -> void {
    this.bytes.clear();
}

// keep the first n bytes (nothing happens when it's already that short)
attach fn truncate(this: std::string&, n: usize) -> void {
    while (this.bytes.len > n) {
        val b = this.bytes.pop();
    }
}

// the last byte, taken off
attach fn pop(this: std::string&) -> u8? {
    return this.bytes.pop();
}

// s inserted at byte index at (the end when at is past it)
attach fn insert(this: std::string&, at: usize, s: str) -> void {
    var i = at;
    if (i > this.bytes.len) {
        i = this.bytes.len;
    }
    var tail = std::string::from(this.as_str()[i..this.bytes.len]);
    this.truncate(i);
    this.append(s);
    this.append(tail.as_str());
}

// append a character, as UTF-8 (one that isn't a character is U+FFFD)
attach fn push_char(this: std::string&, c: u32) -> void {
    var cp = c;
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
        cp = 0xFFFD;
    }
    if (cp < 0x80) {
        this.push(@cast<u8>(cp));
    } else if (cp < 0x800) {
        this.push(@cast<u8>(0xC0 | (cp >> 6)));
        this.push(@cast<u8>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        this.push(@cast<u8>(0xE0 | (cp >> 12)));
        this.push(@cast<u8>(0x80 | ((cp >> 6) & 0x3F)));
        this.push(@cast<u8>(0x80 | (cp & 0x3F)));
    } else {
        this.push(@cast<u8>(0xF0 | (cp >> 18)));
        this.push(@cast<u8>(0x80 | ((cp >> 12) & 0x3F)));
        this.push(@cast<u8>(0x80 | ((cp >> 6) & 0x3F)));
        this.push(@cast<u8>(0x80 | (cp & 0x3F)));
    }
}

// the same text
attach fn eq(this: std::string&, other: std::string&) -> bool {
    return this.as_str() == other.as_str();
}

// -1, 0 or 1: how the text sorts, byte by byte
attach fn cmp(this: std::string&, other: std::string&) -> i32 {
    return this.as_str().cmp(other.as_str());
}

// the text's hash, so strings can be map keys
attach fn hash(this: std::string&) -> u64 {
    return this.as_str().hash();
}

// append s: this makes a string a writer, for std::write (and std::format)
attach fn write_str(this: std::string&, s: str) -> void {
    this.append(s);
}

// a NUL-terminated view for C (valid until the string changes)
attach fn c_str(this: std::string&) -> cstr {
    this.push(0);
    this.bytes.len -= 1; // the 0 stays in memory just past the text
    return @cast<cstr>(this.bytes.ptr);
}
