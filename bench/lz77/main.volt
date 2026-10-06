// lz77: compress a repetitive text with LZ77 (a hash table of recent positions, chains of at most 8
// probes, a 64 KiB window), decompress it and check the round trip; Volt builds std::vecs from
// slices, and the decoder returns an error (an error union) for corrupt input
use std::io;
use std::text;

// the format: a byte c < 128 is followed by c + 1 literal bytes; c >= 128 is a match of
// c - 128 + MIN_MATCH bytes, then its distance back (1..MAX_DIST) in two bytes, low first
val HASH_BITS: u32 = 16;
val WINDOW: usize = 65536;
val MIN_MATCH: usize = 4;
val MAX_MATCH: usize = 131;
val MAX_CHAIN: i32 = 8;
val MAX_DIST: usize = 65535;

error lz_error { LITERALS_PAST_END, MATCH_PAST_END, BAD_DISTANCE }

fn hash4(p: u8[..], i: usize) -> usize {
    val v = @cast<u32>(p[i]) | (@cast<u32>(p[i + 1]) << 8) | (@cast<u32>(p[i + 2]) << 16) | (@cast<u32>(p[i + 3]) << 24);
    return @cast<usize>((v *% 2654435761) >> (32 - HASH_BITS));
}

// inlined, as clang inlines the C's: out of line it takes out's address, and compress then keeps
// out's length in memory around every byte it adds
@attributes([@inline])
fn put_literals(out: std::vec<u8>&, input: u8[..], var from: usize, to: usize) -> !void {
    while (from < to) {
        var k = to - from;
        if (k > 128) {
            k = 128;
        }
        try out.push(@cast<u8>(k - 1));
        try out.extend(input[from..from + k]);
        from += k;
    }
}

fn compress(input: u8[..]) -> !std::vec<u8> {
    var head_table: std::vec<i32> = {};
    try head_table.resize(1 << HASH_BITS, -1);
    var prev_table: std::vec<i32> = {};
    try prev_table.resize(WINDOW, 0);
    val head = head_table.items();
    val prev = prev_table.items();
    val n = input.len;
    var out: std::vec<u8> = {};
    try out.reserve(n + n / 128 + 16); // the most the output can take, as the C sizes its buffer
    var i: usize = 0;
    var lit: usize = 0;
    while (i + MIN_MATCH <= n) {
        val h = hash4(input, i);
        var best: usize = 0;
        var dist: usize = 0;
        var limit = n - i;
        if (limit > MAX_MATCH) {
            limit = MAX_MATCH;
        }
        var cand = head[h];
        var probes = 0;
        while (cand >= 0 && i - @cast<usize>(cand) <= MAX_DIST && probes < MAX_CHAIN) {
            val c = @cast<usize>(cand);
            var len: usize = 0;
            while (len < limit && input[c + len] == input[i + len]) {
                len += 1;
            }
            if (len > best) {
                best = len;
                dist = i - c;
                if (len == limit) {
                    break;
                }
            }
            cand = prev[c & (WINDOW - 1)];
            probes += 1;
        }
        prev[i & (WINDOW - 1)] = head[h];
        head[h] = @cast<i32>(i);
        if (best >= MIN_MATCH) {
            try put_literals(&out, input, lit, i);
            val tag: u8[3] = { @cast<u8>(128 + best - MIN_MATCH), @cast<u8>(dist & 255), @cast<u8>(dist >> 8) };
            try out.extend(tag[..]);
            // the positions inside the match go into the table too
            var j = i + 1;
            while (j < i + best && j + MIN_MATCH <= n) {
                val hj = hash4(input, j);
                prev[j & (WINDOW - 1)] = head[hj];
                head[hj] = @cast<i32>(j);
                j += 1;
            }
            i += best;
            lit = i;
        } else {
            i += 1;
        }
    }
    try put_literals(&out, input, lit, n);
    return out;
}

// expected is the size to reserve room for
fn decompress(data: u8[..], expected: usize) -> !std::vec<u8> {
    var out: std::vec<u8> = {};
    try out.reserve(expected);
    var p: usize = 0;
    while (p < data.len) {
        val c = @cast<usize>(data[p]);
        p += 1;
        if (c < 128) {
            val k = c + 1;
            if (data.len - p < k) {
                return lz_error::LITERALS_PAST_END;
            }
            try out.extend(data[p..p + k]);
            p += k;
        } else {
            if (data.len - p < 2) {
                return lz_error::MATCH_PAST_END;
            }
            val len = c - 128 + MIN_MATCH;
            val dist = @cast<usize>(data[p]) | (@cast<usize>(data[p + 1]) << 8);
            p += 2;
            if (dist == 0 || dist > out.len) {
                return lz_error::BAD_DISTANCE;
            }
            val from = out.len - dist; // may overlap what it writes: a byte at a time
            for (k) in 0..len {
                try out.push(*out.at(from + k));
            }
        }
    }
    return out;
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> !void {
    val n = @cast<usize>((std::process::arg(1) ?? "67108864").parse_int() catch 67108864);
    // the text: words from a 1024-word vocabulary (the first ones the most common), and now and
    // then a phrase repeated from up to 32 KiB back
    var words: std::vec<std::string> = {};
    for (w) in 0..1024 {
        var word: std::string = {};
        val len = 2 + next() % 8;
        for (k) in 0..len {
            word.push(@cast<u8>('a' + next() % 26));
        }
        try words.push(word);
    }
    var text: std::string = {};
    try text.reserve(n + 128);
    while (text.len() < n) {
        val r = next();
        if (r % 16 == 0 && text.len() >= 64) {
            var span = text.len();
            if (span > 32768) {
                span = 32768;
            }
            val dist = 1 + @cast<usize>(next() % @cast<u64>(span));
            val count = 16 + next() % 48;
            for (k) in 0..count {
                text.push(text.as_str()[text.len() - dist]);
            }
        } else {
            text.append(words.at(@cast<usize>(((r >> 8) % 1024) * ((r >> 20) % 1024) / 1024)).as_str());
            match ((r >> 40) % 16) {
                0 => text.append(".\n"),
                1 => text.append(", "),
                default => text.push(' '),
            }
        }
    }
    text.truncate(n);
    val input = @cast<u8[..]>(text.as_str());
    val packed = try compress(input);
    val back = decompress(packed.items(), n) catch |e| {
        std::eprintln("corrupt: {}", e);
        std::process::exit(1);
    };
    if (!back.items().eq(&input)) {
        std::eprintln("round trip failed");
        std::process::exit(1);
    }
    var check: u64 = 14695981039346656037;
    for (b) in packed.items() {
        check = (check ^ @cast<u64>(b)) *% 1099511628211;
    }
    std::println("{} {} {}", n, packed.len, check);
}
