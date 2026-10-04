// Volt types plugged into a C++ framework: listeners on its event bus and plugins in its registry,
// each a Volt struct overriding the interface's virtual methods
use std::io;
use { "framework.hpp" } as cpp;

struct logger {
    lines: i32;
    total: i32;
    rank: i32;
}

attach cpp::fw::Listener -> logger {
    fn on_event(this, self: cpp::fw::Listener&, e: cpp::fw::Event&) -> void {
        this.lines += 1;
        this.total += e.value() * this.rank;
    }

    fn priority(this, self: cpp::fw::Listener&) -> i32 { return this.rank; }
}

struct counter {
    name: str;
    starts: i32;
    stopped: bool;
}

attach cpp::fw::Plugin -> counter {
    fn id(this, self: cpp::fw::Plugin&) -> std::string { return std::string::from(this.name); }

    fn start(this, self: cpp::fw::Plugin&) -> bool {
        this.starts += 1;
        return this.starts < 2;
    }

    fn stop(this, self: cpp::fw::Plugin&) -> void { this.stopped = true; }
}

struct broken {
    code: i32;
}

attach cpp::fw::Plugin -> broken {
    fn id(this, self: cpp::fw::Plugin&) -> std::string { return std::string::from("broken"); }
    fn start(this, self: cpp::fw::Plugin&) -> bool { return false; }
}

// both a listener and a plugin: label is the listener's only (the plugin's is C++'s own)
struct both {
    seen: i32;
}

attach cpp::fw::Listener -> both {
    fn on_event(this, self: cpp::fw::Listener&, e: cpp::fw::Event&) -> void { this.seen += 1; }
    fn label(this, self: cpp::fw::Listener&) -> std::string { return std::string::from("both"); }
}

attach cpp::fw::Plugin -> both {
    fn id(this, self: cpp::fw::Plugin&) -> std::string { return std::string::from("both"); }
}

fn main() -> void {
    val a: logger = { lines: 0, total: 0, rank: 1 };
    val b: logger = { lines: 0, total: 0, rank: 10 };
    var la = cpp::fw::Listener::derive(move a);
    var lb = cpp::fw::Listener::derive(move b);
    var bus = cpp::fw::Bus::new();
    bus.subscribe(&la);
    bus.subscribe(&lb);
    std::println("{} {}", bus.publish("x", 2), bus.publish("y", 3));
    val ga = la.derived<logger>() ?? @panic("not a logger");
    val gb = lb.derived<logger>() ?? @panic("not a logger");
    std::println("{} {} {} {}", ga.lines, ga.total, gb.lines, gb.total);
    val c: counter = { name: "count", starts: 0, stopped: false };
    val k: broken = { code: 1 };
    var pc = cpp::fw::Plugin::derive(move c);
    var pk = cpp::fw::Plugin::derive(move k);
    var reg = cpp::fw::Registry::new();
    reg.add(&pc);
    reg.add(&pk);
    std::println("{} {}", reg.start_all(), reg.start_all());
    reg.stop_all();
    std::println("{}", (pc.derived<counter>() ?? @panic("?")).stopped);
    val x: both = { seen: 0 };
    val y: both = { seen: 0 };
    var lx = cpp::fw::Listener::derive(move x);
    var py = cpp::fw::Plugin::derive(move y);
    bus.subscribe(&lx);
    std::println("{} {} {}", bus.publish("z", 1), cpp::fw::labels(&lx, &py), (lx.derived<both>() ?? @panic("?")).seen);
}
