// a Node.js addon written in Volt with interop/node: numbers, strings, arrays, objects, JS
// callbacks, and errors thrown both ways

fn add(c: node::call&) -> node::node_error!node::value {
    return c.number(try c.arg(0).to_f64() + try c.arg(1).to_f64());
}

fn greet(c: node::call&) -> node::node_error!node::value {
    var s = std::string::from("hello, ");
    s.append((try c.arg(0).to_string()).as_str());
    return c.string(s.as_str());
}

// sum of an array of numbers
fn sum(c: node::call&) -> node::node_error!node::value {
    val xs = c.arg(0);
    var total = 0.0;
    for (i) in 0..try xs.length() {
        total += try (try xs.at(i)).to_f64();
    }
    return c.number(total);
}

// { x, y, label: "point" }, and an array [x, y]
fn point(c: node::call&) -> node::node_error!node::value {
    val p = c.object();
    try p.set("x", try c.arg(0).to_f64());
    try p.set("y", try c.arg(1).to_f64());
    try p.set("label", "point");
    val pair = c.array();
    try pair.put(0, try c.arg(0).to_i64());
    try pair.put(1, try c.arg(1).to_i64());
    try p.set("pair", pair);
    return p;
}

// calls back into JS: f(x, "from volt"), the text built as a std::string
fn apply(c: node::call&) -> node::node_error!node::value {
    val f = c.arg(0);
    return f.call(try c.arg(1).to_f64(), std::fmt::format("from {}", "volt"));
}

// a Volt error becomes a JS Error
fn fails(c: node::call&) -> node::node_error!node::value {
    return node::node_error::THROWN(std::string::from("volt says no"));
}

// a JS exception from a callback comes back as an error, which this reports
fn catches(c: node::call&) -> node::node_error!node::value {
    val r = c.arg(0).call();
    if (r.err) {
        return c.string(std::fmt::format("caught {}", r.err).as_str());
    }
    return c.string("nothing thrown");
}

fn kinds(c: node::call&) -> node::node_error!node::value {
    val out = c.array();
    for (i) in 0..c.len() {
        try out.put(i, c.arg(i).type_of());
    }
    return out;
}

export fn napi_register_module_v1(env: void*, exports: void*) -> void* {
    var m = node::init(env, exports);
    m.function("add", add) catch |e| {};
    m.function("greet", greet) catch |e| {};
    m.function("sum", sum) catch |e| {};
    m.function("point", point) catch |e| {};
    m.function("apply", apply) catch |e| {};
    m.function("fails", fails) catch |e| {};
    m.function("catches", catches) catch |e| {};
    m.function("kinds", kinds) catch |e| {};
    return m.exports();
}
