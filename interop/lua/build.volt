// lua's build file: Lua 5.4 or later's C flags from pkg-config (lua, then lua5.5, lua5.4 and the
// other names distributions use; $LUA_PC picks one). bolt hands them to every package and program
// that depends on this one.
use std::io;

// what pkg-config prints for this package, or null when it doesn't know it
fn ask(name: str) -> std::string? {
    val argv: str[4] = { "pkg-config", "--cflags", "--libs", name };
    val r = std::process::capture(argv[..], "") catch return null;
    if (r.code != 0) {
        return null;
    }
    return std::string::from(r.out.as_str().trim());
}

fn main() -> void {
    val names: str[6] = { "lua", "lua5.5", "lua5.4", "lua-5.5", "lua-5.4", "lua54" };
    var flags: std::string? = null;
    val chosen = std::process::env("LUA_PC");
    if (chosen) {
        flags = ask(chosen);
    } else {
        for (n) in names {
            if (flags == null) {
                flags = ask(n);
            }
        }
    }
    if (flags == null) {
        std::eprintln("lua: pkg-config knows no Lua: install Lua 5.4 or later's development files, or set $LUA_PC");
        std::process::exit(1);
    }
    val f = flags ?? std::string::from("");
    for (w) in f.as_str().words().items() {
        bolt::cc_arg(w);
    }
}
