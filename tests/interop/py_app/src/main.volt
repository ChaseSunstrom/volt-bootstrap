use std::io;
use std::thread;
// a Volt program calling Python through interop/python: modules, calls with converted arguments,
// eval and exec, an exception as an error, and a second thread taking the GIL

fn run() -> python::python_error!void {
    val math = try python::import("math");
    val root = try (try math.call_method("sqrt", 2.0)).to_f64();
    val fact = try (try math.call_method("factorial", 10)).to_i64();
    std::println("sqrt {:.4} factorial {}", root, fact);
    val json = try python::import("json");
    val text = try (try json.call_method("dumps", "volt")).to_string();
    val both = try python::eval("lambda a, b: a and b");
    std::println("json {} and {}", text, try (try both.call(true, false)).to_bool());
    try python::exec("def greet(who, times):\n    return ', '.join(['hi ' + who] * times)\n");
    val greet = try python::eval("greet");
    std::println("{}", try (try greet.call("volt", 2)).to_string());
    val xs = try python::eval("[n * n for n in range(5)]");
    std::println("list {} len {}", try xs.repr(), try (try xs.call_method("__len__")).to_i64());
    std::println("item {}", try (try xs.item(3)).to_i64());
    // an exception is an error with its type and message
    val bad = python::eval("1 / 0");
    if (bad.err) {
        std::println("caught {}", bad.err);
    }
    std::println("none {}", (try python::eval("None")).is_none());
}

fn main() -> !void {
    var py = python::start();
    try run();
    // another thread takes the GIL while this one lets go of it
    var seen: std::thread::atomic_i64 = {};
    py.without_gil(|seen&| () {
        var t = std::thread::spawn(|seen&| () {
            val g = python::gil();
            val r = python::eval("sum(range(101))") catch return;
            seen.store(r.to_i64() catch 0);
        }) catch return;
        t.join();
    });
    std::println("thread {}", seen.load());
}
