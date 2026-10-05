// node: Node.js addons written in Volt, over Node-API. The library exports
//
//     export fn napi_register_module_v1(env: void*, exports: void*) -> void* {
//         var m = node::init(env, exports);
//         m.function("add", add) catch |e| {};
//         return m.exports();
//     }
//
// and each exported function takes the call (its arguments, and what makes new values) and returns
// node_error!node::value. A returned error is thrown in JS as an Error; a JS exception thrown by
// something Volt calls comes back as node_error::THROWN with its message. Values are only good
// during the call that made them.
use { "node_api.h" } as napi;

public error node_error {
    THROWN: std::string,
}

// a JS value (and the environment it belongs to)
public struct value {
    env: napi::napi_env__*;
    v: napi::napi_value__*;
}

// one call of an exported function: its arguments and `this`
public struct call {
    env: napi::napi_env__*;
    args: std::vec<napi::napi_value__*> = {};
    this_value: napi::napi_value__* = null;
}

// the module being set up: what napi_register_module_v1 gets
public struct module {
    env: napi::napi_env__*;
    exports_value: napi::napi_value__*;
}

// the module napi_register_module_v1 sets up
public fn init(env: void*, exports: void*) -> module {
    return { env: @cast<napi::napi_env__*>(env), exports_value: @cast<napi::napi_value__*>(exports) };
}

// the exports object, to return from napi_register_module_v1
public attach fn exports(this: module&) -> void* {
    return @cast<void*>(this.exports_value);
}

// ---------- errors ----------

// the pending JS exception's message (and clears it), else what failed
public fn failure(env: napi::napi_env__*, what: str) -> node_error {
    var pending = false;
    napi::napi_is_exception_pending(env, &pending);
    if (pending) {
        var e: napi::napi_value__* = null;
        napi::napi_get_and_clear_last_exception(env, &e);
        val err: value = { env: env, v: e };
        val m = err.get("message") catch return node_error::THROWN(std::string::from("a JS exception"));
        val text = m.to_string() catch std::string::from("a JS exception");
        return node_error::THROWN(move text);
    }
    var msg = std::string::from("Node-API failed: ");
    msg.append(what);
    return node_error::THROWN(move msg);
}

public fn check(env: napi::napi_env__*, status: i32, what: str) -> node_error!void {
    if (status != napi::napi_ok) {
        return failure(env, what);
    }
}

// ---------- exporting functions ----------

// the C function Node calls for every exported Volt function; `data` is the Volt function
public extern "C" fn trampoline(env: napi::napi_env__*, info: napi::napi_callback_info__*) -> napi::napi_value__* {
    var argc: usize = 0;
    var data: void* = null;
    var c: call = { env: env };
    napi::napi_get_cb_info(env, info, &argc, null, &c.this_value, &data);
    for (i) in 0..argc {
        c.args.push(null) catch return null;
    }
    if (argc > 0) {
        napi::napi_get_cb_info(env, info, &argc, &c.args.items()[0], &c.this_value, null);
    }
    val f = @cast<extern "C" fn(call&) -> node_error!value>(data);
    val r = f(&c) catch |e| {
        var pending = false;
        napi::napi_is_exception_pending(env, &pending);
        if (!pending) {
            match (e) {
                .THROWN(msg) => {
                    var m = std::string::from(msg.as_str());
                    napi::napi_throw_error(env, null, m.c_str());
                },
            }
        }
        return null;
    };
    return r.v;
}

// exports f under name: JS calls it with any arguments
public attach fn function(this: module&, name: str, f: extern "C" fn(call&) -> node_error!value) -> node_error!void {
    var n = std::string::from(name);
    var fv: napi::napi_value__* = null;
    try check(this.env, napi::napi_create_function(this.env, n.c_str(), name.len, trampoline, @cast<void*>(f), &fv), "napi_create_function");
    try check(this.env, napi::napi_set_named_property(this.env, this.exports_value, n.c_str(), fv), "napi_set_named_property");
}

// ---------- a call's arguments, and new values ----------

public attach fn len(this: call&) -> usize {
    return this.args.len;
}

// argument i (undefined past the end)
public attach fn arg(this: call&, i: usize) -> value {
    if (i < this.args.len) {
        return { env: this.env, v: *this.args.at(i) };
    }
    return this.undefined();
}

public attach fn this_arg(this: call&) -> value {
    return { env: this.env, v: this.this_value };
}

public attach fn undefined(this: call&) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_get_undefined(this.env, &r);
    return { env: this.env, v: r };
}

public attach fn null_value(this: call&) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_get_null(this.env, &r);
    return { env: this.env, v: r };
}

public attach fn number(this: call&, x: f64) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_create_double(this.env, x, &r);
    return { env: this.env, v: r };
}

public attach fn boolean(this: call&, x: bool) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_get_boolean(this.env, x, &r);
    return { env: this.env, v: r };
}

public attach fn string(this: call&, s: str) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_create_string_utf8(this.env, @cast<cstr>(s.ptr), s.len, &r);
    return { env: this.env, v: r };
}

public attach fn object(this: call&) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_create_object(this.env, &r);
    return { env: this.env, v: r };
}

public attach fn array(this: call&) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_create_array(this.env, &r);
    return { env: this.env, v: r };
}

// ---------- values ----------

// x as a JS value, for set, push and call: f64, f32, integers, bool, str, std::string, value
<T: type>
public fn js(env: napi::napi_env__*, x: T) -> value {
    @compile_error("node::js takes numbers, bool, str, std::string and node::value");
}
public fn js<value>(env: napi::napi_env__*, x: value) -> value { return x; }
public fn js<f64>(env: napi::napi_env__*, x: f64) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_create_double(env, x, &r);
    return { env: env, v: r };
}
public fn js<f32>(env: napi::napi_env__*, x: f32) -> value { return js(env, x as f64); }
public fn js<i64>(env: napi::napi_env__*, x: i64) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_create_int64(env, x, &r);
    return { env: env, v: r };
}
public fn js<i32>(env: napi::napi_env__*, x: i32) -> value { return js(env, x as i64); }
public fn js<bool>(env: napi::napi_env__*, x: bool) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_get_boolean(env, x, &r);
    return { env: env, v: r };
}
public fn js<str>(env: napi::napi_env__*, x: str) -> value {
    var r: napi::napi_value__* = null;
    napi::napi_create_string_utf8(env, @cast<cstr>(x.ptr), x.len, &r);
    return { env: env, v: r };
}
public fn js<std::string>(env: napi::napi_env__*, x: std::string) -> value { return js(env, x.as_str()); }

// "number", "string", "boolean", "object", "function", "undefined", "null", "symbol", "bigint" or
// "external"
public attach fn type_of(this: value&) -> str {
    var t: i32 = 0;
    napi::napi_typeof(this.env, this.v, &t);
    val names: str[10] = { "undefined", "null", "boolean", "number", "string", "symbol", "object", "function", "external", "bigint" };
    if (t >= 0 && t < 10) {
        return names[@cast<usize>(t)];
    }
    return "unknown";
}

public attach fn to_f64(this: value&) -> node_error!f64 {
    var x: f64 = 0.0;
    try check(this.env, napi::napi_get_value_double(this.env, this.v, &x), "expected a number");
    return x;
}

public attach fn to_i64(this: value&) -> node_error!i64 {
    var x: i64 = 0;
    try check(this.env, napi::napi_get_value_int64(this.env, this.v, &x), "expected a number");
    return x;
}

public attach fn to_bool(this: value&) -> node_error!bool {
    var x = false;
    try check(this.env, napi::napi_get_value_bool(this.env, this.v, &x), "expected a boolean");
    return x;
}

// a string's text (String(x) for anything else)
public attach fn to_string(this: value&) -> node_error!std::string {
    var s = this.v;
    if (this.type_of() != "string") {
        try check(this.env, napi::napi_coerce_to_string(this.env, this.v, &s), "String()");
    }
    var n: usize = 0;
    try check(this.env, napi::napi_get_value_string_utf8(this.env, s, null, 0, &n), "a string's length");
    var buf: std::vec<u8> = {};
    for (i) in 0..n + 1 {
        buf.push(0) catch return node_error::THROWN(std::string::from("out of memory"));
    }
    try check(this.env, napi::napi_get_value_string_utf8(this.env, s, @cast<cstr>(&buf.items()[0]), n + 1, &n), "a string");
    return std::string::from(@cast<str>(buf.items()[0..n]));
}

public attach fn get(this: value&, name: str) -> node_error!value {
    var n = std::string::from(name);
    var r: napi::napi_value__* = null;
    try check(this.env, napi::napi_get_named_property(this.env, this.v, n.c_str(), &r), "a property");
    return { env: this.env, v: r };
}

<T: type>
public attach fn set(this: value&, name: str, x: T) -> node_error!void {
    var n = std::string::from(name);
    val v = js(this.env, x);
    try check(this.env, napi::napi_set_named_property(this.env, this.v, n.c_str(), v.v), "setting a property");
}

// an array's length
public attach fn length(this: value&) -> node_error!usize {
    var n: u32 = 0;
    try check(this.env, napi::napi_get_array_length(this.env, this.v, &n), "expected an array");
    return n as usize;
}

public attach fn at(this: value&, i: usize) -> node_error!value {
    var r: napi::napi_value__* = null;
    try check(this.env, napi::napi_get_element(this.env, this.v, @cast<u32>(i), &r), "an element");
    return { env: this.env, v: r };
}

<T: type>
public attach fn put(this: value&, i: usize, x: T) -> node_error!void {
    val v = js(this.env, x);
    try check(this.env, napi::napi_set_element(this.env, this.v, @cast<u32>(i), v.v), "setting an element");
}

// calls this JS function with the arguments (converted with js); a JS exception is the error
<Args: type...>
public attach fn call(this: value&, args: Args...) -> node_error!value {
    var argv: std::vec<napi::napi_value__*> = {};
    comptime for (a) in args {
        val v = js(this.env, copy a); // an element can't be moved out of (a std::string)
        argv.push(v.v) catch return node_error::THROWN(std::string::from("out of memory"));
    }
    var recv: napi::napi_value__* = null;
    napi::napi_get_undefined(this.env, &recv);
    var r: napi::napi_value__* = null;
    var first: napi::napi_value__** = null;
    if (argv.len > 0) {
        first = &argv.items()[0];
    }
    try check(this.env, napi::napi_call_function(this.env, recv, this.v, argv.len, first, &r), "calling a function");
    return { env: this.env, v: r };
}
