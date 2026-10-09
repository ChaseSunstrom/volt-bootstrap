// revcomp (the Benchmarks Game): the reverse complement of a 64 MiB DNA sequence in FASTA lines of
// 60 bases, done nine times between two byte buffers; prints the size, the first line and an FNV-1a
// checksum of the result. Volt works on the std::vec<u8>s' slices
use std::io;
use std::text;

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

// out gets src's bases from last to first, each complemented, 60 a line
fn revcomp(src: u8[..], out: u8[..], comp: u8[256]&) -> void {
    var o: usize = 0;
    var col: usize = 0;
    var i = src.len;
    while (i > 0) {
        i -= 1;
        val c = src[i];
        if (c == '\n') {
            continue;
        }
        out[o] = comp[c];
        o += 1;
        col += 1;
        if (col == 60) {
            out[o] = '\n';
            o += 1;
            col = 0;
        }
    }
    if (col > 0) {
        out[o] = '\n';
    }
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "67108864").parse_int() catch 67108864);
    // each IUPAC code and its complement, upper and lower case
    val from = "ACGTUMRWSYKVHDBNacgtumrwsykvhdbn";
    val to = "TGCAAKYWSRMBDHVNTGCAAKYWSRMBDHVN";
    var comp: u8[256];
    for (i) in 0..256 {
        comp[i] = @cast<u8>(i);
    }
    for (f, i) in from {
        comp[f] = to[i];
    }
    // the bases: mostly ACGT, some lower case and other codes
    val alphabet = "ACGTACGTACGTacgtNRYKMSWBDHVnACGT";
    val len = n + (n + 59) / 60;
    var abuf: std::vec<u8> = {};
    try abuf.reserve(len);
    for (i) in 0..n {
        try abuf.push(alphabet[@cast<usize>(next() >> 59)]);
        if (i % 60 == 59 || i == n - 1) {
            try abuf.push('\n');
        }
    }
    var bbuf: std::vec<u8> = {};
    try bbuf.resize(len, 0);
    var a = abuf.items();
    var b = bbuf.items();
    for (pass) in 0..9 {
        revcomp(a, b, &comp);
        val t = a;
        a = b;
        b = t;
    }
    var check: u64 = 14695981039346656037;
    for (c) in a {
        check = (check ^ @cast<u64>(c)) *% 1099511628211;
    }
    val first = if (len < 60) len - 1 else 60;
    std::println("{} bases, {} bytes", n, len);
    std::println("{}", @cast<str>(a[0..first]));
    std::println("{}", check);
}
