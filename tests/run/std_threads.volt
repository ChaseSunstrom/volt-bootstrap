// flags: --leak-check
use std::io;
use std::string;
use std::text;
use std::thread;
// std::thread: spawn and join, a mutex and its guard, atomics, shared<T>, a channel of owned values,
// a condition variable, and println from several threads at once

struct tracked { n: i32; }
attach fn delete(this: tracked&) -> void { std::println("tracked {} deleted", this.n); }

// run as a child process: 4 threads println long lines at the same time
fn chatter() -> !void {
    var ts: std::vec<std::thread::thread> = {};
    for (k) in 0..4 {
        try ts.push(try std::thread::spawn(|k| () {
            for (i) in 0..300 {
                std::println("<{} {} {}>", k, i, "abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrstuvwxyz");
            }
        }));
    }
    // deleting ts joins every thread
}

fn main() -> !void {
    if (std::process::arg_count() > 1) {
        try chatter();
        return;
    }

    // 8 threads add 10000 each to a counter behind a mutex and to an atomic. They borrow both (& captures):
    // deleting a thread joins it, so they're done before what they borrow goes away
    var counter: std::thread::mutex<i64> = { value: 0 };
    var hits: std::thread::atomic_i64 = {};
    {
        var ts: std::vec<std::thread::thread> = {};
        for (k) in 0..8 {
            try ts.push(try std::thread::spawn(|counter&, hits&| () {
                for (i) in 0..10000 {
                    *counter.lock().get() += 1;
                    hits.add(1);
                }
            }));
        }
    }
    std::println("{} {} {}", *counter.lock().get(), hits.load(), hits.swap(5));
    std::println("{} {} {}", hits.compare_swap(4, 9), hits.compare_swap(5, 9), hits.load());

    // shared<T>: copies share one value, which goes with the last copy (here, a thread's)
    var go: std::thread::atomic_bool = {};
    var last: std::thread::thread = {};
    {
        val tr: tracked = { n: 5 };
        val s = try std::thread::share(move tr);
        val c = copy s;
        std::println("{} {}", s.get().n, s.count());
        last = try std::thread::spawn(|move c, go&| () {
            while (!go.load()) {
                std::thread::yield_now();
            }
            std::println("thread has {} of {}", c.get().n, c.count());
        });
    }
    std::println("main's copy gone");
    go.store(true);
    last.join();
    std::println("joined");

    // a channel carries owned strings from 4 producers to main, which receives while they send
    {
        val ch = try std::thread::channel<std::string>::new();
        var producers: std::vec<std::thread::thread> = {};
        for (k) in 0..4 {
            try producers.push(try std::thread::spawn(|ch, k| () {
                for (i) in 0..25 {
                    var s = std::string::from("msg-");
                    s.append_int(k * 100 + i);
                    ch.send(move s);
                }
            }));
        }
        var count = 0;
        var total: usize = 0;
        var sum: i64 = 0;
        for (n) in 0..100 {
            val s = ch.recv() ?? @panic("closed early");
            val digits = s.as_str()[4..s.len()];
            count += 1;
            total += s.len();
            sum += digits.parse_int() catch -1000000;
        }
        producers.clear();
        val empty = ch.try_recv() ?? std::string::from("empty");
        // what's sent before close still arrives; after that, recv gives null and send refuses
        ch.send(std::string::from("last"));
        ch.close();
        val tail = ch.recv() ?? std::string::from("none");
        val end = ch.recv() ?? std::string::from("none");
        val refused = !ch.send(std::string::from("too late"));
        std::println("{} {} {} {} {} {} {}", count, total, sum, empty.as_str(), tail.as_str(), end.as_str(), refused);
        // what's never received is deleted with the channel
        val other = try std::thread::channel<std::string>::new();
        other.send(std::string::from("unread"));
    }

    // a condition variable: a thread waits until main sets the flag
    {
        var ready: std::thread::mutex<bool> = { value: false };
        var changed: std::thread::cond = {};
        var waiter = try std::thread::spawn(|ready&, changed&| () {
            var g = ready.lock();
            while (!*g.get()) {
                changed.wait(&g);
            }
            std::println("waiter saw the flag");
        });
        std::time::sleep(std::time::millis(10));
        {
            var g = ready.lock();
            *g.get() = true;
        }
        changed.notify_all();
        waiter.join();
        std::println("waiter joined");
    }

    // println from several threads: every line comes out whole (checked in a child process)
    val me: str[2] = { std::process::arg(0) ?? "", "chatter" };
    val out = try std::process::capture(me, "");
    val lines = out.out.as_str().lines();
    var whole = 0;
    for (line) in lines.items() {
        if (line.starts_with("<") && line.ends_with("z>") && line.count("abc") == 2) {
            whole += 1;
        }
    }
    std::println("{} {} {}", out.code, whole, lines.len);
}
// expect: 80000 80000 80000
// expect: false true 9
// expect: 5 2
// expect: main's copy gone
// expect: thread has 5 of 1
// expect: tracked 5 deleted
// expect: joined
// expect: 100 665 16200 empty last none true
// expect: waiter saw the flag
// expect: waiter joined
// expect: 0 1200 1200
