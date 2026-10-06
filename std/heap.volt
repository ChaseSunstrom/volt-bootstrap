// std::heap: a priority queue (a binary heap): pop gives the smallest element by cmp.
// For largest first, store a type whose cmp is reversed.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A binary min-heap: push and pop in O(log n), peek in O(1).
<T: type, Allocator: std::mem::allocator = std::mem::default_allocator>
public struct heap {
    items: std::vec<T, Allocator> = {}; // items[i] sorts no earlier than items[(i - 1) / 2]
}

// an empty heap that allocates from allocator
<T: type, A: std::mem::allocator>
public attach fn new_in(static this: std::heap<T>, allocator: A) -> std::heap<T, A> {
    return { items: { allocator: move allocator } };
}

// room for n elements without growing
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn reserve(this: std::heap<T, A>&, n: usize) -> std::mem::mem_error!void {
    return this.items.reserve(n);
}

// how many elements it holds
<T: type, A: std::mem::allocator>
public attach fn len(this: std::heap<T, A>&) -> usize {
    return this.items.len;
}

// the smallest element, or null when empty
<T: type, A: std::mem::allocator>
public attach fn peek(this: std::heap<T, A>&) -> T* {
    return this.items.first();
}

// add value (unchecked: i starts at len - 1 and only goes to (i - 1) / 2, below it)
<T: type, A: std::mem::allocator>
@attributes([@invalidates, @unchecked])
public attach fn push(this: std::heap<T, A>&, value: T) -> void {
    this.items.push(move value) catch @panic("out of memory");
    val xs = this.items.items();
    var i = xs.len - 1;
    // the new element comes out, leaving a hole that moves up past each parent it sorts before
    // (moves, not swaps), then it goes into the hole
    val x = @read(&xs[i]);
    while (i > 0) {
        val up = (i - 1) / 2;
        if (x.cmp(&xs[up]) >= 0) {
            break;
        }
        @write(&xs[i], @read(&xs[up]));
        i = up;
    }
    @write(&xs[i], move x);
}

// the smallest element, moved out (unchecked: len > 0; a child is read only below len, and i is always
// 0 or a child read before)
<T: type, A: std::mem::allocator>
@attributes([@invalidates, @unchecked])
public attach fn pop(this: std::heap<T, A>&) -> T? {
    val last = this.items.pop() ?? return null;
    val xs = this.items.items();
    if (xs.len == 0) {
        return last;
    }
    // the root comes out, leaving a hole at the top; the old last element sinks from there, the
    // hole moving down past each smaller child (moves, not swaps)
    val out = @read(&xs[0]);
    var i: usize = 0;
    loop {
        val l = 2 * i + 1;
        if (l >= xs.len) {
            break;
        }
        var c = l;
        if (l + 1 < xs.len && xs[l + 1].cmp(&xs[l]) < 0) {
            c = l + 1;
        }
        if (xs[c].cmp(&last) >= 0) {
            break;
        }
        @write(&xs[i], @read(&xs[c]));
        i = c;
    }
    @write(&xs[i], move last);
    return out;
}

// delete every element
<T: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn clear(this: std::heap<T, A>&) -> void {
    this.items.clear();
}
