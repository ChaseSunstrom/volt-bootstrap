// fasta (the Benchmarks Game): generate three DNA sequences, n*2 bases repeating the ALU string, then
// n*3 and n*5 bases drawn by a linear congruential generator from cumulative probability tables, in
// FASTA lines of 60; prints each one's header, length and an FNV-1a checksum of its lines in place of
// the text. Volt builds the cumulative tables in a comptime fn
use std::io;
use std::text;

val ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";

struct acid {
    c: u8;
    p: f64;
}

// each p becomes the sum of the ones up to it
<N: usize>
comptime fn cumulative(t: acid[N]) -> acid[N] {
    var out = t;
    var sum = 0.0;
    for (i) in 0..N {
        sum += out[i].p;
        out[i].p = sum;
    }
    return out;
}

// the probabilities are vals of their own, named as the Benchmarks Game's programs name them
val IUB_P: acid[15] = {
    { c: 'a', p: 0.27 }, { c: 'c', p: 0.12 }, { c: 'g', p: 0.12 }, { c: 't', p: 0.27 }, { c: 'B', p: 0.02 },
    { c: 'D', p: 0.02 }, { c: 'H', p: 0.02 }, { c: 'K', p: 0.02 }, { c: 'M', p: 0.02 }, { c: 'N', p: 0.02 },
    { c: 'R', p: 0.02 }, { c: 'S', p: 0.02 }, { c: 'V', p: 0.02 }, { c: 'W', p: 0.02 }, { c: 'Y', p: 0.02 },
};
val IUB = cumulative(IUB_P);

val HOMO_SAPIENS_P: acid[4] = {
    { c: 'a', p: 0.3029549426680 }, { c: 'c', p: 0.1979883004921 }, { c: 'g', p: 0.1975473066391 }, { c: 't', p: 0.3015094502008 },
};
val HOMO_SAPIENS = cumulative(HOMO_SAPIENS_P);

val IM: u32 = 139968;
val IA: u32 = 3877;
val IC: u32 = 29573;

var seed: u32 = 42;

fn random_unit() -> f64 {
    seed = (seed * IA + IC) % IM;
    return @cast<f64>(seed) / @cast<f64>(IM);
}

fn fnv(var h: u64, s: u8[..]) -> u64 {
    for (c) in s {
        h = (h ^ @cast<u64>(c)) *% 1099511628211;
    }
    return h;
}

fn repeat(header: str, s: str, n: usize) -> void {
    var pos: usize = 0;
    var line: u8[61];
    var h: u64 = 14695981039346656037;
    var done: usize = 0;
    while (done < n) {
        val m = if (n - done < 60) n - done else 60;
        for (i) in 0..m {
            line[i] = s[pos];
            pos += 1;
            if (pos == s.len) {
                pos = 0;
            }
        }
        line[m] = '\n';
        h = fnv(h, line[0..m + 1]);
        done += m;
    }
    std::println("{}: {} bases, checksum {}", header, n, h);
}

fn random_bases(header: str, t: acid[..], n: usize) -> void {
    var line: u8[61];
    var h: u64 = 14695981039346656037;
    var done: usize = 0;
    while (done < n) {
        val m = if (n - done < 60) n - done else 60;
        for (i) in 0..m {
            val r = random_unit();
            var k: usize = 0;
            while (k < t.len - 1 && r >= t[k].p) {
                k += 1;
            }
            line[i] = t[k].c;
        }
        line[m] = '\n';
        h = fnv(h, line[0..m + 1]);
        done += m;
    }
    std::println("{}: {} bases, checksum {}", header, n, h);
}

fn main() -> void {
    val n = @cast<usize>((std::process::arg(1) ?? "10000000").parse_int() catch 10000000);
    repeat(">ONE Homo sapiens alu", ALU, n * 2);
    random_bases(">TWO IUB ambiguity codes", IUB[..], n * 3);
    random_bases(">THREE Homo sapiens frequency", HOMO_SAPIENS[..], n * 5);
}
