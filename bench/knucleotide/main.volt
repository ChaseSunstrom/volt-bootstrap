// k-nucleotide (the Benchmarks Game): count the k-mers of a long DNA string, k = 1 and 2 as sorted
// frequencies, and five longer ones (up to 18 bases) by building a table for each length; Volt packs
// the bases 2 bits each into a u64 key, counted in a std::map
use std::io;
use std::text;

// every k-mer of codes, its bases 2 bits each
fn count(codes: u8[..], k: usize) -> std::map<u64, u32> {
    var counts: std::map<u64, u32> = {};
    val mask = (@cast<u64>(1) << (2 * @cast<u64>(k))) - 1;
    var key: u64 = 0;
    for (c, i) in codes {
        key = ((key << 2) | @cast<u64>(c)) & mask;
        if (i + 1 >= k) {
            val n = counts.get(key);
            if (n != null) {
                *n += 1;
            } else {
                counts.put(key, 1);
            }
        }
    }
    return counts;
}

fn code_of(c: u8) -> u8 {
    return match (c) {
        'A' => 0,
        'C' => 1,
        'G' => 2,
        default => 3,
    };
}

struct kmer {
    key: u64;
    count: u32;
}

fn frequencies(codes: u8[..], k: usize) -> !void {
    var counts = count(codes, k);
    var all: std::vec<kmer> = {};
    for (e) in counts.iter() {
        try all.push({ key: *e.key, count: *e.value });
    }
    // most first; ties by key, which for one length is letter order
    all.items().sort_by(|| (a: kmer&, b: kmer&) -> i32 {
        if (a.count != b.count) {
            if (a.count > b.count) {
                return -1;
            }
            return 1;
        }
        if (a.key < b.key) {
            return -1;
        }
        if (a.key > b.key) {
            return 1;
        }
        return 0;
    });
    for (m) in all.items() {
        var name: std::string = {};
        for (j) in 0..k {
            name.push("ACGT"[@cast<usize>((m.key >> (2 * @cast<u64>(k - 1 - j))) & 3)]);
        }
        std::println("{} {:.3}", name, 100.0 * @cast<f64>(m.count) / @cast<f64>(codes.len - k + 1));
    }
    std::println("");
}

fn occurrences(codes: u8[..], seq: str) -> void {
    var key: u64 = 0;
    for (c) in seq {
        key = (key << 2) | @cast<u64>(code_of(c));
    }
    var counts = count(codes, seq.len);
    var found: u32 = 0;
    val n = counts.get(key);
    if (n != null) {
        found = *n;
    }
    std::println("{}\t{}", found, seq);
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "25000000").parse_int() catch 25000000);
    // the bases at the human genome's frequencies; the generator that made the original input
    // (fasta) repeats every 139968 numbers, so this sequence repeats with that period too
    val period: usize = 139968;
    var dna: std::string = {};
    try dna.reserve(n);
    for (i) in 0..n {
        if (i >= period) {
            dna.push(dna.as_str()[i - period]);
            continue;
        }
        dna.push(match ((next() >> 32) % 1000) {
            0..=302 => 'A',
            303..=500 => 'C',
            501..=698 => 'G',
            default => 'T',
        });
    }
    var codes: std::vec<u8> = {};
    try codes.reserve(n);
    for (c) in dna.as_str() {
        try codes.push(code_of(c));
    }
    try frequencies(codes.items(), 1);
    try frequencies(codes.items(), 2);
    val seqs: str[] = { "GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT" };
    for (s) in seqs {
        occurrences(codes.items(), s);
    }
}
