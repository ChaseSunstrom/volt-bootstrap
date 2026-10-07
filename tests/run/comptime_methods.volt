use std::io;
// @typeinfo(T).methods lists the fns attached to T; @field(v, name)(...) calls one by a name worked
// out at compile time (and @field(T, name)(...) a static one)
struct counter {
    n: i32;
}

attach fn cmd_up(this: counter&) -> void {
    this.n += 1;
}

attach fn cmd_twice(this: counter&) -> void {
    this.n *= 2;
}

attach fn label(this: counter&, prefix: str) -> std::string {
    return std::fmt::format("{}{}", prefix, this.n);
}

attach fn zero(static this: counter) -> counter {
    return { n: 0 };
}

// runs the cmd_ method named by `cmd` (false when there's none)
<T: type>
fn run(v: T&, cmd: str) -> bool {
    comptime for (m) in @typeinfo(T).methods {
        comptime if (m.name.len > 4 && m.name[0..4] == "cmd_") {
            if (cmd == m.name[4..]) {
                @field(v, m.name)();
                return true;
            }
        }
    }
    return false;
}

fn main() -> void {
    var c = @field(counter, "zero")();
    val cmds: str[] = { "up", "up", "twice", "nope" };
    for (cmd) in cmds {
        if (!run(&c, cmd)) {
            std::println("no command {}", cmd);
        }
    }
    std::println("{}", @field(c, "label")("n="));
    var count = 0;
    comptime for (m) in @typeinfo(counter).methods {
        comptime if (m.name == "label") {
            std::println("{} takes {}", m.name, m.params[0]);
        }
        count += 1;
    }
    std::println("{}", count >= 3);
}
// expect: no command nope
// expect: n=4
// expect: label takes prefix
// expect: true
