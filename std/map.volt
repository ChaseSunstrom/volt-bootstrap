// std::map: a hash map with open addressing. Keys need `hash(this: K&) -> u64` and eq (std::compare).
// (Part of package std: the package loader wraps every file in `namespace std`.)

// FNV-1a hashes for the built-in key types; a key type K needs `hash(this: K&) -> u64` and eq
attach fn hash(this: str&) -> u64 {
    var h: u64 = 14695981039346656037;
    for (b) in *this {
        h = (h ^ @cast<u64>(b)) *% 1099511628211;
    }
    return h;
}
// integers: their bits spread by map_mix
attach fn hash(this: i32&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
attach fn hash(this: i64&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
attach fn hash(this: u32&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
attach fn hash(this: u64&) -> u64 { return std::map_mix(*this); }
attach fn hash(this: usize&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
attach fn hash(this: u8&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
attach fn hash(this: i8&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
attach fn hash(this: i16&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
attach fn hash(this: u16&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
attach fn hash(this: isize&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
attach fn hash(this: bool&) -> u64 { return std::map_mix(@cast<u64>(*this)); }

// spreads the bits of an integer key (splitmix64's finalizer)
fn map_mix(x: u64) -> u64 {
    var z = x +% 11400714819323198485;
    z = (z ^ (z >> 30)) *% 13787848793156543929;
    z = (z ^ (z >> 27)) *% 10723151780598845931;
    return z ^ (z >> 31);
}

// A hash map with open addressing (linear probing, tombstones for removed keys).
<K: type, V: type>
struct map {
    // keys, vals and state are parallel arrays of cap slots; nothing is allocated until the first put
    keys: K* = @cast<K*>(@alignof(K));
    vals: V* = @cast<V*>(@alignof(V)); // the values, parallel to keys
    state: u8* = @cast<u8*>(1); // per slot: 0 empty, 1 full, 2 removed
    // len counts the keys held, cap the slots
    len: usize = 0;  // the keys held
    used: usize = 0; // full + removed
    cap: usize = 0;  // the slots
}

// the slot holding key, or where it would go
<K: type, V: type>
internal attach fn slot(this: std::map<K, V>&, key: K&) -> usize {
    val state = @slice(this.state, this.cap);
    val keys = @slice(this.keys, this.cap);
    var i = @cast<usize>(key.hash()) % this.cap;
    var free = this.cap; // first removed slot seen
    loop {
        if (state[i] == 0) {
            if (free < this.cap) {
                return free;
            }
            return i;
        }
        if (state[i] == 2) {
            if (free == this.cap) {
                free = i;
            }
        } else if (keys[i].eq(key)) {
            return i;
        }
        i = (i + 1) % this.cap;
    }
}

// doubles the slots (at least 8) and puts every entry back, dropping the removed markers
<K: type, V: type>
internal attach fn grow(this: std::map<K, V>&) -> void {
    val old_cap = this.cap;
    val (old_keys, old_vals, old_state) = (this.keys, this.vals, this.state);
    var cap = old_cap * 2;
    if (cap < 8) {
        cap = 8;
    }
    val k = std::mem::c_malloc(cap * @sizeof(K)) ?? @panic("out of memory");
    val v = std::mem::c_malloc(cap * @sizeof(V)) ?? @panic("out of memory");
    val s = std::mem::c_malloc(cap) ?? @panic("out of memory");
    this.keys = @cast<K*>(k);
    this.vals = @cast<V*>(v);
    this.state = @cast<u8*>(s);
    this.cap = cap;
    this.len = 0;
    this.used = 0;
    for (st&) in @slice(this.state, cap) {
        *st = 0;
    }
    if (old_cap == 0) {
        return;
    }
    // move every entry over
    for (i) in 0..old_cap {
        if (@slice(old_state, old_cap)[i] == 1) {
            val key = @read(&(@slice(old_keys, old_cap)[i]));
            val value = @read(&(@slice(old_vals, old_cap)[i]));
            this.put(move key, move value);
        }
    }
    std::mem::c_free(old_keys as void*);
    std::mem::c_free(old_vals as void*);
    std::mem::c_free(old_state as void*);
}

// set key to value (an old value for it is deleted)
<K: type, V: type>
attach fn put(this: std::map<K, V>&, key: K, value: V) -> void {
    // keep used slots under 3/4 (removed ones count), so a probe always reaches an empty slot
    if ((this.used + 1) * 4 > this.cap * 3) {
        this.grow();
    }
    val i = this.slot(&key);
    val state = @slice(this.state, this.cap);
    if (state[i] == 1) {
        @slice(this.vals, this.cap)[i] = move value; // deletes the old value; the old key stays
        return;
    }
    if (state[i] == 0) {
        this.used += 1;
    }
    state[i] = 1;
    this.len += 1;
    @write(&(@slice(this.keys, this.cap)[i]), move key);
    @write(&(@slice(this.vals, this.cap)[i]), move value);
}

// the value for key, if there is one
<K: type, V: type>
attach fn get(this: std::map<K, V>&, key: K) -> V* {
    return this.lookup(&key);
}

// get without taking the key
<K: type, V: type>
internal attach fn lookup(this: std::map<K, V>&, key: K&) -> V* {
    if (this.cap == 0) {
        return null;
    }
    val i = this.slot(key);
    if (@slice(this.state, this.cap)[i] != 1) {
        return null;
    }
    return &(@slice(this.vals, this.cap)[i]);
}

// whether key has a value
<K: type, V: type>
attach fn contains(this: std::map<K, V>&, key: K) -> bool {
    return this.lookup(&key) != null;
}

// take key's value out of the map
<K: type, V: type>
attach fn remove(this: std::map<K, V>&, key: K) -> V? {
    if (this.cap == 0) {
        return null;
    }
    val i = this.slot(&key);
    val state = @slice(this.state, this.cap);
    if (state[i] != 1) {
        return null;
    }
    state[i] = 2;
    this.len -= 1;
    val k = @read(&(@slice(this.keys, this.cap)[i])); // deleted here
    return @read(&(@slice(this.vals, this.cap)[i]));
}

// deletes every key and value, keeping the slots
<K: type, V: type>
attach fn clear(this: std::map<K, V>&) -> void {
    for (i) in 0..this.cap {
        val st = &(@slice(this.state, this.cap)[i]);
        if (*st == 1) {
            // moved out, so both are deleted at the end of this iteration
            val k = @read(&(@slice(this.keys, this.cap)[i]));
            val v = @read(&(@slice(this.vals, this.cap)[i]));
        }
        *st = 0;
    }
    this.len = 0;
    this.used = 0;
}

// a key and its value, as for (e) in m.iter() gives them (don't change the key: the map is
// ordered by it)
<K: type, V: type>
struct entry {
    key: K&;
    value: V&;
}

// walks a map's entries in no particular order; changing the map while walking isn't allowed
<K: type, V: type>
struct map_iter {
    keys: K*;
    vals: V*;
    state: u8*;
    cap: usize;
    i: usize = 0; // the next slot to look at
}

// for (e) in m.iter(): each entry, with e.value a reference into the map
<K: type, V: type>
attach fn iter(this: std::map<K, V>&) -> std::map_iter<K, V> {
    return { keys: this.keys, vals: this.vals, state: this.state, cap: this.cap };
}

// the next full slot's entry
<K: type, V: type>
attach fn next(this: std::map_iter<K, V>&) -> std::entry<K, V>? {
    while (this.i < this.cap) {
        val i = this.i;
        this.i += 1;
        if (@slice(this.state, this.cap)[i] == 1) {
            return { key: &(@slice(this.keys, this.cap)[i]), value: &(@slice(this.vals, this.cap)[i]) };
        }
    }
    return null;
}

// a deep copy: a new map holding a copy of every key and value
<K: type, V: type>
attach fn copy(this: std::map<K, V>&) -> std::map<K, V> {
    var out: std::map<K, V> = {};
    for (i) in 0..this.cap {
        if (@slice(this.state, this.cap)[i] == 1) {
            out.put(copy @slice(this.keys, this.cap)[i], copy @slice(this.vals, this.cap)[i]);
        }
    }
    return move out;
}

// deletes every key and value, then frees the arrays
<K: type, V: type>
attach fn delete(this: std::map<K, V>&) -> void {
    if (this.cap == 0) {
        return;
    }
    for (i) in 0..this.cap {
        if (@slice(this.state, this.cap)[i] == 1) {
            // moved out, so both are deleted at the end of this iteration
            val k = @read(&(@slice(this.keys, this.cap)[i]));
            val v = @read(&(@slice(this.vals, this.cap)[i]));
        }
    }
    std::mem::c_free(this.keys as void*);
    std::mem::c_free(this.vals as void*);
    std::mem::c_free(this.state as void*);
}
