// strings: build a long text of numbered words, split it on spaces, count and join the long words
use std::io;
use std::text;

fn main() -> void {
    val n = (std::process::arg(1) ?? "10000000").parse_int() catch 10000000;
    var text: std::string = {};
    for (i) in 0..n {
        text.append("word");
        text.append_int(i * 7 % 1000003);
        text.push(' ');
    }
    // split on spaces; join the words longer than 9 bytes with commas
    val words = text.as_str().split(" ");
    var joined: std::string = {};
    var long_words = 0;
    for (w) in words.items() {
        if (w.len > 9) {
            if (long_words > 0) {
                joined.push(',');
            }
            joined.append(w);
            long_words += 1;
        }
    }
    // the last piece is the empty one after the final space
    std::println("{} {} {} {}", text.len(), words.len - 1, long_words, joined.len());
}
