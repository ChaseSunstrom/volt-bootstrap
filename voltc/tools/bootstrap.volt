// The self-hosting check, run by `bolt build bootstrap` from the voltc package directory (it works
// from the repository root, where the tests' paths start). stage1 is
// the voltc bolt just built (with the bootstrap compiler) next to this program. stage1 builds
// stage2, stage2 builds stage3; stage2 and stage3 must emit the same C for the compiler, and
// stage2 must pass the golden suite (tests/run and examples: stdout and exit code) with both
// backends and build libraries a program links against (C and LLVM mixed, both ways round). stage2
// also builds the compiler through LLVM, and that compiler must compile itself exactly as stage2 does.
use std::io;
use { "dirent.h", "unistd.h" } as sys;

fn die(msg: std::string) -> never {
    std::eprintln("bootstrap: {}", msg);
    std::process::exit(1);
}

// the .volt files in a directory, sorted
fn volt_files(dir: str) -> std::vec<std::string> {
    var p = std::string::from(dir);
    val d = sys::opendir(p.c_str()) ?? die(std::string::from("can't read a directory"));
    var out: std::vec<std::string> = {};
    loop {
        val e = sys::readdir(d) ?? break;
        var name: std::string = {};
        for (b) in e.d_name {
            if (b == 0) {
                break;
            }
            name.push(@cast<u8>(b));
        }
        val n = name.as_str();
        if (n.len > 5 && n[n.len - 5..n.len] == ".volt") {
            var full = std::string::from(dir);
            full.push(47); // '/'
            full.append(n);
            out.push(move full) catch @panic("out of memory");
        }
    }
    sys::closedir(d);
    // insertion sort: a few dozen names
    for (i) in 1..out.len {
        var j = i;
        while (j > 0 && less(out.at(j).as_str(), out.at(j - 1).as_str())) {
            val a = @read(out.at(j));
            @write(out.at(j), @read(out.at(j - 1)));
            @write(out.at(j - 1), move a);
            j -= 1;
        }
    }
    return move out;
}

// byte order; a prefix sorts first
fn less(a: str, b: str) -> bool {
    var i: usize = 0;
    while (i < a.len && i < b.len) {
        if (a[i] != b[i]) {
            return a[i] < b[i];
        }
        i += 1;
    }
    return a.len < b.len;
}

// the directory this program is in
fn self_dir() -> std::string {
    var buf: u8[4096];
    val n = sys::readlink("/proc/self/exe", @cast<cstr>(&buf[0]), 4095);
    if (n <= 0) {
        die(std::string::from("can't find this program's path"));
    }
    val exe = @cast<str>(@slice(&buf[0], @cast<usize>(n)));
    var end = exe.len;
    while (end > 0 && exe[end - 1] != 47) {
        end -= 1;
    }
    return std::string::from(exe[0..end]);
}

// run a program; its output (stdout and stderr), dying with them when it fails
fn must(argv: str[..], what: str) -> std::process::output {
    val r = std::process::capture(argv, "") catch |e| die(std::string::from("can't run a compiler"));
    if (r.code != 0) {
        std::eprint("{}{}", r.out, r.err);
        var m = std::string::from(what);
        m.append(" failed");
        die(move m);
    }
    return move r;
}

// stage builds the compiler into out, with a backend (c or llvm); the compiler links libLLVM and libclang,
// with the C args bolt linked stage1 with (build.volt's, from llvm-config), or from the default paths
// when this runs outside bolt
fn build(stage: str, srcs: std::vec<std::string>&, std_dir: str, out: str, backend: str) -> void {
    var given = std::process::env("BOLT_CC_ARGS") ?? "";
    if (given.len == 0) {
        given = "-lLLVM\n-lclang";
    }
    val cc_args = given.split("\n");
    var argv: std::vec<str> = {};
    argv.push(stage) catch @panic("out of memory");
    argv.push("build") catch @panic("out of memory");
    for (s&) in srcs.items() {
        argv.push(s.as_str()) catch @panic("out of memory");
    }
    argv.push("--std") catch @panic("out of memory");
    argv.push(std_dir) catch @panic("out of memory");
    argv.push("--backend") catch @panic("out of memory");
    argv.push(backend) catch @panic("out of memory");
    for (a) in cc_args.items() {
        if (a.len > 0) {
            argv.push("--cc") catch @panic("out of memory");
            argv.push(a) catch @panic("out of memory");
        }
    }
    argv.push("-o") catch @panic("out of memory");
    argv.push(out) catch @panic("out of memory");
    must(argv.items(), out);
}

// the C (emit-c) or LLVM IR (emit-llvm) a stage makes of the compiler
fn emit(stage: str, srcs: std::vec<std::string>&, std_dir: str, what: str) -> std::string {
    var argv: std::vec<str> = {};
    argv.push(stage) catch @panic("out of memory");
    argv.push(what) catch @panic("out of memory");
    for (s&) in srcs.items() {
        argv.push(s.as_str()) catch @panic("out of memory");
    }
    argv.push("--std") catch @panic("out of memory");
    argv.push(std_dir) catch @panic("out of memory");
    val r = must(argv.items(), stage);
    return copy r.out;
}

// the `// key: ` lines of a test
fn directives(src: str, key: str, out: std::vec<str>&) -> void {
    var i: usize = 0;
    while (i < src.len) {
        var e = i;
        while (e < src.len && src[e] != 10) {
            e += 1;
        }
        var l = src[i..e];
        while (l.len > 0 && (l[0] == 32 || l[0] == 9)) {
            l = l[1..l.len];
        }
        val tag_len = key.len + 4; // "// " + key + ":"
        if (l.len >= tag_len && l[0..3] == "// " && l[3..3 + key.len] == key && l[3 + key.len] == 58) {
            var r = l[tag_len..l.len];
            if (r.len > 0 && r[0] == 32) {
                r = r[1..r.len];
            }
            out.push(r) catch @panic("out of memory");
        }
        i = e + 1;
    }
}

fn trim_end(s: str) -> str {
    var e = s.len;
    while (e > 0 && (s[e - 1] == 10 || s[e - 1] == 32 || s[e - 1] == 13 || s[e - 1] == 9)) {
        e -= 1;
    }
    return s[0..e];
}

// the decimal digits in s as a number (anything else is skipped)
fn parse_int(s: str) -> i32 {
    var v: i32 = 0;
    for (c) in s {
        if (c >= 48 && c <= 57) {
            v = v * 10 + @cast<i32>(c - 48);
        }
    }
    return v;
}

// a test's `// expect:` lines, joined
fn expected(src: str) -> std::string {
    var expects: std::vec<str> = {};
    directives(src, "expect", &expects);
    var want: std::string = {};
    for (i) in 0..expects.len {
        if (i > 0) {
            want.push(10);
        }
        want.append(*expects.at(i));
    }
    return move want;
}

// stage's `lib` output works: libstd.a and a package's .a (built with one backend), linked into a
// program (built with another) instead of compiling their sources (as tests/golden.rs std_linked
// does with the bootstrap compiler)
fn linked(stage: str, std_dir: str, dir: str, lib_backend: str, prog_backend: str) -> void {
    var std_a = std::string::from(dir);
    std_a.append("libstd.a");
    var geo_a = std::string::from(dir);
    geo_a.append("libgeo.a");
    val lib_std: str[9] = { stage, "lib", "std", "--std", std_dir, "--backend", lib_backend, "-o", std_a.as_str() };
    must(lib_std, "stage2 lib std");
    val lib_geo: str[11] = { stage, "lib", "geo", "--std", std_dir, "--pkg", "geo=tests/pkgs/geo", "--backend", lib_backend, "-o", geo_a.as_str() };
    must(lib_geo, "stage2 lib geo");
    var std_link = std::string::from("std=");
    std_link.append(std_a.as_str());
    var geo_link = std::string::from("geo=");
    geo_link.append(geo_a.as_str());
    val prog = "tests/run/packages_linked.volt";
    val run: str[14] = { stage, "run", prog, "--std", std_dir, "--pkg", "geo=tests/pkgs/geo", "--backend", prog_backend, "--leak-check", "--link", std_link.as_str(), "--link", geo_link.as_str() };
    val r = must(run, "a program linked against stage2's libraries");
    val src = std::fs::read_file(prog) catch |e| die(std::string::from("can't read a test"));
    val want = expected(src.as_str());
    if (trim_end(r.out.as_str()) != trim_end(want.as_str())) {
        std::eprintln("--- want\n{}\n--- got\n{}", want, r.out);
        die(std::string::from("a program linked against stage2's libraries printed the wrong thing"));
    }
    std::println("stage2 lib: {} libraries in a {} program ok", lib_backend, prog_backend);
}

// run every golden test with stage and a backend; the failures
fn golden(stage: str, std_dir: str, backend: str) -> i32 {
    var files = volt_files("tests/run");
    for (f&) in volt_files("examples").items() {
        files.push(copy *f) catch @panic("out of memory");
    }
    var failed: i32 = 0;
    for (f&) in files.items() {
        val src = std::fs::read_file(f.as_str()) catch |e| die(std::string::from("can't read a test"));
        val want = expected(src.as_str());
        var exits: std::vec<str> = {};
        directives(src.as_str(), "exit", &exits);
        // `// exit: N|M`: any of them (a trap is SIGILL on x86-64, SIGTRAP on arm64)
        var want_text = "0";
        if (exits.len > 0) {
            want_text = *exits.at(0);
        }
        var want_codes: std::vec<i32> = {};
        var from: usize = 0;
        for (i) in 0..want_text.len + 1 {
            if (i == want_text.len || want_text[i] == 124) {
                want_codes.push(parse_int(want_text[from..i])) catch @panic("out of memory");
                from = i + 1;
            }
        }
        var flags: std::vec<str> = {};
        directives(src.as_str(), "flags", &flags);
        var argv: std::vec<str> = {};
        argv.push(stage) catch @panic("out of memory");
        argv.push("run") catch @panic("out of memory");
        argv.push(f.as_str()) catch @panic("out of memory");
        argv.push("--std") catch @panic("out of memory");
        argv.push(std_dir) catch @panic("out of memory");
        argv.push("--backend") catch @panic("out of memory");
        argv.push(backend) catch @panic("out of memory");
        // flags lines hold space-separated options
        for (l&) in flags.items() {
            var i: usize = 0;
            val s = *l;
            while (i < s.len) {
                while (i < s.len && s[i] == 32) {
                    i += 1;
                }
                var e = i;
                while (e < s.len && s[e] != 32) {
                    e += 1;
                }
                if (e > i) {
                    argv.push(s[i..e]) catch @panic("out of memory");
                }
                i = e;
            }
        }
        val r = std::process::capture(argv.items(), "") catch |e| die(std::string::from("can't run a test"));
        var code_ok = false;
        for (c) in want_codes.items() {
            if (c == r.code) {
                code_ok = true;
            }
        }
        if (trim_end(r.out.as_str()) != trim_end(want.as_str()) || !code_ok) {
            std::eprintln("FAIL {}: exit {} (want {})\n--- want\n{}\n--- got\n{}\n--- stderr\n{}", f, r.code, want_text, want, r.out, r.err);
            failed += 1;
        }
    }
    std::println("golden: {} of {} passed with stage2 ({})", @cast<i32>(files.len) - failed, files.len, backend);
    return failed;
}

fn main() -> i32 {
    var dir = self_dir();
    var stage1 = copy dir;
    stage1.append("voltc");
    var stage2 = copy dir;
    stage2.append("voltc-stage2");
    var stage3 = copy dir;
    stage3.append("voltc-stage3");
    var stage3l = copy dir;
    stage3l.append("voltc-stage3-llvm");
    // this runs in voltc/ (bolt's package directory); the tests' paths start at the repository root
    if (sys::chdir("..") != 0) {
        die(std::string::from("can't go to the repository root"));
    }
    val std_dir = std::process::env("VOLT_STD") ?? "std";
    val srcs = volt_files("voltc/src");
    // stage1 (bolt's voltc, next to this program) builds stage2, stage2 builds stage3
    build(stage1.as_str(), &srcs, std_dir, stage2.as_str(), "c");
    std::println("stage2 built by stage1");
    build(stage2.as_str(), &srcs, std_dir, stage3.as_str(), "c");
    std::println("stage3 built by stage2");
    val c2 = emit(stage2.as_str(), &srcs, std_dir, "emit-c");
    val c3 = emit(stage3.as_str(), &srcs, std_dir, "emit-c");
    if (c2.as_str() != c3.as_str()) {
        die(std::string::from("stage2 and stage3 compile the compiler differently"));
    }
    std::println("stage2 == stage3 ({} bytes of C)", c3.len());
    // the compiler built by its own LLVM backend must compile itself the same way, to C and to LLVM
    build(stage2.as_str(), &srcs, std_dir, stage3l.as_str(), "llvm");
    std::println("stage3-llvm built by stage2 through LLVM");
    if (emit(stage3l.as_str(), &srcs, std_dir, "emit-c").as_str() != c2.as_str()) {
        die(std::string::from("stage3-llvm and stage2 compile the compiler to different C"));
    }
    val l2 = emit(stage2.as_str(), &srcs, std_dir, "emit-llvm");
    if (emit(stage3l.as_str(), &srcs, std_dir, "emit-llvm").as_str() != l2.as_str()) {
        die(std::string::from("stage3-llvm and stage2 compile the compiler to different LLVM IR"));
    }
    std::println("stage3-llvm == stage2 (C, and {} bytes of LLVM IR)", l2.len());
    // stage2's libraries linked into stage2's programs, mixing the backends
    linked(stage2.as_str(), std_dir, dir.as_str(), "c", "c");
    linked(stage2.as_str(), std_dir, dir.as_str(), "c", "llvm");
    linked(stage2.as_str(), std_dir, dir.as_str(), "llvm", "c");
    // the golden suite with stage2, through each backend
    var failed = golden(stage2.as_str(), std_dir, "c");
    failed += golden(stage2.as_str(), std_dir, "llvm");
    if (failed != 0) {
        return 1;
    }
    return 0;
}
