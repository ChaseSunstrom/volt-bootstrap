use std::io;
// comptime if chains: after `comptime if`, a plain `else if` is decided in the compiler too, and so
// is an `else comptime if`, even after a run-time if. Branches not taken aren't checked.

fn os_name() -> str {
    comptime if (@cfg("os", "plan9")) {
        return plan9_name();
    } else if (@cfg("os", "linux") || @cfg("os", "macos") || @cfg("os", "freebsd") || @cfg("os", "windows")) {
        return "known";
    } else {
        return other_name();
    }
}

<N: i32>
fn size() -> str {
    comptime if (N < 10) {
        return "small";
    } else comptime if (N < 1000) {
        return "medium";
    } else {
        return "large";
    }
}

fn pick(x: i32) -> str {
    if (x > 0) {
        return "positive";
    } else comptime if (@cfg("os", "plan9")) {
        return plan9_name();
    } else {
        return "not positive";
    }
}

fn main() -> void {
    std::println("{} {} {} {} {} {}", os_name(), size<3>(), size<50>(), size<5000>(), pick(1), pick(-1));
}
// expect: known small medium large positive not positive
