// wordfreq: count the words of a text of n words drawn from a Zipf-like vocabulary in a hash map keyed
// by string, then print the 20 most frequent; Volt uses std::map with str keys viewing the text, and
// sort_by with a closure (the vocabulary sits in rows of 10 bytes, as in the C)
use std::io;
use std::text;

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

struct ranked {
    word: str;
    count: i64;
}

fn main() -> !void {
    val n = (std::process::arg(1) ?? "20000000").parse_int() catch 20000000;
    // the vocabulary: random lowercase words of 3 to 10 letters, in rows of 10 bytes as the C keeps them
    var words: std::vec<u8> = {};
    try words.resize(262144 * 10, 0);
    var lens: std::vec<usize> = {};
    try lens.reserve(262144);
    val rows = words.items();
    for (k) in 0..262144 {
        val len = 3 + next() % 8;
        for (j) in 0..len {
            rows[@cast<usize>(k) * 10 + @cast<usize>(j)] = @cast<u8>('a' + next() % 26);
        }
        try lens.push(@cast<usize>(len));
    }
    // the text: word k is picked about 1/k as often as word 1
    var text: std::string = {};
    for (i) in 0..n {
        val bits = next() % 19;
        val k = next() & ((@cast<u64>(1) << bits) - 1);
        val at = @cast<usize>(k) * 10;
        text.append(@cast<str>(rows[at..at + *lens.at(@cast<usize>(k))]));
        text.push(' ');
    }
    var counts: std::map<str, i64> = {};
    val all = text.as_str();
    var start: usize = 0;
    var total: i64 = 0;
    for (b, i) in all {
        if (b == ' ') {
            val w = all[start..i];
            val slot = counts.get(w);
            if (slot) {
                *slot += 1;
            } else {
                counts.put(w, 1);
            }
            total += 1;
            start = i + 1;
        }
    }
    var ranks: std::vec<ranked> = {};
    for (e) in counts.iter() {
        try ranks.push({ word: *e.key, count: *e.value });
    }
    ranks.items().sort_by(|| (a: ranked&, b: ranked&) -> i32 {
        if (a.count != b.count) {
            return b.count.cmp(&a.count);
        }
        return a.word.cmp(b.word);
    });
    std::println("{} bytes, {} words, {} distinct", text.len(), total, ranks.len);
    for (r, i) in ranks.items() {
        if (i == 20) {
            break;
        }
        std::println("{} {}", r.word, r.count);
    }
}
