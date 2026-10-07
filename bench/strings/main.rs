// strings: build a long text of numbered words, split it on spaces, count and join the long words
use std::fmt::Write;

fn main() {
    let n: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(10_000_000);
    let mut text = String::new();
    for i in 0..n {
        write!(text, "word{} ", i * 7 % 1000003).unwrap();
    }
    // split on spaces; join the words longer than 9 bytes with commas
    let mut joined = String::new();
    let (mut words, mut long_words) = (0u64, 0u64);
    for w in text.split_terminator(' ') {
        words += 1;
        if w.len() > 9 {
            if long_words > 0 {
                joined.push(',');
            }
            joined.push_str(w);
            long_words += 1;
        }
    }
    println!("{} {words} {long_words} {}", text.len(), joined.len());
}
