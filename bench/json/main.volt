// json: generate a JSON array of n objects (nested arrays and objects, escaped strings, ints and
// decimals) as text, parse it into a tree, then walk the tree for counts and sums; Volt parses with
// std::json into its value enum (std::string, std::vec, members in order) and walks it with match
use std::io;
use std::text;
use std::fmt;
use std::json;

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

// ---------- the text ----------

val WORDS: str[8] = { "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel" };
val ESCAPES: str[5] = { "\\\"", "\\\\", "\\n", "\\t", "\\u00e9" };

// a string of 2 to 5 pieces, a quarter of them escapes
fn put_name(out: std::string&) -> void {
    out.push('"');
    val pieces = 2 + next() % 4;
    for (k) in 0..pieces {
        if (next() % 4 == 0) {
            out.append(ESCAPES[next() % 5]);
        } else {
            out.append(WORDS[next() % 8]);
        }
    }
    out.push('"');
}

fn put_object(out: std::string&, i: i64) -> void {
    out.append("{\"id\":");
    out.append_int(i);
    out.append(",\"name\":");
    put_name(out);
    val cents = next() % 1000000;
    std::write(out, ",\"score\":{}.{:02},\"tags\":[", cents / 100, cents % 100);
    val tags = next() % 5;
    for (k) in 0..tags {
        if (k > 0) {
            out.push(',');
        }
        out.push('"');
        out.append(WORDS[next() % 8]);
        out.push('"');
    }
    out.append("],\"pos\":[");
    for (k) in 0..3 {
        if (k > 0) {
            out.push(',');
        }
        out.append_int(@cast<i64>(next() % 2000001) - 1000000);
    }
    if (next() % 2 != 0) {
        out.append("],\"active\":true");
    } else {
        out.append("],\"active\":false");
    }
    out.append(",\"meta\":{\"level\":");
    out.append_uint(next() % 10);
    std::write(out, ",\"ratio\":0.{:03},\"note\":", next() % 1000);
    if (next() % 3 == 0) {
        out.append("null");
    } else {
        put_name(out);
    }
    out.append("}}");
}

// ---------- walking ----------

struct stats {
    objects: i64 = 0;
    arrays: i64 = 0;
    strings: i64 = 0;
    numbers: i64 = 0;
    trues: i64 = 0;
    nulls: i64 = 0;
    string_bytes: usize = 0;
}

fn walk(v: std::json::value&, s: stats&) -> void {
    match (*v) {
        .NULL => { s.nulls += 1; },
        .BOOL(b) => {
            if (b) {
                s.trues += 1;
            }
        },
        .NUM(n) => { s.numbers += 1; },
        .STR(t&) => {
            s.strings += 1;
            s.string_bytes += t.len();
        },
        .ARR(items&) => {
            s.arrays += 1;
            for (item&) in items.items() {
                walk(item, s);
            }
        },
        .OBJ(members&) => {
            s.objects += 1;
            for (m&) in members.items() {
                walk(&m.item, s);
            }
        },
    }
}

fn main() -> !void {
    val n = (std::process::arg(1) ?? "400000").parse_int() catch 400000;
    var text = std::string::from("[");
    for (i) in 0..n {
        if (i > 0) {
            text.append(",\n");
        }
        put_object(&text, i);
    }
    text.append("]\n");
    val doc = try std::json::parse(text.as_str());
    var s: stats = {};
    walk(&doc, &s);
    var ids: i64 = 0;
    var cents: i64 = 0;
    for (i) in 0..doc.len() {
        val item = doc.at(i);
        ids += @cast<i64>(item.get("id").as_num() ?? 0.0);
        cents += @cast<i64>((item.get("score").as_num() ?? 0.0) * 100.0 + 0.5);
    }
    std::println("{} bytes: {} objects, {} arrays, {} strings, {} numbers", text.len(), s.objects, s.arrays, s.strings, s.numbers);
    std::println("{} string bytes, {} true, {} null", s.string_bytes, s.trues, s.nulls);
    std::println("{} {}", ids, cents);
}
