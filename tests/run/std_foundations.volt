// flags: --leak-check
use std::io;

struct node { v: i32; }
attach fn delete(this: node&) -> void { std::println("drop {}", this.v); }

fn main() -> !void {
    // vec
    var v: std::vec<i32> = {};
    for (i) in 0..10 {
        try v.push(i * i);
    }
    std::println("{} {} {}", v.len, *v.at(3), v.items());
    std::println(v.pop() ?? -1);
    var w = copy v;
    *w.at(0) = 100;
    std::println("{} {}", v.items()[0], w.items()[0]);
    var nodes: std::vec<node> = {};
    try nodes.push({ v: 1 });
    try nodes.push({ v: 2 });
    {
        val last = nodes.pop() ?? return;
        std::println("popped {}", last.v);
    }

    // string
    var s = std::string::from("n=");
    s.append_int(-42);
    s.append(" ok");
    std::println("[{}] {}", s, s.len());

    // map
    var m: std::map<str, i32> = {};
    m.put("one", 1);
    m.put("two", 2);
    m.put("one", 11);
    for (i) in 0..100 {
        m.put("x", i);
    }
    std::println("{} {} {}", m.len, *(m.get("one") ?? return), m.get("three") == null);
    var n: std::map<i32, std::string> = {};
    for (i) in 0..50 {
        n.put(i, std::string::from("v"));
    }
    val r = n.remove(7) ?? return;
    std::println("{} {} {}", n.len, r, n.get(7) == null);

    // fs and process
    val path = "target/std_foundations_test.txt";
    try std::fs::write_file(path, "line one\nline two\n");
    val text = try std::fs::read_file(path);
    std::print("{}", text);
    std::println(std::fs::read_file("/nope/nothing") catch |e| std::string::from("missing"));
    val argv: str[] = { "sh", "-c", "exit 3" };
    std::println("code {}", try std::process::run(argv[..]));
    std::eprintln("stderr works");
}
// expect: 10 9 { 0, 1, 4, 9, 16, 25, 36, 49, 64, 81 }
// expect: 81
// expect: 0 100
// expect: popped 2
// expect: drop 2
// expect: [n=-42 ok] 8
// expect: 3 11 true
// expect: 49 v true
// expect: line one
// expect: line two
// expect: missing
// expect: code 3
// expect: drop 1
