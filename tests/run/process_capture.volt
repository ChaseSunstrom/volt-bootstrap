use std::io;

// std::process::capture: run a program with some stdin, get its stdout, stderr and exit code
fn main() -> i32 {
    val args: str[3] = { "sh", "-c", "tr a-z A-Z; printf oops >&2; exit 3" };
    val r = std::process::capture(args, "hello") catch |e| {
        std::println("spawn failed");
        return 1;
    };
    std::println("out={} err={} code={}", r.out, r.err, r.code);
    // more than a pipe buffer each way, stderr first: nothing waits on anything else
    var big: std::string = {};
    for (i) in 0..100000 {
        big.push(120);
    }
    val flood: str[3] = { "sh", "-c", "head -c 100000 /dev/zero >&2; cat" };
    val f = std::process::capture(flood, big.as_str()) catch |e| {
        std::println("spawn failed");
        return 1;
    };
    std::println("flood out={} err={} same={}", f.out.len(), f.err.len(), f.out.as_str() == big.as_str());
    // a child that never reads its (bigger than a pipe buffer) input
    val deaf: str[3] = { "sh", "-c", "exit 5" };
    val d = std::process::capture(deaf, big.as_str()) catch |e| {
        std::println("spawn failed");
        return 1;
    };
    std::println("deaf code={}", d.code);
    // a program that isn't there is an error, not an exit code (127 is a real exit code too)
    val none: str[1] = { "voltc-surely-not-a-program" };
    val r2 = std::process::run(none) catch |e| -1;
    std::println("run missing {}", r2);
    val m = std::process::capture(none, "") catch |e| {
        std::println("capture missing: can't run it");
        return 0;
    };
    std::println("capture missing code={}", m.code);
    return 0;
}
// expect: out=HELLO err=oops code=3
// expect: flood out=100000 err=100000 same=true
// expect: deaf code=5
// expect: run missing -1
// expect: capture missing: can't run it
