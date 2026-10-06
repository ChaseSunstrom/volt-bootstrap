// @embed("path"): a file's bytes as a compile-time str, the path relative to this file. Comptime
// code can read it: here a struct is built from a small JSON schema (the guide's @embed example,
// comptime.md, which the docs test can't run: it needs the file beside it)
use std::io;

// "string" | "integer" | "number" | "boolean" → a Volt type
comptime fn json_type(t: str) -> type {
    if (t == "string") {
        return std::string;
    }
    if (t == "integer") {
        return i64;
    }
    if (t == "number") {
        return f64;
    }
    return bool;
}

// the k-th "..." in text (from 0), without its quotes; "" past the last
comptime fn nth_str(text: str, k: usize) -> str {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"') {
            var j = i + 1;
            while (text[j] != '"') {
                j += 1;
            }
            if (seen == k) {
                return text[i + 1..j];
            }
            seen += 1;
            i = j;
        }
        i += 1;
    }
    return "";
}

// { "properties": { "NAME": { "type": "TYPE" }, ... } }: after "properties", each property is three
// strings: its name, "type" and its type
comptime fn from_schema(json: str) -> type {
    return struct {
        comptime for (i) in 0..count(json) {
            (nth_str(json, 1 + 3 * i)): json_type(nth_str(json, 3 + 3 * i));
        }
    };
}

comptime fn count(json: str) -> usize {
    var n: usize = 0;
    while (nth_str(json, 1 + 3 * n) != "") {
        n += 1;
    }
    return n;
}

type user = from_schema(@embed("comptime_embed.json"));

// arrays slice at compile time too
comptime fn middle(xs: i32[]) -> i32 {
    val m = xs[1..3];
    return m[0] + m[1] + xs[..=0][0];
}

fn main() -> void {
    val u: user = { name: std::string::from("ada"), age: 36, admin: true };
    std::println("{} {} {}", u.name.as_str(), u.age, u.admin);
    std::println("{} {}", @embed("comptime_embed.json").len, middle({ 1, 2, 3, 4 }));
}
// expect: ada 36 true
// expect: 129 6
