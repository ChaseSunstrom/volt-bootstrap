// huffman: Huffman-code a skewed 64-letter text: count the letters, build the code tree from a
// priority queue of (weight, node), write every letter's code as bits, then read the bits back a bit
// at a time down the tree and check the round trip; Rust uses BinaryHeap with Reverse and Option
// children
use std::cmp::Reverse;
use std::collections::BinaryHeap;

struct Node {
    children: Option<(usize, usize)>, // none on a leaf
    sym: u8,
}

fn assign(nodes: &[Node], id: usize, code: u64, len: u32, codes: &mut [u64; 256], lens: &mut [u32; 256]) {
    match nodes[id].children {
        None => {
            codes[nodes[id].sym as usize] = code;
            lens[nodes[id].sym as usize] = len;
        }
        Some((left, right)) => {
            assign(nodes, left, code << 1, len + 1, codes, lens);
            assign(nodes, right, (code << 1) | 1, len + 1, codes, lens);
        }
    }
}

fn fnv(s: &[u8]) -> u64 {
    s.iter().fold(14695981039346656037u64, |h, &c| (h ^ c as u64).wrapping_mul(1099511628211))
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(33554432);
    // the text: letters of a 64-letter alphabet, the first ones the most common
    let alphabet = b"etaoinshrdlcumwfgypbvkjxqzETAOINSHRDLCUMWFGYPBVKJXQZ0123456789 .";
    let mut rng = Rng(88172645463325252);
    let text: Vec<u8> = (0..n)
        .map(|_| {
            let r = rng.next();
            alphabet[(((r >> 8) % 64) * ((r >> 20) % 64) / 63) as usize]
        })
        .collect();
    let mut count = [0u64; 256];
    for &c in &text {
        count[c as usize] += 1;
    }
    // a leaf per letter that occurs, in byte order; then a node joining the two lightest, until one is left
    let mut nodes = Vec::new();
    let mut queue = BinaryHeap::new();
    for (c, &w) in count.iter().enumerate() {
        if w > 0 {
            queue.push(Reverse((w, nodes.len())));
            nodes.push(Node { children: None, sym: c as u8 });
        }
    }
    let symbols = nodes.len();
    while queue.len() > 1 {
        let Reverse((wa, a)) = queue.pop().unwrap();
        let Reverse((wb, b)) = queue.pop().unwrap();
        queue.push(Reverse((wa + wb, nodes.len())));
        nodes.push(Node { children: Some((a, b)), sym: 0 });
    }
    let Reverse((_, root)) = queue.pop().unwrap();
    let mut codes = [0u64; 256];
    let mut lens = [0u32; 256];
    assign(&nodes, root, 0, 0, &mut codes, &mut lens);
    let longest = *lens.iter().max().unwrap();
    // write the codes, the first bit of each byte the highest
    let mut packed = Vec::with_capacity(n * longest as usize / 8 + 1);
    let mut acc = 0u64;
    let mut bits = 0;
    for &c in &text {
        acc = (acc << lens[c as usize]) | codes[c as usize];
        bits += lens[c as usize];
        while bits >= 8 {
            bits -= 8;
            packed.push((acc >> bits) as u8);
        }
    }
    if bits > 0 {
        packed.push((acc << (8 - bits)) as u8);
    }
    // read them back down the tree
    let mut back = Vec::with_capacity(n);
    let mut pos = 0;
    for _ in 0..n {
        let mut id = root;
        while let Some((left, right)) = nodes[id].children {
            let bit = (packed[pos >> 3] >> (7 - (pos & 7))) & 1;
            pos += 1;
            id = if bit == 1 { right } else { left };
        }
        back.push(nodes[id].sym);
    }
    if back != text {
        eprintln!("round trip failed");
        std::process::exit(1);
    }
    println!("{n} letters, {symbols} symbols, longest code {longest} bits");
    println!("packed {} bytes, checksum {}", packed.len(), fnv(&packed));
    println!("unpacked {n} bytes, checksum {}", fnv(&back));
}
