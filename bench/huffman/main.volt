// huffman: Huffman-code a skewed 64-letter text: count the letters, build the code tree from a
// priority queue of (weight, node), write every letter's code as bits, then read the bits back a bit
// at a time down the tree and check the round trip; Volt uses std::heap, ordered by the items'
// attached cmp, and optional children
use std::io;
use std::heap;
use std::text;

struct node {
    children: (usize, usize)?; // null on a leaf
    sym: u8;
}

struct item {
    weight: u64;
    id: usize;
}

// lightest first, then the lowest id
attach fn cmp(this: item&, o: item&) -> i32 {
    if (this.weight != o.weight) {
        return if (this.weight < o.weight) -1 else 1;
    }
    return if (this.id < o.id) -1 else if (this.id > o.id) 1 else 0;
}

fn assign(nodes: node[..], id: usize, code: u64, len: u32, codes: u64[256]&, lens: u32[256]&) -> void {
    if (val ch = nodes[id].children) {
        assign(nodes, ch.0, code << 1, len + 1, codes, lens);
        assign(nodes, ch.1, (code << 1) | 1, len + 1, codes, lens);
    } else {
        codes[nodes[id].sym] = code;
        lens[nodes[id].sym] = len;
    }
}

fn fnv(s: u8[..]) -> u64 {
    var h: u64 = 14695981039346656037;
    for (c) in s {
        h = (h ^ @cast<u64>(c)) *% 1099511628211;
    }
    return h;
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "33554432").parse_int() catch 33554432);
    // the text: letters of a 64-letter alphabet, the first ones the most common
    val alphabet = "etaoinshrdlcumwfgypbvkjxqzETAOINSHRDLCUMWFGYPBVKJXQZ0123456789 .";
    var text: std::vec<u8> = {};
    try text.reserve(n);
    for (i) in 0..n {
        val r = next();
        try text.push(alphabet[@cast<usize>(((r >> 8) % 64) * ((r >> 20) % 64) / 63)]);
    }
    var count: u64[256];
    for (c) in text.items() {
        count[c] += 1;
    }
    // a leaf per letter that occurs, in byte order; then a node joining the two lightest, until one is left
    var nodes: std::vec<node> = {};
    var queue: std::heap<item> = {};
    for (w, c) in count {
        if (w > 0) {
            queue.push({ weight: w, id: nodes.len });
            try nodes.push({ children: null, sym: @cast<u8>(c) });
        }
    }
    val symbols = nodes.len;
    while (queue.len() > 1) {
        val a = queue.pop() ?? @panic("empty");
        val b = queue.pop() ?? @panic("empty");
        queue.push({ weight: a.weight + b.weight, id: nodes.len });
        try nodes.push({ children: (a.id, b.id), sym: 0 });
    }
    val root = (queue.pop() ?? @panic("empty")).id;
    var codes: u64[256];
    var lens: u32[256];
    assign(nodes.items(), root, 0, 0, &codes, &lens);
    var longest: u32 = 0;
    for (l) in lens {
        if (l > longest) {
            longest = l;
        }
    }
    // write the codes, the first bit of each byte the highest
    var packed: std::vec<u8> = {};
    try packed.reserve(n * @cast<usize>(longest) / 8 + 1);
    var acc: u64 = 0;
    var bits: u32 = 0;
    for (c) in text.items() {
        acc = (acc << @cast<u64>(lens[c])) | codes[c];
        bits += lens[c];
        while (bits >= 8) {
            bits -= 8;
            try packed.push(@cast<u8>(acc >> @cast<u64>(bits)));
        }
    }
    if (bits > 0) {
        try packed.push(@cast<u8>(acc << @cast<u64>(8 - bits)));
    }
    // read them back down the tree
    val tree = nodes.items();
    val p = packed.items();
    var back: std::vec<u8> = {};
    try back.reserve(n);
    var pos: usize = 0;
    for (i) in 0..n {
        var id = root;
        while (val ch = tree[id].children) {
            val bit = (p[pos >> 3] >> @cast<u8>(7 - (pos & 7))) & 1;
            pos += 1;
            id = if (bit == 1) ch.1 else ch.0;
        }
        try back.push(tree[id].sym);
    }
    val original = text.items();
    if (!back.items().eq(&original)) {
        std::eprintln("round trip failed");
        std::process::exit(1);
    }
    std::println("{} letters, {} symbols, longest code {} bits", n, symbols, longest);
    std::println("packed {} bytes, checksum {}", packed.len, fnv(packed.items()));
    std::println("unpacked {} bytes, checksum {}", n, fnv(back.items()));
}
