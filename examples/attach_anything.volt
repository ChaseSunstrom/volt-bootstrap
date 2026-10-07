// Functions attach to any type, not only the ones you declare: built-ins like i32 and str, std's
// types, a C struct or a C++ class from an import (examples/interop/volt-calls/attach-foreign).
// Comptime code then reads a type's fields and attached fns, and declares new code from them. Zig
// can generate code from a type's fields too, but it can't add a method to a type it doesn't own:
// i32 and a library's types are closed to it.
use std::io;

// ---------- attached to types Volt and std own ----------

attach fn kib(this: i32) -> i32 {
    return this * 1024;
}

attach fn shout(this: str) -> std::string {
    var out = std::string::from(this);
    out.append("!");
    return out;
}

<T: type>
attach fn total(this: std::vec<T>&) -> T {
    var sum: T = 0;
    for (x) in this.items() {
        sum += x;
    }
    return sum;
}

// ---------- a command layer generated from attached fns ----------

struct lamp {
    on: bool;
    level: i32;
}

attach fn cmd_toggle(this: lamp&) -> void {
    this.on = !this.on;
}

attach fn cmd_brighter(this: lamp&) -> void {
    this.level += 10;
}

struct door {
    open: bool;
    locked: bool;
}

attach fn cmd_open(this: door&) -> void {
    if (!this.locked) {
        this.open = true;
    }
}

attach fn cmd_lock(this: door&) -> void {
    this.locked = true;
}

// for any T: run(cmd) calls T's cmd_ fn of that name, commands() lists them, and show() prints
// every field. Nothing here names lamp or door, or any of their fns
comptime fn commands(T: type) -> void {
    attach fn run(this: T&, cmd: str) -> bool {
        comptime for (m) in @typeinfo(T).methods {
            comptime if (m.name.len > 4 && m.name[0..4] == "cmd_") {
                if (cmd == m.name[4..]) {
                    @field(this, m.name)();
                    return true;
                }
            }
        }
        return false;
    }
    attach fn commands(static this: T) -> std::string {
        var out = std::string::from(@typeinfo(T).short_name);
        out.append(":");
        comptime for (m) in @typeinfo(T).methods {
            comptime if (m.name.len > 4 && m.name[0..4] == "cmd_") {
                out.append(" ");
                out.append(m.name[4..]);
            }
        }
        return out;
    }
    attach fn show(this: T&) -> std::string {
        var out = std::string::from(@typeinfo(T).short_name);
        comptime for (f) in @typeinfo(T).fields {
            std::fmt::write(&out, " {}={}", f.name, @field(this, f.name));
        }
        return out;
    }
}

comptime commands(lamp);
comptime commands(door);

fn main() -> void {
    val n: i32 = 4;
    var xs: std::vec<i64> = {};
    xs.push(20);
    xs.push(22);
    std::println("{} {} {}", n.kib(), "volt".shout(), xs.total());

    var l: lamp = { on: false, level: 0 };
    var d: door = { open: false, locked: false };
    val script: str[] = { "toggle", "brighter", "brighter", "fly" };
    for (cmd) in script {
        if (!l.run(cmd)) {
            std::println("lamp can't {}", cmd);
        }
    }
    d.run("lock");
    d.run("open");
    std::println("{}", lamp::commands());
    std::println("{}", door::commands());
    std::println("{}", l.show());
    std::println("{}", d.show());
}
// expect: 4096 volt! 42
// expect: lamp can't fly
// expect: lamp: toggle brighter
// expect: door: open lock
// expect: lamp on=true level=20
// expect: door open=false locked=true
