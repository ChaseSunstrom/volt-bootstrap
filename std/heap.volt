// std::heap: a priority queue (a binary heap): pop gives the smallest element by cmp.
// For largest first, store a type whose cmp is reversed.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A binary min-heap: push and pop in O(log n), peek in O(1).
<T: type>
struct heap {
    items: std::vec<T> = {}; // items[i] sorts no earlier than items[(i - 1) / 2]
}

// how many elements it holds
<T: type>
attach fn len(this: std::heap<T>&) -> usize {
    return this.items.len;
}

// the smallest element, or null when empty
<T: type>
attach fn peek(this: std::heap<T>&) -> T* {
    return this.items.first();
}

// add value
<T: type>
attach fn push(this: std::heap<T>&, value: T) -> void {
    this.items.push(move value) catch @panic("out of memory");
    val xs = this.items.items();
    var i = xs.len - 1;
    // move it up while it sorts before its parent
    while (i > 0) {
        val up = (i - 1) / 2;
        if (xs[i].cmp(&xs[up]) >= 0) {
            break;
        }
        xs.swap(i, up);
        i = up;
    }
}

// the smallest element, moved out
<T: type>
attach fn pop(this: std::heap<T>&) -> T? {
    val n = this.items.len;
    if (n == 0) {
        return null;
    }
    this.items.items().swap(0, n - 1);
    val out = this.items.pop();
    val xs = this.items.items();
    var i: usize = 0;
    // move the new root down while a child sorts before it
    loop {
        var least = i;
        val l = 2 * i + 1;
        val r = l + 1;
        if (l < xs.len && xs[l].cmp(&xs[least]) < 0) {
            least = l;
        }
        if (r < xs.len && xs[r].cmp(&xs[least]) < 0) {
            least = r;
        }
        if (least == i) {
            break;
        }
        xs.swap(i, least);
        i = least;
    }
    return move out;
}

// delete every element
<T: type>
attach fn clear(this: std::heap<T>&) -> void {
    this.items.clear();
}
