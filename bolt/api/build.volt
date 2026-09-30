// The bolt build API: package `bolt`, available to build files (see [build] in bolt.toml).
// A build file is an ordinary Volt program; each call below prints one "@bolt" line, and bolt
// carries them out after the build file finishes. Other output is shown as-is.

// arguments travel on one tab-separated line, so they can't hold tabs or newlines
fn check(s: str) -> void {
    for (c) in s {
        if (c == 9 || c == 10 || c == 13) {
            @panic("bolt: build-file arguments can't contain tabs or newlines");
        }
    }
}

// -Dname=value from the bolt command line, or `fallback`
fn option(name: str, fallback: str) -> str {
    var i: usize = 1;
    while (i < std::process::arg_count()) {
        val a = std::process::arg(i) ?? "";
        if (a.len > name.len + 2 && a[0..2] == "-D" && a[2..2 + name.len] == name && a[2 + name.len] == 61) { // 61 = '='
            return a[3 + name.len..a.len];
        }
        i++;
    }
    return fallback;
}

// another executable, built from .volt files and directories (relative to the package)
<Paths: type...>
fn exe(name: str, paths: Paths...) -> void {
    check(name);
    std::io::print("@bolt\texe\t{}", name);
    comptime for (p) in paths {
        comptime if (@typeof(p) == str) {
            check(p);
        }
        std::io::print("\t{}", p);
    }
    std::io::println("");
}

// one more .volt file in every executable
fn source(path: str) -> void {
    check(path);
    std::io::println("@bolt\tsource\t{}", path);
}

// a C file compiled into every executable
fn c_source(path: str) -> void {
    check(path);
    std::io::println("@bolt\tc_source\t{}", path);
}

// a C library linked into every executable (-lNAME)
fn link_c(name: str) -> void {
    check(name);
    std::io::println("@bolt\tlink_c\t{}", name);
}

// a named step: `bolt build NAME` runs it (after the steps it depends on)
fn step(name: str) -> void {
    check(name);
    std::io::println("@bolt\tstep\t{}", name);
}

// the step runs a program
<Args: type...>
fn cmd(step: str, program: str, args: Args...) -> void {
    check(step);
    check(program);
    std::io::print("@bolt\tcmd\t{}\t{}", step, program);
    comptime for (a) in args {
        comptime if (@typeof(a) == str) {
            check(a);
        }
        std::io::print("\t{}", a);
    }
    std::io::println("");
}

// the step runs one of this package's executables (building everything first)
<Args: type...>
fn run(step: str, exe: str, args: Args...) -> void {
    check(step);
    check(exe);
    std::io::print("@bolt\trun\t{}\t{}", step, exe);
    comptime for (a) in args {
        comptime if (@typeof(a) == str) {
            check(a);
        }
        std::io::print("\t{}", a);
    }
    std::io::println("");
}

// `step` needs `on` to run first ("install" builds every executable)
fn depends(step: str, on: str) -> void {
    check(step);
    check(on);
    std::io::println("@bolt\tdepends\t{}\t{}", step, on);
}

// is feature `name` of this package on? (bolt passes them as BOLT_FEATURE_<NAME>, - as _)
fn feature(name: str) -> bool {
    var key = std::string::from("BOLT_FEATURE_");
    for (c) in name {
        if (c >= 'a' && c <= 'z') {
            key.push(c - 32);
        } else if (c == '-') {
            key.push('_');
        } else {
            key.push(c);
        }
    }
    return std::process::env(key.as_str()) != null;
}

// the profile being built: dev, release, test, bench or a custom one
fn profile() -> str {
    return std::process::env("BOLT_PROFILE") ?? "dev";
}
