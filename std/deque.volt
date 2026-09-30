// std::deque: a double-ended queue (a ring buffer): push and pop at both ends in O(1).
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A double-ended queue that owns its elements. Nothing is allocated until the first push.
<T: type>
struct deque {
    ptr: T* = @cast<T*>(@alignof(T)); // cap slots; a non-null placeholder while cap is 0
    head: usize = 0;                  // the slot of the first element
    len: usize = 0;                   // the elements held
    cap: usize = 0;                   // the slots
}

// the slot of element i
<T: type>
internal attach fn slot(this: std::deque<T>&, i: usize) -> T& {
    return &(@slice(this.ptr, this.cap)[(this.head + i) % this.cap]);
}

// doubles the slots (at least 8), moving the elements to the front in order
<T: type>
internal attach fn grow(this: std::deque<T>&) -> void {
    var cap = this.cap * 2;
    if (cap < 8) {
        cap = 8;
    }
    val raw = std::mem::c_malloc(cap * @sizeof(T)) ?? @panic("out of memory");
    val fresh = @slice(@cast<T*>(raw), cap);
    for (i) in 0..this.len {
        @write(&fresh[i], @read(this.slot(i)));
    }
    if (this.cap > 0) {
        std::mem::c_free(this.ptr as void*);
    }
    this.ptr = @cast<T*>(raw);
    this.cap = cap;
    this.head = 0;
}

// element i from the front (panics when i >= len)
<T: type>
attach fn at(this: std::deque<T>&, i: usize) -> T& {
    if (i >= this.len) {
        @panic("deque index out of range");
    }
    return this.slot(i);
}

// the first element, or null when empty
<T: type>
attach fn front(this: std::deque<T>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return this.slot(0) as T*;
}

// the last element, or null when empty
<T: type>
attach fn back(this: std::deque<T>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return this.slot(this.len - 1) as T*;
}

// append value at the back
<T: type>
attach fn push_back(this: std::deque<T>&, value: T) -> void {
    if (this.len == this.cap) {
        this.grow();
    }
    @write(this.slot(this.len), move value);
    this.len += 1;
}

// put value at the front
<T: type>
attach fn push_front(this: std::deque<T>&, value: T) -> void {
    if (this.len == this.cap) {
        this.grow();
    }
    this.head = (this.head + this.cap - 1) % this.cap;
    @write(this.slot(0), move value);
    this.len += 1;
}

// the last element, moved out
<T: type>
attach fn pop_back(this: std::deque<T>&) -> T? {
    if (this.len == 0) {
        return null;
    }
    this.len -= 1;
    return @read(this.slot(this.len));
}

// the first element, moved out
<T: type>
attach fn pop_front(this: std::deque<T>&) -> T? {
    if (this.len == 0) {
        return null;
    }
    val out = @read(this.slot(0));
    this.head = (this.head + 1) % this.cap;
    this.len -= 1;
    return move out;
}

// delete every element, keep the memory
<T: type>
attach fn clear(this: std::deque<T>&) -> void {
    while (this.len > 0) {
        this.pop_back();
    }
}

// walks a deque front to back; changing the deque while walking isn't allowed
<T: type>
struct deque_iter {
    d: std::deque<T>*;
    i: usize = 0; // the next element
}

// for (x) in d.iter(): each element, as a reference
<T: type>
attach fn iter(this: std::deque<T>&) -> std::deque_iter<T> {
    return { d: this as std::deque<T>* };
}

// the next element
<T: type>
attach fn next(this: std::deque_iter<T>&) -> T* {
    if (this.i >= this.d->len) {
        return null;
    }
    this.i += 1;
    return this.d->slot(this.i - 1) as T*;
}

// a new deque holding a copy of each element
<T: type>
attach fn copy(this: std::deque<T>&) -> std::deque<T> {
    var out: std::deque<T> = {};
    for (i) in 0..this.len {
        out.push_back(copy *this.slot(i));
    }
    return move out;
}

// deletes the elements, then frees the memory
<T: type>
attach fn delete(this: std::deque<T>&) -> void {
    this.clear();
    if (this.cap > 0) {
        std::mem::c_free(this.ptr as void*);
    }
}
