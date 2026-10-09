// std::sorted_map: a map kept in key order (by cmp), so it walks its entries sorted.
// (Part of package std: the package loader wraps every file in `namespace std`.)

// A map ordered by key. Lookups are a binary search.
// ponytail: sorted arrays, so put and remove move the entries after the key (O(n));
// a B-tree if maps with many thousands of keys change often
<K: type, V: type, Allocator: std::mem::allocator = std::mem::default_allocator>
public struct sorted_map {
    keys: std::vec<K, Allocator> = {}; // sorted by cmp
    vals: std::vec<V, Allocator> = {}; // vals[i] is keys[i]'s value
}

// an empty sorted_map that allocates from allocator
<K: type, V: type, A: std::mem::allocator>
public attach fn new_in(static this: std::sorted_map<K, V>, allocator: A) -> std::sorted_map<K, V, A> {
    return { keys: { allocator: copy allocator }, vals: { allocator: move allocator } };
}

// room for n keys without growing
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn reserve(this: std::sorted_map<K, V, A>&, n: usize) -> std::mem::mem_error!void {
    try this.keys.reserve(n);
    return this.vals.reserve(n);
}

// how many keys it holds
<K: type, V: type, A: std::mem::allocator>
public attach fn len(this: std::sorted_map<K, V, A>&) -> usize {
    return this.keys.len;
}

// the index of key, or where it would go
<K: type, V: type, A: std::mem::allocator>
attach fn place(this: std::sorted_map<K, V, A>&, key: K&) -> (bool, usize) {
    val keys = this.keys.items();
    val at = keys.bound(key);
    return (at < keys.len && keys[at].cmp(key) == 0, at);
}

// set key to value (an old value for it is deleted)
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn put(this: std::sorted_map<K, V, A>&, key: K, value: V) -> void {
    val (found, at) = this.place(&key);
    if (found) {
        this.vals[at] = move value;
        return;
    }
    this.keys.insert(at, move key) catch @panic("out of memory");
    this.vals.insert(at, move value) catch @panic("out of memory");
}

// the value for key, if there is one
<K: type, V: type, A: std::mem::allocator>
public attach fn get(this: std::sorted_map<K, V, A>&, key: K) -> V* {
    val (found, at) = this.place(&key);
    if (!found) {
        return null;
    }
    return &this.vals[at];
}

// whether key has a value
<K: type, V: type, A: std::mem::allocator>
public attach fn contains(this: std::sorted_map<K, V, A>&, key: K) -> bool {
    val (found, at) = this.place(&key);
    return found;
}

// take key's value out of the map
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn remove(this: std::sorted_map<K, V, A>&, key: K) -> V? {
    val (found, at) = this.place(&key);
    if (!found) {
        return null;
    }
    val k = this.keys.remove(at); // deleted here
    return this.vals.remove(at);
}

// delete every key and value
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn clear(this: std::sorted_map<K, V, A>&) -> void {
    this.keys.clear();
    this.vals.clear();
}

// walks a sorted_map's entries in key order
<K: type, V: type>
public struct sorted_map_iter {
    keys: K[..];
    vals: V[..];
    i: usize = 0; // the next entry
}

// for (e) in m.iter(): each entry in key order, with e.value a reference into the map
<K: type, V: type, A: std::mem::allocator>
public attach fn iter(this: std::sorted_map<K, V, A>&) -> std::sorted_map_iter<K, V> {
    return { keys: this.keys.items(), vals: this.vals.items() };
}

// the next entry
<K: type, V: type>
public attach fn next(this: std::sorted_map_iter<K, V>&) -> std::entry<K, V>? {
    if (this.i >= this.keys.len) {
        return null;
    }
    this.i += 1;
    return { key: &this.keys[this.i - 1], value: &this.vals[this.i - 1] };
}
