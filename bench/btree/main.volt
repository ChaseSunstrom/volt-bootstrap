// btree: an ordered map from u64 to u64 under random inserts (some overwriting), lookups (two in five
// of them hits) and range scans of 100 entries from a random key; prints the size, the hits and a
// checksum of what the lookups and scans saw. Volt's B-tree is a generic struct over its key and
// value types (31 keys a node, splitting full nodes on the way down), its nodes in a std::vec linked
// by index; get returns an optional, and a scan calls a closure
use std::io;
use std::text;

val MAX: usize = 31; // keys in a node; a full one splits into two of 15 around its middle key
val HALF: usize = 15;

<K: type, V: type>
struct bnode {
    n: usize = 0;
    leaf: bool = true;
    keys: K[31] = {};
    vals: V[31] = {};
    kids: u32[32] = {};
}

// the first key in x not below k
<K: type, V: type>
fn lower(x: bnode<K, V>&, k: K) -> usize {
    var i: usize = 0;
    while (i < x.n && x.keys[i] < k) {
        i += 1;
    }
    return i;
}

<K: type, V: type>
struct btree {
    nodes: std::vec<bnode<K, V>> = {};
    root: u32 = 0;
    len: usize = 0;
}

// node xi's kid i is full: its upper half moves to a new node after it, and its middle key up into xi
<K: type, V: type>
attach fn split_child(this: btree<K, V>&, xi: u32, i: usize) -> !void {
    val yi = this.nodes.at(@cast<usize>(xi)).kids[i];
    val zi = @cast<u32>(this.nodes.len);
    try this.nodes.push({ leaf: this.nodes.at(@cast<usize>(yi)).leaf });
    val ns = this.nodes.items();
    val x = &ns[@cast<usize>(xi)];
    val y = &ns[@cast<usize>(yi)];
    val z = &ns[@cast<usize>(zi)];
    for (j) in 0..HALF {
        z.keys[j] = y.keys[j + HALF + 1];
        z.vals[j] = y.vals[j + HALF + 1];
    }
    if (!y.leaf) {
        for (j) in 0..HALF + 1 {
            z.kids[j] = y.kids[j + HALF + 1];
        }
    }
    z.n = HALF;
    y.n = HALF;
    var j = x.n;
    while (j > i) {
        x.kids[j + 1] = x.kids[j];
        x.keys[j] = x.keys[j - 1];
        x.vals[j] = x.vals[j - 1];
        j -= 1;
    }
    x.kids[i + 1] = zi;
    x.keys[i] = y.keys[HALF];
    x.vals[i] = y.vals[HALF];
    x.n += 1;
}

<K: type, V: type>
attach fn put(this: btree<K, V>&, k: K, v: V) -> !void {
    if (this.nodes.len == 0) {
        try this.nodes.push({});
    }
    if (this.nodes.at(@cast<usize>(this.root)).n == MAX) {
        val r = @cast<u32>(this.nodes.len);
        try this.nodes.push({ leaf: false });
        this.nodes.at(@cast<usize>(r)).kids[0] = this.root;
        this.root = r;
        try this.split_child(r, 0);
    }
    var xi = this.root;
    loop {
        val x = this.nodes.at(@cast<usize>(xi));
        var i = lower(x, k);
        if (i < x.n && x.keys[i] == k) {
            x.vals[i] = v;
            return;
        }
        if (x.leaf) {
            var j = x.n;
            while (j > i) {
                x.keys[j] = x.keys[j - 1];
                x.vals[j] = x.vals[j - 1];
                j -= 1;
            }
            x.keys[i] = k;
            x.vals[i] = v;
            x.n += 1;
            this.len += 1;
            return;
        }
        if (this.nodes.at(@cast<usize>(x.kids[i])).n == MAX) {
            try this.split_child(xi, i);
            val p = this.nodes.at(@cast<usize>(xi)); // the split may have moved the nodes
            if (k == p.keys[i]) {
                p.vals[i] = v;
                return;
            }
            if (k > p.keys[i]) {
                i += 1;
            }
            xi = p.kids[i];
        } else {
            xi = x.kids[i];
        }
    }
}

<K: type, V: type>
attach fn get(this: btree<K, V>&, k: K) -> V? {
    if (this.nodes.len == 0) {
        return null;
    }
    val ns = this.nodes.items();
    var xi = this.root;
    loop {
        val x = &ns[@cast<usize>(xi)];
        val i = lower(x, k);
        if (i < x.n && x.keys[i] == k) {
            return x.vals[i];
        }
        if (x.leaf) {
            return null;
        }
        xi = x.kids[i];
    }
}

// calls visit on the entries of node xi's subtree from the first key not below lo, in order, while
// left is above 0
<K: type, V: type, F: type>
attach fn scan_from(this: btree<K, V>&, xi: u32, lo: K, left: usize&, visit: F) -> void {
    val x = this.nodes.at(@cast<usize>(xi));
    var i = lower(x, lo);
    while (i <= x.n) {
        if (!x.leaf) {
            this.scan_from(x.kids[i], lo, left, visit);
            if (*left == 0) {
                return;
            }
        }
        if (i == x.n) {
            return;
        }
        visit(x.keys[i], x.vals[i]);
        *left -= 1;
        if (*left == 0) {
            return;
        }
        i += 1;
    }
}

// calls visit on up to count entries, in order, from the first key not below lo
<K: type, V: type, F: type>
attach fn scan(this: btree<K, V>&, lo: K, count: usize, visit: F) -> void {
    var left = count;
    if (this.nodes.len > 0 && count > 0) {
        this.scan_from(this.root, lo, &left, visit);
    }
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "2000000").parse_int() catch 2000000);
    val space = 2 * @cast<u64>(n); // keys are drawn from 0..space
    var t: btree<u64, u64> = {};
    for (i) in 0..n {
        try t.put(next() % space, @cast<u64>(i));
    }
    var hits: usize = 0;
    var check: u64 = 0;
    for (i) in 0..n {
        if (val v = t.get(next() % space)) {
            hits += 1;
            check +%= v;
        }
    }
    for (i) in 0..n / 10 {
        t.scan(next() % space, 100, |check&| (k: u64, v: u64) {
            check = check *% 31 +% k +% v;
        });
    }
    std::println("{} entries, {} of {} lookups found", t.len, hits, n);
    std::println("checksum {}", check);
}
