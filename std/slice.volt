// std::slice: algorithms on any T[..]: sort, search, reverse, min and max.
// They order elements with cmp and match them with eq (see std::compare).
// (Part of package std: the package loader wraps every file in `namespace std`.)

// sorts in place, smallest first by cmp; stable (equal elements keep their order)
<T: type>
attach fn sort(this: T[..]&) -> void {
    this.sort_by(|| (a: T&, b: T&) -> i32 { return a.cmp(b); });
}

// sorts in place by order(a, b) (negative: a goes first); stable
<T: type, F: type>
attach fn sort_by(this: T[..]&, order: F) -> void {
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
    // scratch for the left run of each merge
    val raw = std::mem::c_malloc(n * @sizeof(T)) ?? @panic("out of memory");
    val buf = @slice(@cast<T*>(raw), n);
    var width = run;
    while (width < n) {
        var start: usize = 0;
        while (start + width < n) {
            val mid = start + width;
            var end = mid + width;
            if (end > n) {
                end = n;
            }
            // left run out to buf, then merge buf and the right run back into xs
            for (k) in start..mid {
                @write(&buf[k - start], @read(&xs[k]));
            }
            var i: usize = 0;
            val left = mid - start;
            var j = mid;
            var k = start;
            while (i < left && j < end) {
                // take from the right only when strictly smaller: that keeps it stable
                if (order(&xs[j], &buf[i]) < 0) {
                    @write(&xs[k], @read(&xs[j]));
                    j += 1;
                } else {
                    @write(&xs[k], @read(&buf[i]));
                    i += 1;
                }
                k += 1;
            }
            while (i < left) {
                @write(&xs[k], @read(&buf[i]));
                i += 1;
                k += 1;
            }
            start = end;
        }
        width *= 2;
    }
    std::mem::c_free(raw);
}

// whether every element sorts no earlier than the one before it
<T: type>
attach fn is_sorted(this: T[..]&) -> bool {
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
attach fn lower_bound(this: T[..]&, x: T) -> usize {
    return this.bound(&x);
}

// in a sorted slice: an index holding x, if one does
<T: type>
attach fn binary_search(this: T[..]&, x: T) -> usize? {
    val at = this.bound(&x);
    if (at < this.len && (*this)[at].cmp(&x) == 0) {
        return at;
    }
    return null;
}

// lower_bound without taking x
<T: type>
internal attach fn bound(this: T[..]&, x: T&) -> usize {
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
attach fn swap(this: T[..]&, i: usize, j: usize) -> void {
    val xs = *this;
    val t = @read(&xs[i]);
    @write(&xs[i], @read(&xs[j]));
    @write(&xs[j], move t);
}

// reverses the order in place
<T: type>
attach fn reverse(this: T[..]&) -> void {
    val n = this.len;
    for (i) in 0..n / 2 {
        this.swap(i, n - 1 - i);
    }
}

// the index of the first element equal to x (by eq), if any
<T: type>
attach fn index_of(this: T[..]&, x: T) -> usize? {
    for (e&, i) in *this {
        if (e.eq(&x)) {
            return i;
        }
    }
    return null;
}

// whether an element equals x (by eq)
<T: type>
attach fn contains(this: T[..]&, x: T) -> bool {
    return this.index_of(move x) != null;
}

// the smallest element by cmp (the first of equals), or null when empty
<T: type>
attach fn min(this: T[..]&) -> T* {
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
attach fn max(this: T[..]&) -> T* {
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
