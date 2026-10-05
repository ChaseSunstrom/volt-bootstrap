// lua: embed Lua (5.4 or later) in Volt. start() makes a Lua state with the standard libraries;
// run(code) runs a chunk, eval(expr) and global(name) give values, and a value calls with Volt
// arguments, converted: integers, floats, bool, str, std::string and values. Values are Lua
// registry references (copying one adds a reference, deleting it drops it). A Lua error comes back
// as lua_error::ERROR with its message. register(name, f) gives Lua a Volt function.
use { "lua.h", "lauxlib.h", "lualib.h" } as c;

public error lua_error {
    ERROR: std::string,
}

// ---------- the state ----------

public struct state {
    L: c::lua_State* = null;
}

// a Lua state with the standard libraries
public fn start() -> state {
    val L = c::luaL_newstate() ?? @panic("lua: out of memory");
    // what luaL_openlibs does (a macro in Lua 5.5)
    open(L, "_G", c::luaopen_base);
    open(L, "package", c::luaopen_package);
    open(L, "coroutine", c::luaopen_coroutine);
    open(L, "table", c::luaopen_table);
    open(L, "io", c::luaopen_io);
    open(L, "os", c::luaopen_os);
    open(L, "string", c::luaopen_string);
    open(L, "math", c::luaopen_math);
    open(L, "utf8", c::luaopen_utf8);
    open(L, "debug", c::luaopen_debug);
    return { L: L };
}

public fn open(L: c::lua_State*, name: str, f: extern "C" fn(c::lua_State*) -> i32) -> void {
    var n = std::string::from(name);
    c::luaL_requiref(L, n.c_str(), f, 1);
    c::lua_settop(L, -2);
}

public attach fn delete(this: state&) -> void {
    if (this.L != null) {
        c::lua_close(this.L);
        this.L = null;
    }
}

// the message on top of the stack, popped, as an error
public fn failed(L: c::lua_State*) -> lua_error {
    var msg = std::string::from("a Lua error");
    var n: usize = 0;
    val s = c::lua_tolstring(L, -1, &n);
    if (s) {
        msg = std::string::from(@cast<str>(@slice(@cast<u8*>(s), n)));
    }
    c::lua_settop(L, -2);
    return lua_error::ERROR(move msg);
}

// loads a chunk (the function it compiles to is pushed)
public fn load(L: c::lua_State*, code: str, name: str) -> lua_error!void {
    var n = std::string::from(name);
    if (c::luaL_loadbufferx(L, @cast<cstr>(code.ptr), code.len, n.c_str(), null) != 0) {
        return failed(L);
    }
}

// runs a chunk of Lua
public attach fn run(this: state&, code: str) -> lua_error!void {
    try load(this.L, code, "=run");
    if (c::lua_pcallk(this.L, 0, 0, 0, 0, null) != 0) {
        return failed(this.L);
    }
}

// an expression's value
public attach fn eval(this: state&, expr: str) -> lua_error!value {
    var code = std::string::from("return ");
    code.append(expr);
    try load(this.L, code.as_str(), "=eval");
    if (c::lua_pcallk(this.L, 0, 1, 0, 0, null) != 0) {
        return failed(this.L);
    }
    return pop(this.L);
}

// the global called name (nil when there's none)
public attach fn global(this: state&, name: str) -> value {
    var n = std::string::from(name);
    c::lua_getglobal(this.L, n.c_str());
    return pop(this.L);
}

// sets the global called name to x
<T: type>
public attach fn set_global(this: state&, name: str, x: T) -> void {
    push(this.L, &x);
    var n = std::string::from(name);
    c::lua_setglobal(this.L, n.c_str());
}

// gives Lua a Volt function as the global name: it reads its arguments and returns its results
// through lua::args (an error raised from it would skip Volt's deletes, so return nil and a message
// instead)
public attach fn register(this: state&, name: str, f: extern "C" fn(void*) -> i32) -> void {
    c::lua_pushcclosure(this.L, @cast<extern "C" fn(c::lua_State*) -> i32>(f), 0);
    var n = std::string::from(name);
    c::lua_setglobal(this.L, n.c_str());
}

// ---------- values ----------

// a Lua value, held in the registry
public struct value {
    L: c::lua_State* = null;
    ref: i32 = -1; // LUA_REFNIL: nil
}

public attach fn delete(this: value&) -> void {
    if (this.L != null && this.ref >= 0) {
        c::luaL_unref(this.L, c::LUA_REGISTRYINDEX, this.ref);
        this.ref = -1;
    }
}

public attach fn copy(this: value&) -> value {
    if (this.L == null) {
        return {};
    }
    this.push();
    return pop(this.L);
}

// nil, as a value to pass
public fn nil() -> value {
    return {};
}

// the value on top of the stack, popped
public fn pop(L: c::lua_State*) -> value {
    return { L: L, ref: c::luaL_ref(L, c::LUA_REGISTRYINDEX) };
}

// pushes this value
public attach fn push(this: value&) -> void {
    c::lua_rawgeti(this.L, c::LUA_REGISTRYINDEX, @cast<i64>(this.ref));
}

// x pushed on the stack
<T: type>
public fn push(L: c::lua_State*, x: T&) -> void {
    @compile_error("Lua values are integers, f64, f32, bool, str, std::string and lua::value");
}
public fn push<i64>(L: c::lua_State*, x: i64&) -> void { c::lua_pushinteger(L, *x); }
public fn push<i32>(L: c::lua_State*, x: i32&) -> void { c::lua_pushinteger(L, *x as i64); }
public fn push<f64>(L: c::lua_State*, x: f64&) -> void { c::lua_pushnumber(L, *x); }
public fn push<f32>(L: c::lua_State*, x: f32&) -> void { c::lua_pushnumber(L, *x as f64); }
public fn push<bool>(L: c::lua_State*, x: bool&) -> void {
    var b = 0;
    if (*x) {
        b = 1;
    }
    c::lua_pushboolean(L, b);
}
public fn push<str>(L: c::lua_State*, x: str&) -> void { c::lua_pushlstring(L, @cast<cstr>(x.ptr), x.len); }
public fn push<std::string>(L: c::lua_State*, x: std::string&) -> void { c::lua_pushlstring(L, @cast<cstr>(x.as_str().ptr), x.len()); }
public fn push<value>(L: c::lua_State*, x: value&) -> void {
    if (x.L == null) {
        c::lua_pushnil(L);
    } else {
        x.push();
    }
}

// this(args...): its first result (nil when there's none)
<Args: type...>
public attach fn call(this: value&, args: Args...) -> lua_error!value {
    this.push();
    var n = 0;
    comptime for (a) in args {
        push(this.L, &a);
        n++;
    }
    if (c::lua_pcallk(this.L, n, 1, 0, 0, null) != 0) {
        return failed(this.L);
    }
    return pop(this.L);
}

// this[key], for a table (or anything with __index)
public attach fn get(this: value&, key: str) -> lua_error!value {
    this.push();
    var k = std::string::from(key);
    c::lua_pushlstring(this.L, k.c_str(), k.len());
    if (c::lua_type(this.L, -2) != 5) { // LUA_TTABLE
        c::lua_settop(this.L, -3);
        return lua_error::ERROR(std::fmt::format("indexing a {} value with {}", this.type_name(), key));
    }
    c::lua_gettable(this.L, -2);
    val v = pop(this.L);
    c::lua_settop(this.L, -2);
    return v;
}

// this[i], for a sequence (1 is the first)
public attach fn at(this: value&, i: i64) -> lua_error!value {
    if (this.type_name() != "table") {
        return lua_error::ERROR(std::fmt::format("indexing a {} value with {}", this.type_name(), i));
    }
    this.push();
    c::lua_geti(this.L, -1, i);
    val v = pop(this.L);
    c::lua_settop(this.L, -2);
    return v;
}

// #this: a string's or sequence's length
public attach fn len(this: value&) -> i64 {
    this.push();
    val n = c::lua_rawlen(this.L, -1);
    c::lua_settop(this.L, -2);
    return @cast<i64>(n);
}

// "nil", "number", "string", "table", "function", ...
public attach fn type_name(this: value&) -> str {
    if (this.L == null) {
        return "nil";
    }
    this.push();
    val t = c::lua_type(this.L, -1);
    c::lua_settop(this.L, -2);
    val s = c::lua_typename(this.L, t) ?? return "nil";
    return @cast<str>(@slice(@cast<u8*>(s), strlen(s)));
}

public attach fn is_nil(this: value&) -> bool {
    return this.type_name() == "nil";
}

public attach fn to_i64(this: value&) -> lua_error!i64 {
    this.push();
    var ok = 0;
    val x = c::lua_tointegerx(this.L, -1, &ok);
    c::lua_settop(this.L, -2);
    if (ok == 0) {
        return lua_error::ERROR(std::fmt::format("a {} isn't an integer", this.type_name()));
    }
    return x;
}

public attach fn to_f64(this: value&) -> lua_error!f64 {
    this.push();
    var ok = 0;
    val x = c::lua_tonumberx(this.L, -1, &ok);
    c::lua_settop(this.L, -2);
    if (ok == 0) {
        return lua_error::ERROR(std::fmt::format("a {} isn't a number", this.type_name()));
    }
    return x;
}

// Lua's truth: false and nil are false, everything else is true
public attach fn to_bool(this: value&) -> bool {
    if (this.L == null) {
        return false;
    }
    this.push();
    val b = c::lua_toboolean(this.L, -1);
    c::lua_settop(this.L, -2);
    return b != 0;
}

// what tostring(this) gives
public attach fn to_string(this: value&) -> std::string {
    if (this.L == null) {
        return std::string::from("nil");
    }
    this.push();
    var n: usize = 0;
    val s = c::luaL_tolstring(this.L, -1, &n);
    var out = std::string::from("");
    if (s) {
        out = std::string::from(@cast<str>(@slice(@cast<u8*>(s), n)));
    }
    c::lua_settop(this.L, -3);
    return out;
}

public extern "C" fn strlen(s: cstr) -> usize;

// ---------- Volt functions Lua calls ----------

// a call from Lua to a registered Volt function: its arguments (1 is the first) and its results
public struct args {
    L: c::lua_State*;
}

// the arguments of the call a registered function was given L for
public fn args_of(L: void*) -> args {
    return { L: @cast<c::lua_State*>(L) };
}

public attach fn len(this: args&) -> i32 {
    return c::lua_gettop(this.L);
}

public attach fn integer(this: args&, i: i32) -> i64? {
    var ok = 0;
    val x = c::lua_tointegerx(this.L, i, &ok);
    if (ok == 0) {
        return null;
    }
    return x;
}

public attach fn number(this: args&, i: i32) -> f64? {
    var ok = 0;
    val x = c::lua_tonumberx(this.L, i, &ok);
    if (ok == 0) {
        return null;
    }
    return x;
}

public attach fn text(this: args&, i: i32) -> std::string? {
    if (c::lua_type(this.L, i) != 4) { // LUA_TSTRING
        return null;
    }
    var n: usize = 0;
    val s = c::lua_tolstring(this.L, i, &n) ?? return null;
    return std::string::from(@cast<str>(@slice(@cast<u8*>(s), n)));
}

public attach fn get(this: args&, i: i32) -> value {
    c::lua_pushvalue(this.L, i);
    return pop(this.L);
}

// pushes a result; the function returns how many it pushed
<T: type>
public attach fn ret(this: args&, x: T) -> void {
    push(this.L, &x);
}
