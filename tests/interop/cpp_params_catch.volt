// @cpp<cpp_error!R>(...) runs its C++ in catch mode, as a try_ form does: a throw is the error (mapped
// as a try_ form maps it), a normal return the value; a std::string& is left as it was on a throw
use std::io;
use { "params.hpp" } as cpp;
fn show(what: str, r: cpp::cpp_error!i32) -> void {
    val n = r catch |e| {
        std::println("{}: {} {}", what, e, cpp::last_exception());
        return;
    };
    std::println("{}: {}", what, n);
}
fn shown(what: str, r: cpp::cpp_error!void) -> void {
    r catch |e| {
        std::println("{}: {} {}", what, e, cpp::last_exception());
        return;
    };
    std::println("{}: done", what);
}
// a template taking the Volt string as a C++ std::string&: C++ changed its copy before throwing
fn grown(t: std::string&, k: i32) -> void {
    val n = @cpp<cpp::cpp_error!i32, std::string>("pr::gs::grow<{t0}>({0}, {1})", t, k) catch |e| {
        std::println("grow {}: {} {}", k, e, t.as_str());
        return;
    };
    std::println("grow {}: {} {}", k, n, t.as_str());
}
// an argument with a side of its own: worked out once, before catch mode
fn bump() -> i32 {
    std::println("bump");
    return -2;
}
// a fn C++ calls through a pointer runs in the outer call's catch mode: its plain call's throw is
// the outer call's error, and a catching call it makes after that (a scope of its own, failing or
// not) leaves it so
fn inc(x: i32) -> i32 { return x + 1; }
fn seven() -> i32 { return 7; }
extern "C" fn snprintf(buf: u8*, n: usize, fmt: cstr, ...) -> i32;
extern "C" fn strlen(s: cstr) -> usize;
fn text_len(s: cstr) -> i32 { return @cast<i32>(strlen(s)); }
fn maybe_name(x: i32) -> cstr? {
    if (x > 0) {
        return "abc";
    }
    return null;
}
fn set_len(n: usize*) -> void { *n = 5; }
fn opt_len(s: cstr?) -> i32 {
    val t = s ?? return -1;
    return @cast<i32>(strlen(t)) * 10;
}
fn then_ok(k: i32) -> i32 {
    val z = cpp::pr::pu::nonneg(k);
    val n = @cpp<cpp::cpp_error!i32>("pr::pu::nonneg(1)") catch |e| { return 98; };
    return z + n;
}
fn then_fail(k: i32) -> i32 {
    val z = cpp::pr::pu::nonneg(k);
    @cpp<cpp::cpp_error!void>("pr::pu::boom({0}, {1})", 1, 2) catch |e| {
        std::println("inner: {}", e);
        return 97;
    };
    return z;
}
fn only_fail(k: i32) -> i32 {
    return @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", k) catch |e| { return 96; };
}
fn main() -> void {
    show("nested ok", cpp::pr::try_apply(then_ok, -1));
    show("nested fail", cpp::pr::try_apply(then_fail, -1));
    show("inner only", cpp::pr::try_apply(only_fail, -1));
    show("bumped", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", bump()));
    var b = std::string::from("b");
    show("tbumped", @cpp<cpp::cpp_error!i32, std::string>("pr::gs::grow<{t0}>({0}, {1})", &b, bump()));
    std::println("b {}", b);
    show("nonneg 4", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", 4));
    show("nonneg -4", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", -4));
    shown("boom 1", @cpp<cpp::cpp_error!void>("pr::pu::boom({0})", 1));
    shown("boom 2", @cpp<cpp::cpp_error!void>("pr::pu::boom({0}, {1})", 1, 2));
    // a thrown value that isn't a std::exception, and std::bad_alloc
    show("throw 42", @cpp<cpp::cpp_error!i32>("(throw 42, 0)"));
    shown("bad_alloc", @cpp<cpp::cpp_error!void>("throw std::bad_alloc()"));
    var t = std::string::from("hi");
    grown(&t, 2);
    grown(&t, -1);
    // in a callback C++ called, the catch is the callback's own, and catch mode ends with it
    std::println("relay {}", cpp::pr::relay(|| (k: i32) -> i32 { return @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", k) catch |e| { return 99; }; }));
    show("nonneg -5", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", -5));
    // its arguments are plain @cpp<R>'s: a fn name a function pointer (a throw in the C++ after it
    // calls the fn, or in the fn itself, is the error), a reference the object it names, a slice a
    // volt_slice; the plain twins after
    show("apply 41", @cpp<cpp::cpp_error!i32>("pr::apply({0}, {1})", inc, 41));
    show("apply -5", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg(pr::apply({0}, {1}))", inc, -5));
    show("apply nested", @cpp<cpp::cpp_error!i32>("pr::apply({0}, {1})", then_ok, -1));
    var q = -2;
    show("ref -2", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", &q));
    val ys: i32[2] = { 3, -4 };
    show("slice 0", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0}.ptr[0])", ys[..]));
    show("slice 1", @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0}.ptr[1])", ys[..]));
    q = 5;
    std::println("plain {} {} {} {}", @cpp<i32>("pr::pu::nonneg({0})", 3), @cpp<i32>("pr::apply({0}, {1})", inc, 41), @cpp<i32>("pr::pu::nonneg({0})", &q), @cpp<i32>("{0}.ptr[0]", ys[..]));
    // a fn of no parameters and a C variadic one as function pointers: @cpp<R>'s {i} and {&i}, and
    // calls worked out per use
    std::println("fns {} {} {} {} {}", @cpp<i32>("{0}()", seven), @cpp<i32>("{&0}()", seven), cpp::pr::call0(seven), @cpp<i32>("pr::callv({0})", snprintf), cpp::pr::callv(snprintf));
    show("fns caught", @cpp<cpp::cpp_error!i32>("pr::callv({0})", snprintf));
    // a declared function's variadic function pointer parameter (size_t, const char *: snprintf's
    // usize and cstr)
    std::println("fmt {}", cpp::pr::apply_fmt(snprintf, 345));
    // per use, a fn's cstr and cstr? both cross as const char *; an operator's operand is a function
    // pointer too
    val tally = cpp::pr::rp::Tally<i32>::new(3);
    std::println("text {} op {}", cpp::pr::callc(text_len, opt_len), tally.op_bitor(inc));
    // declared: a const char * result is a cstr? (null too), a size_t * parameter a usize*
    std::println("names {} {} len {}", cpp::pr::name_len(maybe_name, 1), cpp::pr::name_len(maybe_name, 0), cpp::pr::fill_len(set_len));
}
