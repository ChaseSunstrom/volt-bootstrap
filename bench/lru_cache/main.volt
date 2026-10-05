// lru_cache: an LRU cache of 100000 int keys to owned strings under n skewed get/put operations
// (a miss puts the value); Volt uses std::map from key to node index, the nodes (a std::string value
// and prev/next indexes) living in a std::vec, where an evicted node's slot is reused
use std::io;
use std::text;

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

struct node {
    key: u64;
    value: std::string;
    prev: usize; // recency: nodes[0] is the sentinel, its next the most recent
    next: usize;
}

struct lru {
    cap: usize;
    nodes: std::vec<node> = {};
    index: std::map<u64, usize> = {};
}

attach fn with_capacity(static this: lru, cap: usize) -> std::mem::mem_error!lru {
    var c: lru = { cap: cap };
    try c.nodes.reserve(cap + 1);
    try c.index.reserve(cap);
    try c.nodes.push({ key: 0, value: {}, prev: 0, next: 0 });
    return c;
}

attach fn unlink(this: lru&, i: usize) -> void {
    val p = this.nodes.at(i).prev;
    val n = this.nodes.at(i).next;
    this.nodes.at(p).next = n;
    this.nodes.at(n).prev = p;
}

attach fn push_front(this: lru&, i: usize) -> void {
    val first = this.nodes.at(0).next;
    this.nodes.at(i).prev = 0;
    this.nodes.at(i).next = first;
    this.nodes.at(first).prev = i;
    this.nodes.at(0).next = i;
}

// the value for key (marked most recent), or null
attach fn get(this: lru&, key: u64) -> str? {
    val i = *(this.index.get(key) ?? return null);
    this.unlink(i);
    this.push_front(i);
    return this.nodes.at(i).value.as_str();
}

// set key to value, evicting the least recent key when full
attach fn put(this: lru&, key: u64, value: std::string) -> void {
    // (if (val slot = ...) here makes the move checker think value is moved below: see the report)
    val slot = this.index.get(key);
    if (slot) {
        val i = *slot;
        this.nodes.at(i).value = move value;
        this.unlink(i);
        this.push_front(i);
        return;
    }
    var i = this.nodes.len;
    if (this.nodes.len - 1 == this.cap) {
        i = this.nodes.at(0).prev;
        this.unlink(i);
        val gone = this.index.remove(this.nodes.at(i).key);
        this.nodes.at(i).key = key;
        this.nodes.at(i).value = move value;
    } else {
        this.nodes.push({ key: key, value: move value, prev: 0, next: 0 }) catch @panic("out of memory");
    }
    this.push_front(i);
    this.index.put(key, i);
}

val PATTERN: str = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop";

// the value stored for key at step i: 8 to 32 letters
fn make_value(key: u64, i: i64) -> std::string {
    val at = @cast<usize>(key % 26);
    return std::string::from(PATTERN[at..at + @cast<usize>(8 + (key + @cast<u64>(i)) % 25)]);
}

fn main() -> !void {
    val n = (std::process::arg(1) ?? "20000000").parse_int() catch 20000000;
    var cache = try lru::with_capacity(100000);
    var hits: i64 = 0;
    var misses: i64 = 0;
    var total: i64 = 0;
    for (i) in 0..n {
        val r = next();
        // three in four keys come from a hot set a little bigger than the cache
        var key = next();
        if (r % 4 != 0) {
            key = key % 120000;
        } else {
            key = key % 1000000;
        }
        if ((r >> 8) % 10 == 0) {
            cache.put(key, make_value(key, i));
            continue;
        }
        if (val v = cache.get(key)) {
            hits += 1;
            total += @cast<i64>(v.len);
        } else {
            misses += 1;
            cache.put(key, make_value(key, i));
        }
    }
    std::println("{} hits, {} misses, {} total, {} cached", hits, misses, total, cache.index.len);
}
