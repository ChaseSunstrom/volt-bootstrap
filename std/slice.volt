// std::slice: algorithms on any T[..]: sort, search, reverse, min and max.
// They order elements with cmp and match them with eq (see std::compare).
// (Part of package std: the package loader wraps every file in `namespace std`.)

// sorts in place, smallest first by cmp; stable (equal elements keep their order). Past 16 elements
// it takes scratch room for n elements from allocator. Integers sort by their bits (a radix sort, in
// a few passes over the elements, with no compares), the rest with a merge sort
<T: type, A: std::mem::allocator = std::mem::default_allocator>
public attach fn sort(this: T[..]&, allocator: A = {}) -> void {
    comptime match (@typeinfo(T).kind) {
        .INT(k) => {
            if (this.len >= 256) {
                std::radix_sort(*this, k.0, move allocator);
                return;
            }
        },
        default => {},
    }
    this.sort_by(|| (a: T&, b: T&) -> i32 { return a.cmp(b); }, move allocator);
}

// a stable LSD radix sort of integers, a byte at a time from the lowest; a signed type's top bit is
// flipped, so negatives come first. A pass where every element has the same byte is skipped
<T: type, A: std::mem::allocator>
fn radix_sort(xs: T[..], signed: bool, allocator: A) -> void {
    val n = xs.len;
    val scratch: T* = allocator.malloc<T>(n) catch @panic("out of memory");
    var src = xs;
    var dst = @slice(scratch, n);
    val bits = @sizeof(T) * 8;
    var flip: u64 = 0;
    if (signed) {
        flip = @cast<u64>(1) << @cast<u64>(bits - 1);
    }
    var count: usize[256];
    for (b) in 0..@sizeof(T) {
        val shift = @cast<u64>(b * 8);
        for (c&) in count {
            *c = 0;
        }
        for (x) in src {
            count[@cast<usize>(((@cast<u64>(x) ^ flip) >> shift) & 255)] += 1;
        }
        if (count[@cast<usize>(((@cast<u64>(src[0]) ^ flip) >> shift) & 255)] == n) {
            continue;
        }
        var at: usize = 0;
        for (c&) in count {
            val here = *c;
            *c = at;
            at += here;
        }
        for (x) in src {
            val d = @cast<usize>(((@cast<u64>(x) ^ flip) >> shift) & 255);
            dst[count[d]] = x;
            count[d] += 1;
        }
        val t = src;
        src = dst;
        dst = t;
    }
    if (src.ptr != xs.ptr) {
        for (k) in 0..n {
            xs[k] = src[k];
        }
    }
    allocator.free<T>(scratch, n);
}

// sorts in place by order(a, b) (negative: a goes first); stable
<T: type, F: type, A: std::mem::allocator = std::mem::default_allocator>
public attach fn sort_by(this: T[..]&, order: F, allocator: A = {}) -> void {
    val xs = *this;
    val n = xs.len;
    // insertion sort each run of 16, then merge runs pairwise, doubling their length
    val run: usize = 16;
    var lo: usize = 0;
    while (lo < n) {
        var hi = lo + run;
        if (hi > n) {
            hi = n;
        }
        for (i) in lo + 1..hi {
            val x = @read(&xs[i]);
            var j = i;
            while (j > lo && order(&x, &xs[j - 1]) < 0) {
                @write(&xs[j], @read(&xs[j - 1]));
                j -= 1;
            }
            @write(&xs[j], move x);
        }
        lo = hi;
    }
    if (n <= run) {
        return;
    }
    // merge runs pairwise, doubling their length, from xs into the scratch and back: each pass moves
    // every element once, and a last odd run moves over as it is
    val scratch: T* = allocator.malloc<T>(n) catch @panic("out of memory");
    var src = xs;
    var dst = @slice(scratch, n);
    var width = run;
    while (width < n) {
        var start: usize = 0;
        while (start < n) {
            var mid = start + width;
            if (mid > n) {
                mid = n;
            }
            var end = mid + width;
            if (end > n) {
                end = n;
            }
            var i = start;
            var j = mid;
            var k = start;
            while (i < mid && j < end) {
                // take from the right only when strictly smaller (that keeps it stable); picked
                // without a branch, since on unsorted input which side wins is a coin flip
                val right = order(&src[j], &src[i]) < 0;
                val from = if (right) &src[j] else &src[i];
                @write(&dst[k], @read(from));
                j += if (right) 1 else 0;
                i += if (right) 0 else 1;
                k += 1;
            }
            while (i < mid) {
                @write(&dst[k], @read(&src[i]));
                i += 1;
                k += 1;
            }
            while (j < end) {
                @write(&dst[k], @read(&src[j]));
                j += 1;
                k += 1;
            }
            start = end;
        }
        val t = src;
        src = dst;
        dst = t;
        width *= 2;
    }
    // the sorted elements are in src: when that's the scratch, they move back
    if (src.ptr != xs.ptr) {
        for (k) in 0..n {
            @write(&xs[k], @read(&src[k]));
        }
    }
    allocator.free<T>(scratch, n);
}

// whether every element sorts no earlier than the one before it
<T: type>
public attach fn is_sorted(this: T[..]&) -> bool {
    val xs = *this;
    for (i) in 1..xs.len {
        if (xs[i].cmp(&xs[i - 1]) < 0) {
            return false;
        }
    }
    return true;
}

// in a sorted slice: the first index whose element doesn't sort before x (len if none)
<T: type>
public attach fn lower_bound(this: T[..]&, x: T) -> usize {
    return this.bound(&x);
}

// in a sorted slice: an index holding x, if one does
<T: type>
public attach fn binary_search(this: T[..]&, x: T) -> usize? {
    val at = this.bound(&x);
    if (at < this.len && (*this)[at].cmp(&x) == 0) {
        return at;
    }
    return null;
}

// lower_bound without taking x
<T: type>
attach fn bound(this: T[..]&, x: T&) -> usize {
    val xs = *this;
    var lo: usize = 0;
    var hi = xs.len;
    while (lo < hi) {
        val mid = lo + (hi - lo) / 2;
        if (xs[mid].cmp(x) < 0) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

// swaps elements i and j
<T: type>
public attach fn swap(this: T[..]&, i: usize, j: usize) -> void {
    val xs = *this;
    val t = @read(&xs[i]);
    @write(&xs[i], @read(&xs[j]));
    @write(&xs[j], move t);
}

// reverses the order in place
<T: type>
public attach fn reverse(this: T[..]&) -> void {
    val n = this.len;
    for (i) in 0..n / 2 {
        this.swap(i, n - 1 - i);
    }
}

// the index of the first element equal to x (by eq), if any
<T: type>
public attach fn index_of(this: T[..]&, x: T) -> usize? {
    for (e&, i) in *this {
        if (e.eq(&x)) {
            return i;
        }
    }
    return null;
}

// whether an element equals x (by eq)
<T: type>
public attach fn contains(this: T[..]&, x: T) -> bool {
    return this.index_of(move x) != null;
}

// the smallest element by cmp (the first of equals), or null when empty
<T: type>
public attach fn min(this: T[..]&) -> T* {
    val xs = *this;
    if (xs.len == 0) {
        return null;
    }
    var best: usize = 0;
    for (i) in 1..xs.len {
        if (xs[i].cmp(&xs[best]) < 0) {
            best = i;
        }
    }
    return &xs[best];
}

// the largest element by cmp (the first of equals), or null when empty
<T: type>
public attach fn max(this: T[..]&) -> T* {
    val xs = *this;
    if (xs.len == 0) {
        return null;
    }
    var best: usize = 0;
    for (i) in 1..xs.len {
        if (xs[i].cmp(&xs[best]) > 0) {
            best = i;
        }
    }
    return &xs[best];
}
