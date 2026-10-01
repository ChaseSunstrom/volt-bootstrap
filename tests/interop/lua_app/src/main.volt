use std::io;
// a Volt program embedding Lua through interop/lua: a script, globals both ways, calls with Volt
// arguments, tables, a Volt function Lua calls, and errors

// hypot(a, b) for Lua: numbers in, a number out (or nil and a message)
extern "C" fn hypot(L: void*) -> i32 {
    var a = lua::args_of(L);
    val x = a.number(1);
    val y = a.number(2);
    if (x == null || y == null) {
        a.ret(lua::nil());
        a.ret("hypot wants two numbers");
        return 2;
    }
    a.ret(std::math::sqrt((x ?? 0.0) * (x ?? 0.0) + (y ?? 0.0) * (y ?? 0.0)));
    return 1;
}

fn run(l: lua::state&) -> lua::lua_error!void {
    try l.run("function greet(who, n) return string.rep('hi ' .. who .. ' ', n) end\nscores = { 3, 9, 4, best = 'volt' }");
    val greet = l.global("greet");
    std::println("{}", (try greet.call("volt", 2)).to_string());
    val scores = l.global("scores");
    std::println("len {} second {} best {}", scores.len(), try (try scores.at(2)).to_i64(), (try scores.get("best")).to_string());
    l.set_global("limit", 40);
    std::println("eval {}", try (try l.eval("limit + 2")).to_i64());
    std::println("math {}", try (try l.eval("math.floor(math.pi * 100)")).to_f64());
    l.register("hypot", hypot);
    std::println("hypot {}", (try l.eval("hypot(3, 4)")).to_string());
    std::println("hypot bad {}", (try l.eval("select(2, hypot('x'))")).to_string());
    val t = try l.eval("{ name = 'lua', tags = { 'a', 'b' } }");
    std::println("type {} {} nil {}", t.type_name(), (try (try t.get("tags")).at(2)).to_string(), (try t.get("missing")).is_nil());
    val bad = l.run("error('boom')");
    if (bad.err) {
        std::println("caught {}", bad.err);
    }
    val syntax = l.run("x = = 1");
    std::println("syntax {}", syntax.err != null);
    val notnum = (try l.eval("'abc'")).to_i64();
    if (notnum.err) {
        std::println("{}", notnum.err);
    }
}

fn main() -> !void {
    var l = lua::start();
    try run(&l);
}
