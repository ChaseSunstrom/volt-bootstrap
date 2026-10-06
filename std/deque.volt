// std::deque: a double-ended queue (a ring buffer): push and pop at both ends in O(1).
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A double-ended queue that owns its elements. Nothing is allocated until the first push.
<T: type, Allocator: std::mem::allocator = std::mem::default_allocator>
public struct deque {
    ptr: T* = @cast<T*>(@alignof(T)); // cap slots; a non-null placeholder while cap is 0
    head: usize = 0;                  // the slot of the first element
    len: usize = 0;                   // the elements held
    cap: usize = 0;                   // the slots
    allocator: Allocator = {};        // where the slots come from
}

// an empty deque that allocates from allocator
<T: type, A: std::mem::allocator>
public attach fn new_in(static this: std::deque<T>, allocator: A) -> std::deque<T, A> {
    return { allocator: move allocator };
}

// the slot of element i
<T: type, A: std::mem::allocator>
attach fn slot(this: std::deque<T, A>&, i: usize) -> T& {
    return &(@slice(this.ptr, this.cap)[(this.head + i) % this.cap]);
}

// room for at least n elements: when it grows (to double, at least 8), the elements move to the
// front of the new slots in order
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn reserve(this: std::deque<T, A>&, n: usize) -> std::mem::mem_error!void {
    if (n <= this.cap) {
        return;
    }
    var cap = this.cap * 2;
    if (cap < n) {
        cap = n;
    }
    if (cap < 8) {
        cap = 8;
    }
    val fresh: T* = try this.allocator.malloc<T>(cap);
    val slots = @slice(fresh, cap);
    for (i) in 0..this.len {
        @write(&slots[i], @read(this.slot(i)));
    }
    if (this.cap > 0) {
        this.allocator.free<T>(this.ptr, this.cap);
    }
    this.ptr = fresh;
    this.cap = cap;
    this.head = 0;
}

// room for one more
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
attach fn grow(this: std::deque<T, A>&) -> void {
    this.reserve(this.len + 1) catch @panic("out of memory");
}

// element i from the front (panics when i >= len)
<T: type, A: std::mem::allocator>
public attach fn at(this: std::deque<T, A>&, i: usize) -> T& {
    if (i >= this.len) {
        @panic("deque index out of range");
    }
    return this.slot(i);
}

// the first element, or null when empty
<T: type, A: std::mem::allocator>
public attach fn front(this: std::deque<T, A>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return this.slot(0) as T*;
}

// the last element, or null when empty
<T: type, A: std::mem::allocator>
public attach fn back(this: std::deque<T, A>&) -> T* {
    if (this.len == 0) {
        return null;
    }
    return this.slot(this.len - 1) as T*;
}

// append value at the back
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn push_back(this: std::deque<T, A>&, value: T) -> void {
    if (this.len == this.cap) {
        this.grow();
    }
    @write(this.slot(this.len), move value);
    this.len += 1;
}

// put value at the front
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn push_front(this: std::deque<T, A>&, value: T) -> void {
    if (this.len == this.cap) {
        this.grow();
    }
    this.head = (this.head + this.cap - 1) % this.cap;
    @write(this.slot(0), move value);
    this.len += 1;
}

// the last element, moved out
<T: type, A: std::mem::allocator>
public attach fn pop_back(this: std::deque<T, A>&) -> T? {
    if (this.len == 0) {
        return null;
    }
    this.len -= 1;
    return @read(this.slot(this.len));
}

// the first element, moved out
<T: type, A: std::mem::allocator>
public attach fn pop_front(this: std::deque<T, A>&) -> T? {
    if (this.len == 0) {
        return null;
    }
    val out = @read(this.slot(0));
    this.head = (this.head + 1) % this.cap;
    this.len -= 1;
    return out;
}

// delete every element, keep the memory
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn clear(this: std::deque<T, A>&) -> void {
    while (this.len > 0) {
        this.pop_back();
    }
}

// walks a deque front to back; changing the deque while walking isn't allowed
<T: type, A: std::mem::allocator>
public struct deque_iter {
    d: std::deque<T, A>*;
    i: usize = 0; // the next element
}

// for (x) in d.iter(): each element, as a reference
<T: type, A: std::mem::allocator>
public attach fn iter(this: std::deque<T, A>&) -> std::deque_iter<T, A> {
    return { d: this as std::deque<T, A>* };
}

// the next element
<T: type, A: std::mem::allocator>
public attach fn next(this: std::deque_iter<T, A>&) -> T* {
    if (this.i >= this.d->len) {
        return null;
    }
    this.i += 1;
    return this.d->slot(this.i - 1) as T*;
}

// a new deque holding a copy of each element, with a copy of the allocator
<T: type, A: std::mem::allocator>
public attach fn copy(this: std::deque<T, A>&) -> std::deque<T, A> {
    var out: std::deque<T, A> = { allocator: copy this.allocator };
    for (i) in 0..this.len {
        out.push_back(copy *this.slot(i));
    }
    return out;
}

// deletes the elements, then frees the memory
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn delete(this: std::deque<T, A>&) -> void {
    this.clear();
    if (this.cap > 0) {
        this.allocator.free<T>(this.ptr, this.cap);
    }
}
