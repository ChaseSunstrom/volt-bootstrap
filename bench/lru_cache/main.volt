// lru_cache: an LRU cache of 100000 int keys to owned strings under n skewed get/put operations
// (a miss puts the value); Volt keeps the nodes (a std::string value, prev/next and a bucket chain,
// as indexes) in a std::vec and finds them through a hand-written chained hash table, the same
// design as the C (a std::map from key to node index instead runs about 1.2x C: one more lookup)
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
    chain: usize; // the next node in the same bucket, 0 for none
}

struct lru {
    cap: usize;
    nodes: std::vec<node> = {};
    buckets: std::vec<usize> = {}; // the first node of each bucket's chain, 0 for none
    mask: usize = 0;
}

attach fn with_capacity(static this: lru, cap: usize) -> std::mem::mem_error!lru {
    var c: lru = { cap: cap };
    var nb: usize = 1;
    while (nb < cap * 2) {
        nb *= 2;
    }
    try c.buckets.resize(nb, 0);
    c.mask = nb - 1;
    try c.nodes.reserve(cap + 1);
    try c.nodes.push({ key: 0, value: {}, prev: 0, next: 0, chain: 0 });
    return c;
}

fn bucket(c: lru&, key: u64) -> usize {
    return @cast<usize>(std::map_mix(key)) & c.mask;
}

attach fn unlink(this: lru&, i: usize) -> void {
    val ns = this.nodes.items();
    val p = ns[i].prev;
    val n = ns[i].next;
    ns[p].next = n;
    ns[n].prev = p;
}

attach fn push_front(this: lru&, i: usize) -> void {
    val ns = this.nodes.items();
    val first = ns[0].next;
    ns[i].prev = 0;
    ns[i].next = first;
    ns[first].prev = i;
    ns[0].next = i;
}

attach fn find(this: lru&, key: u64) -> usize {
    val ns = this.nodes.items();
    var n = this.buckets.items()[bucket(this, key)];
    while (n != 0 && ns[n].key != key) {
        n = ns[n].chain;
    }
    return n;
}

attach fn get(this: lru&, key: u64) -> str? {
    val i = this.find(key);
    if (i == 0) {
        return null;
    }
    this.unlink(i);
    this.push_front(i);
    return this.nodes.items()[i].value.as_str();
}

attach fn put(this: lru&, key: u64, value: std::string) -> void {
    var i = this.find(key);
    if (i != 0) {
        this.nodes.items()[i].value = move value;
        this.unlink(i);
        this.push_front(i);
        return;
    }
    val bs = this.buckets.items();
    if (this.nodes.len - 1 == this.cap) {
        i = this.nodes.items()[0].prev;
        this.unlink(i);
        val ns = this.nodes.items();
        // take it off its bucket's chain
        var at = bucket(this, ns[i].key);
        if (bs[at] == i) {
            bs[at] = ns[i].chain;
        } else {
            var p = bs[at];
            while (ns[p].chain != i) {
                p = ns[p].chain;
            }
            ns[p].chain = ns[i].chain;
        }
        ns[i].key = key;
        ns[i].value = move value;
    } else {
        i = this.nodes.len;
        this.nodes.push({ key: key, value: move value, prev: 0, next: 0, chain: 0 }) catch @panic("out of memory");
    }
    val b = bucket(this, key);
    this.nodes.items()[i].chain = bs[b];
    bs[b] = i;
    this.push_front(i);
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
    std::println("{} hits, {} misses, {} total, {} cached", hits, misses, total, cache.nodes.len - 1);
}
