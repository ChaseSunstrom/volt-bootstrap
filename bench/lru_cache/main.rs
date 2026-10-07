// lru_cache: an LRU cache of 100000 int keys to owned strings under n skewed get/put operations
// (a miss puts the value); Rust keeps the nodes in a Vec linked by index into a recency list,
// found through a std HashMap from key to index, with String values
use std::collections::HashMap;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

struct Node {
    key: u64,
    val: String,
    prev: usize, // recency: nodes[0] is the sentinel, and its next is the most recent
    next: usize,
}

struct Lru {
    nodes: Vec<Node>,
    index: HashMap<u64, usize>,
    cap: usize,
}

impl Lru {
    fn new(cap: usize) -> Self {
        let mut nodes = Vec::with_capacity(cap + 1);
        nodes.push(Node { key: 0, val: String::new(), prev: 0, next: 0 });
        Lru { nodes, index: HashMap::with_capacity(cap), cap }
    }

    fn len(&self) -> usize {
        self.index.len()
    }

    fn unlink(&mut self, i: usize) {
        let (prev, next) = (self.nodes[i].prev, self.nodes[i].next);
        self.nodes[prev].next = next;
        self.nodes[next].prev = prev;
    }

    fn push_front(&mut self, i: usize) {
        let first = self.nodes[0].next;
        self.nodes[i].prev = 0;
        self.nodes[i].next = first;
        self.nodes[first].prev = i;
        self.nodes[0].next = i;
    }

    // the value for key (marked most recent), or None
    fn get(&mut self, key: u64) -> Option<&str> {
        let i = *self.index.get(&key)?;
        self.unlink(i);
        self.push_front(i);
        Some(&self.nodes[i].val)
    }

    // set key to val, evicting the least recent key when full
    fn put(&mut self, key: u64, val: String) {
        if let Some(&i) = self.index.get(&key) {
            self.nodes[i].val = val;
            self.unlink(i);
            self.push_front(i);
            return;
        }
        let i = if self.index.len() == self.cap {
            // the least recent node takes the new key
            let old = self.nodes[0].prev;
            self.unlink(old);
            self.index.remove(&self.nodes[old].key);
            self.nodes[old].key = key;
            self.nodes[old].val = val;
            old
        } else {
            self.nodes.push(Node { key, val, prev: 0, next: 0 });
            self.nodes.len() - 1
        };
        self.index.insert(key, i);
        self.push_front(i);
    }
}

const PATTERN: &str = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop";

// the value stored for key at step i: 8 to 32 letters
fn make_value(key: u64, i: u64) -> String {
    let start = (key % 26) as usize;
    PATTERN[start..start + (8 + (key + i) % 25) as usize].to_string()
}

fn main() {
    let n: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(20000000);
    let mut rng = Rng(88172645463325252);
    let mut cache = Lru::new(100000);
    let (mut hits, mut misses, mut total) = (0u64, 0u64, 0usize);
    for i in 0..n {
        let r = rng.next();
        // three in four keys come from a hot set a little bigger than the cache
        let key = if r % 4 != 0 { rng.next() % 120000 } else { rng.next() % 1000000 };
        if (r >> 8) % 10 == 0 {
            cache.put(key, make_value(key, i));
            continue;
        }
        if let Some(len) = cache.get(key).map(str::len) {
            hits += 1;
            total += len;
        } else {
            misses += 1;
            cache.put(key, make_value(key, i));
        }
    }
    println!("{hits} hits, {misses} misses, {total} total, {} cached", cache.len());
}
