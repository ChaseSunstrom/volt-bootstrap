// std::set: a hash set. Elements need `hash(this: T&) -> u64` and eq, like map keys.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A hash set: each value at most once.
// ponytail: a map with a byte of unused value per slot; its own table if that byte matters
<T: type, Allocator: std::mem::t_allocator = std::mem::default_allocator>
struct set {
    m: std::map<T, u8, Allocator> = {};
}

// an empty set that allocates from allocator
<T: type, A: std::mem::t_allocator>
attach fn new_in(static this: std::set<T>, allocator: A) -> std::set<T, A> {
    return { m: { allocator: move allocator } };
}

// room for n values without growing
<T: type, A: std::mem::t_allocator>
attach fn reserve(this: std::set<T, A>&, n: usize) -> std::mem::mem_error!void {
    return this.m.reserve(n);
}

// add value; false when it was already there (then value is deleted)
<T: type, A: std::mem::t_allocator>
attach fn add(this: std::set<T, A>&, value: T) -> bool {
    if (this.m.lookup(&value) != null) {
        return false;
    }
    this.m.put(move value, 0);
    return true;
}

// whether value is in the set
<T: type, A: std::mem::t_allocator>
attach fn contains(this: std::set<T, A>&, value: T) -> bool {
    return this.m.lookup(&value) != null;
}

// take value out; false when it wasn't there
<T: type, A: std::mem::t_allocator>
attach fn remove(this: std::set<T, A>&, value: T) -> bool {
    return this.m.remove(move value) != null;
}

// how many values it holds
<T: type, A: std::mem::t_allocator>
attach fn len(this: std::set<T, A>&) -> usize {
    return this.m.len;
}

// delete every value
<T: type, A: std::mem::t_allocator>
attach fn clear(this: std::set<T, A>&) -> void {
    this.m.clear();
}

// walks a set's values in no particular order
<T: type>
struct set_iter {
    it: std::map_iter<T, u8>;
}

// for (x) in s.iter(): each value, as a reference (don't change it: the set is ordered by it)
<T: type, A: std::mem::t_allocator>
attach fn iter(this: std::set<T, A>&) -> std::set_iter<T> {
    return { it: this.m.iter() };
}

// the next value
<T: type>
attach fn next(this: std::set_iter<T>&) -> T* {
    val e = this.it.next() ?? return null;
    return e.key as T*;
}
