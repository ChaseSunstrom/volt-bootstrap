// std::compare: eq and cmp, the methods std's collections and algorithms compare values with.
// Every type with == and < has them here; a type of your own attaches its own
// (eq(this: T&, other: T&) -> bool, cmp(this: T&, other: T&) -> i32), and those win over these.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// whether this and other are equal, by ==
<T: type>
public attach fn eq(this: T&, other: T&) -> bool {
    return *this == *other;
}

// optionals: both empty, or both holding equal values
<T: type>
public attach fn eq(this: T?&, other: T?&) -> bool {
    if (*this == null || *other == null) {
        return *this == null && *other == null;
    }
    return this.value.eq(&other.value);
}

// slices: as long, and equal element by element. Integers and bools compare as bytes, all at once
// (floats can't: NaN isn't equal to itself, and -0.0 is equal to 0.0)
<T: type>
public attach fn eq(this: T[..]&, other: T[..]&) -> bool {
    if (this.len != other.len) {
        return false;
    }
    comptime if (@cfg("hosted")) {
        comptime match (@typeinfo(T).kind) {
            .INT(k) => {
                return this.len == 0 || std::text::libc::memcmp(@cast<void*>(this.ptr), @cast<void*>(other.ptr), this.len * @sizeof(T)) == 0;
            },
            .BOOL => {
                return this.len == 0 || std::text::libc::memcmp(@cast<void*>(this.ptr), @cast<void*>(other.ptr), this.len * @sizeof(T)) == 0;
            },
            default => {},
        }
    }
    for (x&, i) in *this {
        if (!x.eq(&(*other)[i])) {
            return false;
        }
    }
    return true;
}

// vectors: their elements, as slices
<T: type, A: std::mem::allocator, B: std::mem::allocator>
public attach fn eq(this: std::vec<T, A>&, other: std::vec<T, B>&) -> bool {
    val b = other.items();
    return this.items().eq(&b);
}

// -1, 0 or 1: how this sorts against other, by <
<T: type>
public attach fn cmp(this: T&, other: T&) -> i32 {
    if (*this < *other) {
        return -1;
    }
    if (*other < *this) {
        return 1;
    }
    return 0;
}

// str sorts byte by byte (see str's cmp in std::text)
public attach fn cmp(this: str&, other: str&) -> i32 {
    return this.cmp(*other);
}
