// std::vec: a growable array that owns its elements.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A growable array that owns its elements. Nothing is allocated until the first push.
<T: type, Allocator: std::mem::allocator = std::mem::default_allocator>
public struct vec {
    ptr: T* = @cast<T*>(@alignof(T)); // a non-null placeholder while cap is 0
    len: usize = 0;            // the elements held
    cap: usize = 0;            // room for this many before it grows
    allocator: Allocator = {}; // where the memory comes from
}

// an empty vec that allocates from allocator
<T: type, A: std::mem::allocator>
public attach fn new_in(static this: std::vec<T>, allocator: A) -> std::vec<T, A> {
    return { allocator: move allocator };
}

// the elements as a slice (valid until the vec changes)
<T: type, A: std::mem::allocator>
public attach fn items(this: std::vec<T, A>&) -> T[..] {
    return @slice(this.ptr, this.len);
}

// element i, bounds-checked (v[i] is the same place)
<T: type, A: std::mem::allocator>
public attach fn at(this: std::vec<T, A>&, i: usize) -> T& {
    return &(@slice(this.ptr, this.len)[i]);
}

// v[i]: element i, a place (read it, assign to it, borrow it), bounds-checked like at()
<T: type, A: std::mem::allocator>
public attach operator [](this: std::vec<T, A>&, i: usize) -> T& {
    return this.at(i);
}

// room for at least n elements
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn reserve(this: std::vec<T, A>&, n: usize) -> std::mem::mem_error!void {
    if (n <= this.cap) {
        return;
    }
    var cap = this.cap * 2;
    if (cap < n) {
        cap = n;
    }
    if (cap < 4) {
        cap = 4;
    }
    this.ptr = try moved_to<T, A>(this.ptr, this.cap, cap, copy this.allocator);
    this.cap = cap;
}

// a block for cap T's holding the old ones at ptr. Out of line, and given the fields rather than the
// vec: inlined into a loop that pushes or appends, the allocator's paths take the loop's registers,
// and a vec passed by reference would keep its length in memory (vec_grow and strings were 3-10%
// slower either way)
@attributes([@noinline])
<T: type, A: std::mem::allocator>
fn moved_to(ptr: T*, old: usize, cap: usize, allocator: A) -> std::mem::mem_error!(T*) {
    if (old == 0) {
        return try allocator.malloc<T>(cap);
    }
    return try allocator.realloc<T>(ptr, old, cap);
}

// append value (moved in), growing the memory when it's full
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn push(this: std::vec<T, A>&, value: T) -> std::mem::mem_error!void {
    if (this.len == this.cap) {
        try this.reserve(this.len + 1);
    }
    @write(&(@slice(this.ptr, this.cap)[this.len]), move value);
    this.len += 1;
}

// the last element, moved out
<T: type, A: std::mem::allocator>
public attach fn pop(this: std::vec<T, A>&) -> T? {
    if (this.len == 0) {
        return null;
    }
    this.len -= 1;
    return @read(&(@slice(this.ptr, this.cap)[this.len]));
}

// the first element, or null when empty
<T: type, A: std::mem::allocator>
public attach fn first(this: std::vec<T, A>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return this.ptr;
}

// the last element, or null when empty
<T: type, A: std::mem::allocator>
public attach fn last(this: std::vec<T, A>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return &(@slice(this.ptr, this.len)[this.len - 1]);
}

// put value at index i (0..=len), moving the elements from i on up by one
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn insert(this: std::vec<T, A>&, i: usize, value: T) -> std::mem::mem_error!void {
    if (i > this.len) {
        @panic("vec insert index out of range");
    }
    try this.reserve(this.len + 1);
    val xs = @slice(this.ptr, this.len + 1);
    var j = this.len;
    while (j > i) {
        @write(&xs[j], @read(&xs[j - 1]));
        j -= 1;
    }
    @write(&xs[i], move value);
    this.len += 1;
}

// take element i out, moving the ones after it down by one
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn remove(this: std::vec<T, A>&, i: usize) -> T {
    if (i >= this.len) {
        @panic("vec remove index out of range");
    }
    val xs = @slice(this.ptr, this.len);
    val out = @read(&xs[i]);
    for (j) in i + 1..this.len {
        @write(&xs[j - 1], @read(&xs[j]));
    }
    this.len -= 1;
    return out;
}

// take element i out and put the last element in its place: O(1), but changes the order
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn swap_remove(this: std::vec<T, A>&, i: usize) -> T {
    if (i >= this.len) {
        @panic("vec swap_remove index out of range");
    }
    val xs = @slice(this.ptr, this.len);
    val out = @read(&xs[i]);
    this.len -= 1;
    if (i != this.len) {
        @write(&xs[i], @read(&xs[this.len]));
    }
    return out;
}

// delete the elements from index n on (nothing when n >= len)
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn truncate(this: std::vec<T, A>&, n: usize) -> void {
    while (this.len > n) {
        this.pop();
    }
}

// n elements: copies of value added at the end, or the ones past n deleted. Filling is one plain
// loop, which the C compiler turns into a memset for bytes
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn resize(this: std::vec<T, A>&, n: usize, value: T) -> std::mem::mem_error!void {
    if (n <= this.len) {
        this.truncate(n);
        return;
    }
    try this.reserve(n);
    val xs = @slice(this.ptr, n);
    for (i) in this.len..n {
        @write(&xs[i], copy value);
    }
    this.len = n;
}

// append a copy of each element of xs
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn extend(this: std::vec<T, A>&, xs: T[..]) -> std::mem::mem_error!void {
    if (xs.len == 0) {
        return;
    }
    // xs can be part of this vec (v.extend(v.items())), and growing moves the buffer it's in: read
    // it from where it moved to
    val base = @cast<usize>(this.ptr);
    val src = @cast<usize>(xs.ptr);
    val inside = this.cap > 0 && src >= base && src < base + this.cap * @sizeof(T);
    try this.reserve(this.len + xs.len);
    var from = xs;
    if (inside) {
        from = @slice(@cast<T*>(@cast<usize>(this.ptr) + (src - base)), xs.len);
    }
    val to = @slice(this.ptr, this.cap);
    // numbers and bools copy bit for bit, all at once; anything else one copy at a time
    comptime match (@typeinfo(T).kind) {
        .INT(k) => {
            std::mem::c_memcpy(@cast<void*>(&to[this.len]), @cast<void*>(from.ptr), from.len * @sizeof(T));
        },
        .FLOAT(b) => {
            std::mem::c_memcpy(@cast<void*>(&to[this.len]), @cast<void*>(from.ptr), from.len * @sizeof(T));
        },
        .BOOL => {
            std::mem::c_memcpy(@cast<void*>(&to[this.len]), @cast<void*>(from.ptr), from.len * @sizeof(T));
        },
        default => {
            for (x&, i) in from {
                @write(&to[this.len + i], copy *x);
            }
        },
    }
    this.len += from.len;
}

// delete each element equal (by eq) to the one kept before it, so a run of equals keeps its first
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn dedup(this: std::vec<T, A>&) -> void {
    val xs = @slice(this.ptr, this.len);
    if (xs.len == 0) {
        return;
    }
    var w: usize = 1; // elements kept so far, at the front
    for (r) in 1..xs.len {
        if (xs[r].eq(&xs[w - 1])) {
            val dropped = @read(&xs[r]); // deleted here
        } else {
            if (r != w) {
                @write(&xs[w], @read(&xs[r]));
            }
            w += 1;
        }
    }
    this.len = w;
}

// delete the elements keep(&x) returns false for, keeping the others in order
<T: type, A: std::mem::allocator, F: type>
@attributes([@invalidates])
public attach fn retain(this: std::vec<T, A>&, keep: F) -> void {
    val xs = @slice(this.ptr, this.len);
    var w: usize = 0; // elements kept so far, at the front
    for (r) in 0..xs.len {
        if (keep(&xs[r])) {
            if (r != w) {
                @write(&xs[w], @read(&xs[r]));
            }
            w += 1;
        } else {
            val dropped = @read(&xs[r]); // deleted here
        }
    }
    this.len = w;
}

// delete every element, keep the memory
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn clear(this: std::vec<T, A>&) -> void {
    // last to first, as pops would; for elements that own nothing the loop does nothing and compiles
    // away (a loop of pops didn't)
    val xs = @slice(this.ptr, this.len);
    this.len = 0;
    var i = xs.len;
    while (i > 0) {
        i -= 1;
        val dropped = @read(&xs[i]); // deleted here
    }
}

// deletes the elements, then frees the memory
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn delete(this: std::vec<T, A>&) -> void {
    this.clear();
    if (this.cap > 0) {
        this.allocator.free<T>(this.ptr, this.cap);
    }
}

// a new vec holding a copy of each element, with a copy of the allocator
<T: type, A: std::mem::allocator>
public attach fn copy(this: std::vec<T, A>&) -> std::vec<T, A> {
    var out: std::vec<T, A> = { allocator: copy this.allocator };
    out.reserve(this.len) catch @panic("out of memory");
    for (x&) in @slice(this.ptr, this.len) {
        out.push(copy *x) catch @panic("out of memory");
    }
    return out;
}
