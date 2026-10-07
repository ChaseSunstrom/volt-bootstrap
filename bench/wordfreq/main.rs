// wordfreq: count the words of a text of n words drawn from a Zipf-like vocabulary in a HashMap<&str, i64>, then print the 20 most frequent
use std::collections::HashMap;

const VOCAB: usize = 1 << 18;

fn main() {
    let n: i64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(20000000);
    let mut x: u64 = 88172645463325252;
    let mut next = move || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    // the vocabulary: random lowercase words of 3 to 10 letters
    let words: Vec<String> = (0..VOCAB)
        .map(|_| {
            let len = 3 + next() % 8;
            (0..len).map(|_| (b'a' + (next() % 26) as u8) as char).collect()
        })
        .collect();
    // the text: word k is picked about 1/k as often as word 1
    let mut text = String::with_capacity(1 << 20);
    for _ in 0..n {
        let bits = next() % 19;
        let k = next() & ((1u64 << bits) - 1);
        text.push_str(&words[k as usize]);
        text.push(' ');
    }
    let mut counts: HashMap<&str, i64> = HashMap::new();
    let mut total = 0i64;
    for w in text.split_terminator(' ') {
        *counts.entry(w).or_insert(0) += 1;
        total += 1;
    }
    // most frequent first, ties alphabetically
    let mut all: Vec<(&str, i64)> = counts.into_iter().collect();
    all.sort_unstable_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    println!("{} bytes, {total} words, {} distinct", text.len(), all.len());
    for (w, c) in all.iter().take(20) {
        println!("{w} {c}");
    }
}
