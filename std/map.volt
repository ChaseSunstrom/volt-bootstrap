// std::map: a hash map with open addressing. Keys need `hash(this: K&) -> u64` and eq (std::compare).
// (Part of package std: the package loader wraps every file in `namespace std`.)

// FNV-1a hashes for the built-in key types; a key type K needs `hash(this: K&) -> u64` and eq
public attach fn hash(this: str&) -> u64 {
    var h: u64 = 14695981039346656037;
    for (b) in *this {
        h = (h ^ @cast<u64>(b)) *% 1099511628211;
    }
    return h;
}
// integers: their bits spread by map_mix
public attach fn hash(this: i32&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
public attach fn hash(this: i64&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
public attach fn hash(this: u32&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
public attach fn hash(this: u64&) -> u64 { return std::map_mix(*this); }
public attach fn hash(this: usize&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
public attach fn hash(this: u8&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
public attach fn hash(this: i8&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
public attach fn hash(this: i16&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
public attach fn hash(this: u16&) -> u64 { return std::map_mix(@cast<u64>(*this)); }
public attach fn hash(this: isize&) -> u64 { return std::map_mix(@cast<u64>(@cast<i64>(*this))); }
public attach fn hash(this: bool&) -> u64 { return std::map_mix(@cast<u64>(*this)); }

// spreads the bits of an integer key (splitmix64's finalizer)
public fn map_mix(x: u64) -> u64 {
    var z = x +% 11400714819323198485;
    z = (z ^ (z >> 30)) *% 13787848793156543929;
    z = (z ^ (z >> 27)) *% 10723151780598845931;
    return z ^ (z >> 31);
}

// A hash map with open addressing: linear probing, and a removal shifts the entries after it back
// into the gap, so there are no removed markers and a probe stops at the first empty slot.
<K: type, V: type, Allocator: std::mem::allocator = std::mem::default_allocator>
public struct map {
    // slots and state are parallel arrays of cap slots; nothing is allocated until the first put. A key
    // and its value share a slot, so a hit reads one place
    slots: std::map_slot<K, V>* = @cast<std::map_slot<K, V>*>(@alignof(std::map_slot<K, V>));
    // per slot: 0 empty, else its key's tag (map_tag), so most probes that miss compare a byte
    // instead of the key
    state: u8* = @cast<u8*>(1);
    len: usize = 0; // the keys held
    cap: usize = 0; // the slots: 0, or a power of two (8, then doubling)
    allocator: Allocator = {}; // where the arrays come from
}

// one slot of a map: a key and its value, side by side
<K: type, V: type>
struct map_slot {
    key: K;
    value: V;
}

// a full slot's state byte for a key hashing to h: its top 7 bits, with 0x80 set so it's never 0
fn map_tag(h: u64) -> u8 {
    return @cast<u8>((h >> 57) | 0x80);
}

// an empty map that allocates from allocator
<K: type, V: type, A: std::mem::allocator>
public attach fn new_in(static this: std::map<K, V>, allocator: A) -> std::map<K, V, A> {
    return { allocator: move allocator };
}

// the slot holding key (which hashes to h), or the empty slot where it would go
<K: type, V: type, A: std::mem::allocator>
attach fn slot(this: std::map<K, V, A>&, key: K&, h: u64) -> usize {
    val state = @slice(this.state, this.cap);
    val slots = @slice(this.slots, this.cap);
    val mask = this.cap - 1; // cap is a power of two: 8, then doubling
    val tag = std::map_tag(h);
    var i = @cast<usize>(h) & mask;
    loop {
        val s = state[i];
        if (s == 0 || (s == tag && slots[i].key.eq(key))) {
            return i;
        }
        i = (i + 1) & mask;
    }
}

// room for n keys without growing: the slots double (at least 8) until n fit under 3/4 of them
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn reserve(this: std::map<K, V, A>&, n: usize) -> std::mem::mem_error!void {
    if (n * 4 <= this.cap * 3) {
        return;
    }
    var cap = this.cap * 2;
    if (cap < 8) {
        cap = 8;
    }
    while (n * 4 > cap * 3) {
        cap *= 2;
    }
    try this.rehash(cap);
}

// doubles the slots (at least 8), for one more key
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
attach fn grow(this: std::map<K, V, A>&) -> void {
    var cap = this.cap * 2;
    if (cap < 8) {
        cap = 8;
    }
    this.rehash(cap) catch @panic("out of memory");
}

// cap new slots, with every entry put back
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
attach fn rehash(this: std::map<K, V, A>&, cap: usize) -> std::mem::mem_error!void {
    val old_cap = this.cap;
    val (old_slots, old_state) = (this.slots, this.state);
    val e: std::map_slot<K, V>* = try this.allocator.malloc<std::map_slot<K, V>>(cap);
    val s: u8* = this.allocator.malloc<u8>(cap) catch |err| {
        this.allocator.free<std::map_slot<K, V>>(e, cap);
        return std::mem::mem_error::OUT_OF_MEMORY;
    };
    this.slots = e;
    this.state = s;
    this.cap = cap;
    this.len = 0;
    for (st&) in @slice(this.state, cap) {
        *st = 0;
    }
    if (old_cap == 0) {
        return;
    }
    // move every entry over
    for (i) in 0..old_cap {
        if (@slice(old_state, old_cap)[i] != 0) {
            val old = &(@slice(old_slots, old_cap)[i]);
            val key = @read(&old.key);
            val value = @read(&old.value);
            this.put(move key, move value);
        }
    }
    this.allocator.free<std::map_slot<K, V>>(old_slots, old_cap);
    this.allocator.free<u8>(old_state, old_cap);
}

// set key to value (an old value for it is deleted)
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn put(this: std::map<K, V, A>&, key: K, value: V) -> void {
    // keep the keys under 3/4 of the slots, so a probe soon reaches an empty slot
    if ((this.len + 1) * 4 > this.cap * 3) {
        this.grow();
    }
    val h = key.hash();
    val i = this.slot(&key, h);
    val state = @slice(this.state, this.cap);
    if (state[i] != 0) {
        @slice(this.slots, this.cap)[i].value = move value; // deletes the old value; the old key stays
        return;
    }
    state[i] = std::map_tag(h);
    this.len += 1;
    val at = &(@slice(this.slots, this.cap)[i]);
    @write(&at.key, move key);
    @write(&at.value, move value);
}

// the value for key, if there is one
<K: type, V: type, A: std::mem::allocator>
public attach fn get(this: std::map<K, V, A>&, key: K) -> V* {
    return this.lookup(&key);
}

// get without taking the key
<K: type, V: type, A: std::mem::allocator>
attach fn lookup(this: std::map<K, V, A>&, key: K&) -> V* {
    if (this.cap == 0) {
        return null;
    }
    val i = this.slot(key, key.hash());
    if (@slice(this.state, this.cap)[i] == 0) {
        return null;
    }
    return &(@slice(this.slots, this.cap)[i].value);
}

// whether key has a value
<K: type, V: type, A: std::mem::allocator>
public attach fn contains(this: std::map<K, V, A>&, key: K) -> bool {
    return this.lookup(&key) != null;
}

// take key's value out of the map
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn remove(this: std::map<K, V, A>&, key: K) -> V? {
    if (this.cap == 0) {
        return null;
    }
    val i = this.slot(&key, key.hash());
    val state = @slice(this.state, this.cap);
    if (state[i] == 0) {
        return null;
    }
    val slots = @slice(this.slots, this.cap);
    val k = @read(&slots[i].key); // deleted here
    val out = @read(&slots[i].value);
    this.len -= 1;
    // close the gap: an entry after it moves back into the gap when the gap lies between the
    // entry's home slot and where it sits, so every key stays reachable from its home
    val mask = this.cap - 1;
    var gap = i;
    var j = (i + 1) & mask;
    while (state[j] != 0) {
        val home = @cast<usize>(slots[j].key.hash()) & mask;
        if (((j -% home) & mask) >= ((j -% gap) & mask)) {
            state[gap] = state[j];
            @write(&slots[gap], @read(&slots[j]));
            gap = j;
        }
        j = (j + 1) & mask;
    }
    state[gap] = 0;
    return out;
}

// deletes every key and value, keeping the slots
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn clear(this: std::map<K, V, A>&) -> void {
    for (i) in 0..this.cap {
        val st = &(@slice(this.state, this.cap)[i]);
        if (*st != 0) {
            // moved out, so both are deleted at the end of this iteration
            val at = &(@slice(this.slots, this.cap)[i]);
            val k = @read(&at.key);
            val v = @read(&at.value);
        }
        *st = 0;
    }
    this.len = 0;
}

// a key and its value, as for (e) in m.iter() gives them (don't change the key: the map is
// ordered by it)
<K: type, V: type>
public struct entry {
    key: K&;
    value: V&;
}

// walks a map's entries in no particular order; changing the map while walking isn't allowed
<K: type, V: type>
public struct map_iter {
    slots: std::map_slot<K, V>*;
    state: u8*;
    cap: usize;
    i: usize = 0; // the next slot to look at
}

// for (e) in m.iter(): each entry, with e.value a reference into the map
<K: type, V: type, A: std::mem::allocator>
public attach fn iter(this: std::map<K, V, A>&) -> std::map_iter<K, V> {
    return { slots: this.slots, state: this.state, cap: this.cap };
}

// the next full slot's entry
<K: type, V: type>
public attach fn next(this: std::map_iter<K, V>&) -> std::entry<K, V>? {
    while (this.i < this.cap) {
        val i = this.i;
        this.i += 1;
        if (@slice(this.state, this.cap)[i] != 0) {
            val at = &(@slice(this.slots, this.cap)[i]);
            return { key: &at.key, value: &at.value };
        }
    }
    return null;
}

// a deep copy: a new map holding a copy of every key and value
<K: type, V: type, A: std::mem::allocator>
public attach fn copy(this: std::map<K, V, A>&) -> std::map<K, V, A> {
    var out: std::map<K, V, A> = { allocator: copy this.allocator };
    for (i) in 0..this.cap {
        if (@slice(this.state, this.cap)[i] != 0) {
            val at = &(@slice(this.slots, this.cap)[i]);
            out.put(copy at.key, copy at.value);
        }
    }
    return out;
}

// deletes every key and value, then frees the arrays
<K: type, V: type, A: std::mem::allocator>
@attributes([@invalidates])
public attach fn delete(this: std::map<K, V, A>&) -> void {
    if (this.cap == 0) {
        return;
    }
    for (i) in 0..this.cap {
        if (@slice(this.state, this.cap)[i] != 0) {
            // moved out, so both are deleted at the end of this iteration
            val at = &(@slice(this.slots, this.cap)[i]);
            val k = @read(&at.key);
            val v = @read(&at.value);
        }
    }
    this.allocator.free<std::map_slot<K, V>>(this.slots, this.cap);
    this.allocator.free<u8>(this.state, this.cap);
}
