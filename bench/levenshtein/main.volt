// levenshtein: edit distances between many pairs of strings, each a random string of 64 to 191
// letters and a copy with random substitutions, deletions and insertions, by the dynamic program
// over one row; prints the number of pairs, the sum and the largest of the distances, and a checksum
// of them all. Volt builds the strings in std::strings and keeps the row in a std::vec
use std::io;
use std::math;
use std::text;

fn distance(a: str, b: str, row_vec: std::vec<u32>&) -> !u32 {
    row_vec.clear();
    for (j) in 0..=b.len {
        try row_vec.push(@cast<u32>(j));
    }
    val row = row_vec.items();
    for (ca, i) in a {
        var diag = row[0];
        row[0] = @cast<u32>(i + 1);
        for (cb, j) in b {
            val up = row[j + 1];
            val cost: u32 = if (ca != cb) 1 else 0;
            row[j + 1] = std::math::min(std::math::min(diag + cost, up + 1), row[j] + 1);
            diag = up;
        }
    }
    return row[b.len];
}

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

fn main() -> !void {
    val pairs = @cast<usize>((std::process::arg(1) ?? "40000").parse_int() catch 40000);
    val letters = "abcdefgh";
    var a: std::string = {};
    var b: std::string = {};
    var row: std::vec<u32> = {};
    var total: u64 = 0;
    var check: u64 = 0;
    var most: u32 = 0;
    for (p) in 0..pairs {
        val la = 64 + next() % 128;
        a.clear();
        for (i) in 0..la {
            a.push(letters[@cast<usize>(next() % 8)]);
        }
        // b: a with about one letter in 8 changed, one in 16 dropped and one in 16 inserted
        b.clear();
        for (c) in a.as_str() {
            val r = next() % 16;
            if (r == 0) {
                continue;
            }
            if (r == 1) {
                b.push(letters[@cast<usize>(next() % 8)]);
            }
            b.push(if (r == 2 || r == 3) letters[@cast<usize>(next() % 8)] else c);
        }
        val d = try distance(a.as_str(), b.as_str(), &row);
        total += @cast<u64>(d);
        most = std::math::max(most, d);
        check = check *% 31 +% @cast<u64>(d);
    }
    std::println("{} pairs, total distance {}, largest {}", pairs, total, most);
    std::println("checksum {}", check);
}
