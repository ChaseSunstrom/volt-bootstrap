// std::set: a hash set. Elements need `hash(this: T&) -> u64` and eq, like map keys.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A hash set: each value at most once.
// ponytail: a map with a byte of unused value per slot; its own table if that byte matters
<T: type>
struct set {
    m: std::map<T, u8> = {};
}

// add value; false when it was already there (then value is deleted)
<T: type>
attach fn add(this: std::set<T>&, value: T) -> bool {
    if (this.m.lookup(&value) != null) {
        return false;
    }
    this.m.put(move value, 0);
    return true;
}

// whether value is in the set
<T: type>
attach fn contains(this: std::set<T>&, value: T) -> bool {
    return this.m.lookup(&value) != null;
}

// take value out; false when it wasn't there
<T: type>
attach fn remove(this: std::set<T>&, value: T) -> bool {
    return this.m.remove(move value) != null;
}

// how many values it holds
<T: type>
attach fn len(this: std::set<T>&) -> usize {
    return this.m.len;
}

// delete every value
<T: type>
attach fn clear(this: std::set<T>&) -> void {
    this.m.clear();
}

// walks a set's values in no particular order
<T: type>
struct set_iter {
    it: std::map_iter<T, u8>;
}

// for (x) in s.iter(): each value, as a reference (don't change it: the set is ordered by it)
<T: type>
attach fn iter(this: std::set<T>&) -> std::set_iter<T> {
    return { it: this.m.iter() };
}

// the next value
<T: type>
attach fn next(this: std::set_iter<T>&) -> T* {
    val e = this.it.next() ?? return null;
    return e.key as T*;
}
