// std::vec: a growable array that owns its elements.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A growable array that owns its elements. Nothing is allocated until the first push.
<T: type, Allocator: std::mem::t_allocator = std::mem::default_allocator>
struct vec {
    ptr: T* = @cast<T*>(@alignof(T)); // a non-null placeholder while cap is 0
    len: usize = 0;            // the elements held
    cap: usize = 0;            // room for this many before it grows
    allocator: Allocator = {}; // where the memory comes from
}

// an empty vec that allocates from allocator
<T: type, A: std::mem::t_allocator>
attach fn new_in(static this: std::vec<T>, allocator: A) -> std::vec<T, A> {
    return { allocator: move allocator };
}

// the elements as a slice (valid until the vec changes)
<T: type, A: std::mem::t_allocator>
attach fn items(this: std::vec<T, A>&) -> T[..] {
    return @slice(this.ptr, this.len);
}

// element i (bounds-checked in debug builds)
<T: type, A: std::mem::t_allocator>
attach fn at(this: std::vec<T, A>&, i: usize) -> T& {
    return &(@slice(this.ptr, this.len)[i]);
}

// room for at least n elements
<T: type, A: std::mem::t_allocator>
attach fn reserve(this: std::vec<T, A>&, n: usize) -> std::mem::mem_error!void {
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
    if (this.cap == 0) {
        this.ptr = try this.allocator.malloc<T>(cap);
    } else {
        this.ptr = try this.allocator.realloc<T>(this.ptr, this.cap, cap);
    }
    this.cap = cap;
}

// append value (moved in), growing the memory when it's full
<T: type, A: std::mem::t_allocator>
attach fn push(this: std::vec<T, A>&, value: T) -> std::mem::mem_error!void {
    try this.reserve(this.len + 1);
    @write(&(@slice(this.ptr, this.cap)[this.len]), move value);
    this.len += 1;
}

// the last element, moved out
<T: type, A: std::mem::t_allocator>
attach fn pop(this: std::vec<T, A>&) -> T? {
    if (this.len == 0) {
        return null;
    }
    this.len -= 1;
    return @read(&(@slice(this.ptr, this.cap)[this.len]));
}

// the first element, or null when empty
<T: type, A: std::mem::t_allocator>
attach fn first(this: std::vec<T, A>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return this.ptr;
}

// the last element, or null when empty
<T: type, A: std::mem::t_allocator>
attach fn last(this: std::vec<T, A>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return &(@slice(this.ptr, this.len)[this.len - 1]);
}

// put value at index i (0..=len), moving the elements from i on up by one
<T: type, A: std::mem::t_allocator>
attach fn insert(this: std::vec<T, A>&, i: usize, value: T) -> std::mem::mem_error!void {
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
<T: type, A: std::mem::t_allocator>
attach fn remove(this: std::vec<T, A>&, i: usize) -> T {
    if (i >= this.len) {
        @panic("vec remove index out of range");
    }
    val xs = @slice(this.ptr, this.len);
    val out = @read(&xs[i]);
    for (j) in i + 1..this.len {
        @write(&xs[j - 1], @read(&xs[j]));
    }
    this.len -= 1;
    return move out;
}

// take element i out and put the last element in its place: O(1), but changes the order
<T: type, A: std::mem::t_allocator>
attach fn swap_remove(this: std::vec<T, A>&, i: usize) -> T {
    if (i >= this.len) {
        @panic("vec swap_remove index out of range");
    }
    val xs = @slice(this.ptr, this.len);
    val out = @read(&xs[i]);
    this.len -= 1;
    if (i != this.len) {
        @write(&xs[i], @read(&xs[this.len]));
    }
    return move out;
}

// delete the elements from index n on (nothing when n >= len)
<T: type, A: std::mem::t_allocator>
attach fn truncate(this: std::vec<T, A>&, n: usize) -> void {
    while (this.len > n) {
        this.pop();
    }
}

// append a copy of each element of xs
<T: type, A: std::mem::t_allocator>
attach fn extend(this: std::vec<T, A>&, xs: T[..]) -> std::mem::mem_error!void {
    try this.reserve(this.len + xs.len);
    for (x&) in xs {
        try this.push(copy *x);
    }
}

// delete each element equal (by eq) to the one kept before it, so a run of equals keeps its first
<T: type, A: std::mem::t_allocator>
attach fn dedup(this: std::vec<T, A>&) -> void {
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
<T: type, A: std::mem::t_allocator, F: type>
attach fn retain(this: std::vec<T, A>&, keep: F) -> void {
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
<T: type, A: std::mem::t_allocator>
attach fn clear(this: std::vec<T, A>&) -> void {
    while (this.len > 0) {
        this.pop();
    }
}

// deletes the elements, then frees the memory
<T: type, A: std::mem::t_allocator>
attach fn delete(this: std::vec<T, A>&) -> void {
    this.clear();
    if (this.cap > 0) {
        this.allocator.free<T>(this.ptr, this.cap);
    }
}

// a new vec holding a copy of each element, with a copy of the allocator
<T: type, A: std::mem::t_allocator>
attach fn copy(this: std::vec<T, A>&) -> std::vec<T, A> {
    var out: std::vec<T, A> = { allocator: copy this.allocator };
    out.reserve(this.len) catch @panic("out of memory");
    for (x&) in @slice(this.ptr, this.len) {
        out.push(copy *x) catch @panic("out of memory");
    }
    return move out;
}
