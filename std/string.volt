// std::string: an owned, growable UTF-8 string.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// Owned, growable text: bytes (UTF-8 by convention, not checked). Prints as its text. An export fn
// that returns one hands other languages its text (@export_text).
<Allocator: std::mem::allocator = std::mem::default_allocator>
@attributes([@export_text("as_str")])
public struct string {
    bytes: std::vec<u8, Allocator> = {}; // the text's bytes
}

// a string holding a copy of s, in memory from allocator
<A: std::mem::allocator = std::mem::default_allocator>
public attach fn from(static this: std::string, s: str, allocator: A = {}) -> std::string<A> {
    var out: std::string<A> = { bytes: { allocator: move allocator } };
    out.append(s);
    return out;
}

// an empty string that allocates from allocator
<A: std::mem::allocator>
public attach fn new_in(static this: std::string, allocator: A) -> std::string<A> {
    return { bytes: { allocator: move allocator } };
}

// room for n bytes without growing
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn reserve(this: std::string<A>&, n: usize) -> std::mem::mem_error!void {
    return this.bytes.reserve(n);
}

// the text (valid until the string changes)
<A: std::mem::allocator>
public attach fn as_str(this: std::string<A>&) -> str {
    return @cast<str>(this.bytes.items());
}

// the length in bytes
<A: std::mem::allocator>
public attach fn len(this: std::string<A>&) -> usize {
    return this.bytes.len;
}

// s[i]: byte i (not character i), a place, bounds-checked like the vec it's kept in
<A: std::mem::allocator>
public attach operator [](this: std::string<A>&, i: usize) -> u8& {
    return this.bytes.at(i);
}

// append one byte
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn push(this: std::string<A>&, byte: u8) -> void {
    this.bytes.push(byte) catch @panic("out of memory");
}

// append s (s can be part of this string: vec.extend finds it again if growing moves it). Inlined:
// out of line it took the string's address, so a caller building text kept the string in memory and
// reloaded it after every byte it pushed
<A: std::mem::allocator>
@attributes([@invalidates, @inline])
public attach fn append(this: std::string<A>&, s: str) -> void {
    this.bytes.extend(@cast<u8[..]>(s)) catch @panic("out of memory");
}

// decimal digits of v
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn append_int(this: std::string<A>&, v: i64) -> void {
    if (v < 0) {
        this.push(45); // '-'
        // -(i64 min) doesn't fit: go through u64
        this.append_uint(@cast<u64>(0 -% v));
        return;
    }
    this.append_uint(@cast<u64>(v));
}

// decimal digits of v (unchecked: a u64 has at most 20 digits, and the room for them was reserved)
<A: std::mem::allocator>
@attributes([@invalidates, @unchecked])
public attach fn append_uint(this: std::string<A>&, v: u64) -> void {
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
    this.bytes.reserve(this.bytes.len + n) catch @panic("out of memory");
    val room = @slice(this.bytes.ptr, this.bytes.cap);
    for (k) in 0..n {
        room[this.bytes.len + k] = digits[n - 1 - k];
    }
    this.bytes.len += n;
}

// is it empty?
<A: std::mem::allocator>
public attach fn is_empty(this: std::string<A>&) -> bool {
    return this.bytes.len == 0;
}

// make it empty (the memory stays for reuse)
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn clear(this: std::string<A>&) -> void {
    this.bytes.clear();
}

// keep the first n bytes (nothing happens when it's already that short)
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn truncate(this: std::string<A>&, n: usize) -> void {
    while (this.bytes.len > n) {
        val b = this.bytes.pop();
    }
}

// the last byte, taken off
<A: std::mem::allocator>
public attach fn pop(this: std::string<A>&) -> u8? {
    return this.bytes.pop();
}

// s inserted at byte index at (the end when at is past it)
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn insert(this: std::string<A>&, at: usize, s: str) -> void {
    var i = at;
    if (i > this.bytes.len) {
        i = this.bytes.len;
    }
    // s can be part of this string: take a copy before the text moves
    val piece = std::string::from(s, copy this.bytes.allocator);
    var tail = std::string::from(this.as_str()[i..this.bytes.len], copy this.bytes.allocator);
    this.truncate(i);
    this.append(piece.as_str());
    this.append(tail.as_str());
}

// append a character, as UTF-8 (one that isn't a character is U+FFFD)
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn push_char(this: std::string<A>&, c: u32) -> void {
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
<A: std::mem::allocator, B: std::mem::allocator>
public attach fn eq(this: std::string<A>&, other: std::string<B>&) -> bool {
    return this.as_str() == other.as_str();
}

// -1, 0 or 1: how the text sorts, byte by byte
<A: std::mem::allocator, B: std::mem::allocator>
public attach fn cmp(this: std::string<A>&, other: std::string<B>&) -> i32 {
    return this.as_str().cmp(other.as_str());
}

// the text's hash, so strings can be map keys
<A: std::mem::allocator>
public attach fn hash(this: std::string<A>&) -> u64 {
    return this.as_str().hash();
}

// append s: this makes a string a writer, for std::write (and std::format)
<A: std::mem::allocator>
@attributes([@invalidates])
public attach fn write_str(this: std::string<A>&, s: str) -> void {
    this.append(s);
}

// a NUL-terminated view for C (valid until the string changes)
<A: std::mem::allocator>
public attach fn c_str(this: std::string<A>&) -> cstr {
    this.push(0);
    this.bytes.len -= 1; // the 0 stays in memory just past the text
    return @cast<cstr>(this.bytes.ptr);
}
