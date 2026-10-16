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
fn shown_kind(what: str, r: cpp::cpp_error!i32) -> void {
    val n = r catch |e| {
        std::println("{}: {}", what, e);
        return;
    };
    std::println("{}: {}", what, n);
}
fn only_fail(k: i32) -> i32 {
    return @cpp<cpp::cpp_error!i32>("pr::pu::nonneg({0})", k) catch |e| { return 96; };
}
fn main() -> void {
    show("nested ok", cpp::pr::try_apply(then_ok, -1));
    shown_kind("nested fail", cpp::pr::try_apply(then_fail, -1));
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
    std::println("plain {}", @cpp<i32>("pr::pu::nonneg({0})", 3));
}
