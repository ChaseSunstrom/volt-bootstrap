// voltc: the command line. A port of bootstrap/main.rs.
// It adds emit-llvm and --backend llvm (lgen.volt); `parse` only prints the canonical --sexp form.
use std::io;
use { "dirent.h", "poll.h", "unistd.h" } as sys;

// a --pkg or --link argument: NAME=PATH
struct pkg_arg {
    name: str;
    path: str;
}

// the parsed command line
struct cli {
    cmd: str;
    // the positional arguments: source files (for `lib`, the package name)
    files: std::vec<str> = {};
    out: str? = null;
    std_dir: str? = null;
    no_std: bool = false;
    pkgs: std::vec<pkg_arg> = {};
    links: std::vec<pkg_arg> = {};
    cc_args: std::vec<str> = {};
    c_std: str = "";   // --cc -std=c11: C imports' standard
    cpp_std: str = ""; // --cc -std=c++17: C++ imports'
    c_unit_std: str = "gnu11"; // what Volt's own C is compiled under
    cfg: std::vec<cfg_arg> = {}; // --cfg [PKG:]KEY[=VALUE]
    lib: str? = null;             // check --lib NAME
    shared: bool = false;         // lib --shared: a self-contained shared library, for any language
    standalone: bool = false;     // lib --static: a self-contained static library, for any language
    lang: str = "c";              // bindings --lang
    release: bool = false;
    leak_check: bool = false;
    test: bool = false; // build the program's test blocks instead of its main
    test_pkgs: std::vec<str> = {}; // and these packages' test blocks too
    profiler: bool = false; // --profiler: bolt hot's sampler, line info and frame pointers
    sexp: bool = false;
    llvm: bool = false;        // through the LLVM backend (--backend llvm, or the default where it's complete)
    backend_set: bool = false; // --backend (or --target) chose it: no falling back to C
    target: str? = null;      // --target: bare metal (target.volt), through LLVM and ld.lld
    link_script: str? = null; // --link-script: the linker script for --target
    format: u8 = 0;     // --message-format (FORMAT_HUMAN, FORMAT_SHORT, FORMAT_JSON)
    color: str = "auto"; // --color auto|always|never
    error_limit: usize = 20; // --error-limit: errors shown (0: all)
    expand_line: usize = 0;  // voltc expand FILE:LINE (0: every line)
    // everything after `--`: the arguments for `run`'s program
    prog_args: std::vec<str> = {};
}

fn usage() -> never {
    std::eprintln("usage: voltc <command> FILES... [options]\ncommands:\n  parse FILE --sexp       parse only\n  check FILES            type check\n  expand FILE[:LINE] ... what the comptime code (on that line) became: values, branches, comptime\n                         for copies, generic instances, built types, declared fns and @derive output\n  emit-c FILES [-o DIR]  print the generated C, or write it as files to DIR\n  emit-llvm FILES        print the generated LLVM IR\n  build FILES [-o OUT]   compile to an executable\n  run FILES [-- ARGS]    build and run\n  lib NAME [-o OUT.a]    precompile package NAME's non-generic code into a static library; with\n                         --shared (OUT.so) or --static, a self-contained library other languages link\n  bindings NAME --lang L bindings of package NAME's export fns for L: c, cpp, rust, zig, python, pyi\n                         (its stubs), csharp, java, go, lua (a C module), dart, swift, kotlin, ruby (a C\n                         extension), node (a Node-API addon's C), js (its loader), ts (its types), or\n                         json (the model, for generators of your own)\n  std-dir                print where the std package is\n  lsp                    the language server for editors (JSON-RPC on stdin and stdout)\n  doc NAME               package NAME's declarations and their comments, as JSON\noptions:\n  --release              optimize, wrap on overflow instead of trapping\n  --leak-check           debug: exit 102 if runtime allocations were never freed\n  --test                 build the program's test blocks (test \"name\" { ... }) instead of its main\n  --test-pkg NAME        with --test, package NAME's test blocks too\n  --profiler             sample where the program spends its time (bolt hot reads it): line info,\n                         frame pointers, and a sampler that writes $VOLT_PROFILE_OUT at exit\n  --std DIR | --no-std   where the std package is (default: $VOLT_STD, then next to voltc)\n  --pkg NAME=PATH        a package: PATH's .volt files, wrapped in namespace NAME\n  --cfg [PKG:]KEY[=VAL]  set KEY (to VAL) for @cfg in the program's files, or in package PKG's\n  --lib NAME             check: package NAME alone, as a library (no program files, no main)\n  --link NAME=LIB.a      take package NAME's non-generic code from a library built by voltc lib\n  --cc ARG               pass ARG to the C compiler when linking (a .c file, -lNAME, ...)\n  --message-format F     how errors are printed: human (default), short (one line each) or json\n  --color WHEN           colour errors: auto (default: on a terminal, unless NO_COLOR is set), always, never\n  --error-limit N        show at most N errors (default 20; 0: all of them)\n  --backend c|llvm       generate C, or native code through LLVM (the default on x86-64 and\n                         aarch64 but for Windows; a program LLVM can't lower falls back to C)\n  --target T             bare metal through LLVM, linked by ld.lld with no C at all: riscv32-none,\n                         riscv64-none, thumbv6m-none, thumbv7m-none or thumbv7em-none\n  --link-script FILE     the linker script for --target (memory layout, the start code's symbols)");
    std::process::exit(2);
}

// print an error, remove this run's build directories and stop
fn die(msg: std::string) -> never {
    std::eprintln("voltc: {}", msg);
    remove_build_dirs();
    std::process::exit(1);
}

// the build directories this run made (fresh_dir): a failed build removes them and their files
var build_dirs: std::vec<std::string> = {};

fn remove_build_dirs() -> void {
    for (d&) in build_dirs.items() {
        val names = list_dir(d.as_str()) ?? continue;
        for (n&) in names.items() {
            var p = copy *d;
            p.push('/');
            p.append(n.as_str());
            unlink_path(p.as_str());
        }
        rmdir_path(d.as_str());
    }
}

// the command, then files and options in any order; a malformed line prints the usage and exits
fn parse_cli() -> cli {
    var c: cli = { cmd: std::process::arg(1) ?? usage() };
    var i: usize = 2;
    while (i < std::process::arg_count()) {
        val a = std::process::arg(i) ?? "";
        i += 1;
        if (a == "--shared") {
            c.shared = true;
        } else if (a == "--static") {
            c.standalone = true;
        } else if (a == "--release") {
            c.release = true;
        } else if (a == "--profiler") {
            c.profiler = true;
        } else if (a == "--leak-check") {
            c.leak_check = true;
        } else if (a == "--test") {
            c.test = true;
        } else if (a == "--test-pkg") {
            c.test = true;
            put(&c.test_pkgs, std::process::arg(i) ?? usage());
            i += 1;
        } else if (a == "--sexp") {
            c.sexp = true;
        } else if (a == "--no-std") {
            c.no_std = true;
        } else if (a == "-o" || a == "--std" || a == "--cc" || a == "--pkg" || a == "--link" || a == "--backend" || a == "--message-format" || a == "--color" || a == "--error-limit" || a == "--cfg" || a == "--lib" || a == "--lang" || a == "--target" || a == "--link-script") {
            val v = std::process::arg(i) ?? usage();
            i += 1;
            if (a == "--message-format") {
                if (v == "human") {
                    c.format = FORMAT_HUMAN;
                } else if (v == "short") {
                    c.format = FORMAT_SHORT;
                } else if (v == "json") {
                    c.format = FORMAT_JSON;
                } else {
                    die(S("--message-format takes human, short or json"));
                }
            } else if (a == "--error-limit") {
                if (v.len == 0) {
                    die(S("--error-limit takes a number (0: no limit)"));
                }
                var n: usize = 0;
                for (ch) in v {
                    if (ch < '0' || ch > '9') {
                        die(S("--error-limit takes a number (0: no limit)"));
                    }
                    n = n * 10 + (ch - '0') as usize;
                }
                c.error_limit = n;
            } else if (a == "--color") {
                if (v != "auto" && v != "always" && v != "never") {
                    die(S("--color takes auto, always or never"));
                }
                c.color = v;
            } else if (a == "--backend") {
                if (v != "c" && v != "llvm") {
                    die(fmt("--backend takes c or llvm, not '{}'", S(v)));
                }
                c.llvm = v == "llvm";
                c.backend_set = true;
            } else if (a == "--target") {
                // bare metal: @cfg sees os=none and the target's arch and pointer size
                val t = find_target(v) ?? die(fmt2("--target takes one of {}, not '{}'", target_names(), S(v)));
                c.target = v;
                c.llvm = true;
                c.backend_set = true;
                for (set) in t.cfg {
                    put(&c.cfg, { pkg: null, set: set });
                }
            } else if (a == "--link-script") {
                c.link_script = v;
            } else if (a == "-o") {
                c.out = v;
            } else if (a == "--std") {
                c.std_dir = v;
            } else if (a == "--cc") {
                if (starts_with(v, "-std=")) {
                    // the standard C or C++ imports are read and compiled under, unless one says
                    // (@standard); Volt's own C keeps its own
                    if (contains(v, "++")) {
                        c.cpp_std = v[5..];
                    } else {
                        c.c_std = v[5..];
                    }
                } else {
                    put(&c.cc_args, v);
                }
            } else if (a == "--lib") {
                c.lib = v;
            } else if (a == "--lang") {
                c.lang = v;
            } else if (a == "--cfg") {
                // PKG: scopes it, when the part before ':' is a name (a value may hold ':' too)
                var colon: usize? = null;
                for (k) in 0..v.len {
                    if (colon == null && v[k] == '=') {
                        break;
                    }
                    if (colon == null && v[k] == ':') {
                        colon = k;
                    }
                }
                val at = colon ?? 0;
                if (at > 0) {
                    put(&c.cfg, { pkg: v[0..at], set: v[at + 1..v.len] });
                } else {
                    put(&c.cfg, { pkg: null, set: v });
                }
            } else {
                var eq: usize? = null;
                for (k) in 0..v.len {
                    if (v[k] == '=' && eq == null) {
                        eq = k;
                    }
                }
                val at = eq ?? die(fmt2("{} wants NAME=PATH, got '{}'", S(a), S(v)));
                val p: pkg_arg = { name: v[0..at], path: v[at + 1..v.len] };
                if (a == "--pkg") {
                    put(&c.pkgs, p);
                } else {
                    put(&c.links, p);
                }
            }
        } else if (a == "--stdio" && c.cmd == "lsp") {
            // what LSP clients (VS Code's, Neovim's...) pass to say the protocol goes over stdin
            // and stdout, which is the only way voltc lsp talks
        } else if (a == "--") {
            while (i < std::process::arg_count()) {
                put(&c.prog_args, std::process::arg(i) ?? "");
                i += 1;
            }
        } else if (a.len > 0 && a[0] == '-') {
            die(fmt("unknown option '{}'", S(a)));
        } else {
            // voltc expand FILE:LINE: a trailing :digits is the line
            var at = a.len;
            while (at > 0 && a[at - 1] >= '0' && a[at - 1] <= '9') {
                at -= 1;
            }
            if (c.cmd == "expand" && at > 1 && at < a.len && a[at - 1] == ':') {
                for (k) in at..a.len {
                    c.expand_line = c.expand_line * 10 + @cast<usize>(a[k] - '0');
                }
                put(&c.files, a[0..at - 1]);
            } else {
                put(&c.files, a);
            }
        }
    }
    if (c.files.len == 0 && c.cmd != "std-dir" && c.cmd != "lsp" && !(c.cmd == "check" && c.lib != null) && c.test_pkgs.len == 0) {
        usage();
    }
    if (c.target != null && !c.llvm) {
        die(S("--target builds through LLVM: leave out --backend c"));
    }
    // LLVM is the default backend where it's complete: x86-64 and aarch64 (Linux, macOS, FreeBSD).
    // Windows x64's calling convention is in, but voltc doesn't run there yet (C stays its default
    // until it can be tested there). A program LLVM can't lower is built through C instead
    if (!c.backend_set) {
        comptime if ((@cfg("arch", "x86_64") || @cfg("arch", "aarch64")) && !@cfg("os", "windows")) {
            c.llvm = true;
        }
    }
    if (c.target != null && (c.cmd == "run" || c.cmd == "lib")) {
        die(fmt("voltc {} doesn't take --target: build the program, then load it on the board (or qemu)", S(c.cmd)));
    }
    return c;
}

// the names in a directory, or none when it isn't one
fn list_dir(path: str) -> std::vec<std::string>? {
    var p = S(path);
    val d = sys::opendir(p.c_str()) ?? return null;
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
        if (name.as_str() != "." && name.as_str() != "..") {
            put(&out, move name);
        }
    }
    sys::closedir(d);
    return out;
}

// sorts by bytes (an insertion sort: a package has few files)
fn sort_strings(v: std::vec<std::string>&) -> void {
    for (i) in 1..v.len {
        var j = i;
        while (j > 0 && str_less(v.at(j).as_str(), v.at(j - 1).as_str())) {
            swap(v.at(j - 1), v.at(j));
            j -= 1;
        }
    }
}

// byte order; a prefix sorts first
fn str_less(a: str, b: str) -> bool {
    var i: usize = 0;
    while (i < a.len && i < b.len) {
        if (a[i] != b[i]) {
            return a[i] < b[i];
        }
        i += 1;
    }
    return a.len < b.len;
}

// every .volt file under path (sorted, so builds are reproducible), or path itself
fn volt_files(path: str) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    var dirs: std::vec<std::string> = {};
    val top = list_dir(path);
    if (top == null) {
        put(&out, S(path));
        return out;
    }
    put(&dirs, S(path));
    while (dirs.len > 0) {
        val d = dirs.pop() ?? break;
        val names = list_dir(d.as_str()) ?? die(fmt("can't read package directory {}", copy d));
        for (n&) in names.items() {
            var full = copy d;
            full.push('/');
            full.append(n.as_str());
            if (list_dir(full.as_str()) != null) {
                put(&dirs, move full);
            } else if (ends_with(n.as_str(), ".volt")) {
                put(&out, move full);
            }
        }
    }
    sort_strings(&out);
    return out;
}

// the std package: --std, $VOLT_STD, or a std/ directory next to (or above) voltc: installed
// (prefix/lib/volt/std), in cargo's target/<profile>/, or in bolt's voltc/target/<profile>/
fn find_std(c: cli&) -> std::string? {
    if (c.no_std) {
        return null;
    }
    if (c.std_dir) {
        return S(c.std_dir);
    }
    val e = std::process::env("VOLT_STD");
    if (e) {
        if (list_dir(e) == null) {
            die(fmt("$VOLT_STD is {}, which isn't a directory: point it at std, or unset it", S(e)));
        }
        return S(e);
    }
    val path = std::process::exe_path();
    if (path) {
        val exe = path.as_str();
        var dir_end = exe.len;
        while (dir_end > 0 && exe[dir_end - 1] != '/') {
            dir_end -= 1;
        }
        val dir = exe[0..dir_end];
        val cands: str[5] = { "std", "../std", "../../std", "../lib/volt/std", "../../../std" };
        for (cand) in cands {
            var p = S(dir);
            p.append(cand);
            if (list_dir(p.as_str()) != null) {
                // without the ../ steps: file names in messages and panics read plainly
                var real: u8[4096];
                val r = realpath(p.c_str(), &real[0]);
                if (r) {
                    return S(@cast<str>(@slice(@cast<u8*>(r), strlen(r))));
                }
                return p;
            }
        }
    }
    die(S("can't find the std package; pass --std DIR (or --no-std)"));
}

// a source file and the package it belongs to (none: the program's own)
struct unit {
    file: u32;
    pkg: str?;
}

// the program's sources: its own files, std and packages
struct sources {
    // names and texts own the files' contents; files, toks and asts point into them
    names: std::vec<std::string> = {};
    texts: std::vec<std::string> = {};
    files: std::vec<source_file> = {};
    units: std::vec<unit> = {};
    toks: std::vec<std::vec<token>> = {};
    asts: std::vec<std::vec<item>> = {}; // the checked program points into these (names, string literals)
    guard_names: std::vec<std::string> = {}; // packages' guard symbols (the program's globals name them)
    pkg_names: std::vec<std::string> = {};   // package names the units point into (the language server's)
    // test blocks: left out (0), run instead of main (1, --test), or kept as plain fns (2, the
    // language server); test_names are the names kept ones get
    test_mode: u32 = 0;
    test_pkgs: std::vec<str> = {}; // packages whose tests run too (--test-pkg)
    test_names: std::vec<std::string> = {};
}

// read path as a unit of package pkg (none: the program's own)
fn add_file(s: sources&, path: str, pkg: str?) -> void {
    val text = std::fs::read_file(path) catch |e| {
        die(fmt("can't read {}", S(path)));
    };
    put(&s.names, S(path));
    put(&s.texts, move text);
    put(&s.units, { file: @cast<u32>(s.names.len - 1), pkg: pkg });
}

// print diagnostics (errors and warnings) the way the command line asked
fn report_diags(c: cli&, files: std::vec<source_file>&, diags: std::vec<diag>&) -> void {
    var color = c.color == "always";
    if (c.color == "auto") {
        val term = std::process::env("TERM");
        color = sys::isatty(2) != 0 && std::process::env("NO_COLOR") == null && (term == null || (term ?? "") != "dumb");
    }
    std::eprint("{}", report(files, diags, c.format, color, c.error_limit));
}

// print one error and stop
fn fail_diag(c: cli&, files: std::vec<source_file>&, e: compile_error&) -> never {
    var diags: std::vec<diag> = {};
    put(&diags, err_diag(e));
    report_diags(c, files, &diags);
    std::process::exit(1);
}

// parse the program, std and packages, then check; the checked program
fn compile_cli(c: cli&, s: sources&) -> std::box<checker> {
    return compile_with(c, s, null);
}

// voltc lib's second pass: the shims voltc bindings describes (bindings.volt), compiled as one more
// file of the package, and the package's export fns they stand in for
struct shim_src {
    pkg: str;
    text: std::string;
    unexport: std::vec<std::string>;
}

// voltc lib: the package, and for other languages (--shared, --static) again with its shims when its
// export fns need them (owned text, export structs, closures). first holds the first pass's sources;
// s the ones the result points into
fn compile_lib(c: cli&, first: sources&, s: sources&) -> std::box<checker> {
    val pkg = *c.files.at(0);
    val chk = compile_with(c, first, null);
    if (!c.shared && !c.standalone) {
        // a library for Volt programs: they call its fns as Volt does
        return chk;
    }
    val plan = chk.shims(pkg) catch |e| {
        fail_diag(c, &first.files, &e);
    };
    if (plan.text.len() == 0) {
        return chk;
    }
    var shim: shim_src = { pkg: pkg, text: copy plan.text, unexport: copy plan.unexport };
    return compile_with(c, s, &shim);
}

// the package's export fns that shims stand in for stop being exports (the shims take their names)
fn unexport(items: std::vec<item>&, prefix: str, file: str, names: std::vec<std::string>&) -> void {
    for (it&) in items.items() {
        match (it.kind) {
            .FN(fd&) => {
                if (!fd.is_export) {
                    continue;
                }
                // full::name@file:offset: two attach fns can share a name
                var full = S(prefix);
                full.append("::");
                full.append(fd.name);
                full.push('@');
                full.append(file);
                full.push(':');
                full.append_uint(@cast<u64>(it.span.lo));
                for (n&) in names.items() {
                    if (n.as_str() == full.as_str()) {
                        fd.is_export = false;
                        fd.unexported = true;
                    }
                }
            },
            .NAMESPACE(path&, inner&) => {
                var p = S(prefix);
                for (seg&) in path.items() {
                    if (p.len() > 0) {
                        p.append("::");
                    }
                    p.append(*seg);
                }
                unexport(inner, p.as_str(), file, names);
            },
            default => {},
        }
    }
}

fn compile_with(c: cli&, s: sources&, shim: shim_src*) -> std::box<checker> {
    var pkgs: std::vec<pkg_arg> = {};
    var std_path = find_std(c);
    if (std_path) {
        put(&pkgs, { name: "std", path: std_path.as_str() });
    }
    for (p&) in c.pkgs.items() {
        // the name becomes a namespace and part of C symbol names
        var ident = p.name.len > 0 && (is_alpha(p.name[0]) || p.name[0] == '_');
        for (b) in p.name {
            if (!(is_alpha(b) || is_digit(b) || b == '_')) {
                ident = false;
            }
        }
        if (!ident) {
            die(fmt("package name '{}' has to be a Volt name (letters, digits, _): it becomes a namespace", S(p.name)));
        }
        for (q&) in pkgs.items() {
            if (q.name == p.name) {
                var hint = "";
                if (p.name == "std") {
                    hint = " (pick another std with --std DIR)";
                }
                die(fmt2("package '{}' is given twice{}", S(p.name), S(hint)));
            }
        }
        put(&pkgs, *p);
    }
    // a package's guard symbol names its exact sources and build flavor
    var guards: std::vec<guard> = {};
    for (p&) in pkgs.items() {
        var all: std::string = {};
        for (f&) in volt_files(p.path).items() {
            add_file(s, f.as_str(), p.name);
            all.append(s.texts.at(s.texts.len - 1).as_str());
            all.push(0);
        }
        if (shim != null && shim->pkg == p.name) {
            var name = S(p.path);
            name.append("/(export shims).volt");
            put(&s.names, move name);
            put(&s.texts, copy shim->text);
            put(&s.units, { file: @cast<u32>(s.names.len - 1), pkg: p.name });
            all.append(shim->text.as_str());
            all.push(0);
        }
        // and its --cfg settings: a library built with other features doesn't link either
        var cfg: std::vec<std::string> = {};
        for (x&) in c.cfg.items() {
            if (same_pkg(x.pkg, p.name)) {
                put(&cfg, S(x.set));
            }
        }
        sort_strings(&cfg);
        for (x&) in cfg.items() {
            all.append(x.as_str());
            all.push(0);
        }
        var flavor = "d";
        if (c.release) {
            flavor = "r";
        }
        var g = S("volt_pkg_");
        g.append(p.name);
        g.push('_');
        g.append(hex8(fnv32(all.as_str())).as_str());
        g.push('_');
        g.append(flavor);
        put(&s.guard_names, move g);
    }
    // `lib NAME` (and `check --lib NAME`) builds package NAME alone: there are no program files
    var lib: str? = c.lib;
    if (c.cmd == "lib" || c.cmd == "bindings") {
        lib = *c.files.at(0);
    }
    if (lib) {
        val l = lib;
        var known = false;
        for (p&) in pkgs.items() {
            if (p.name == l) {
                known = true;
            }
        }
        if (!known) {
            die(fmt("no package '{}' to build (std, or one given with --pkg)", S(l)));
        }
    } else {
        for (f&) in c.files.items() {
            add_file(s, *f, null);
        }
    }
    // a linked package's sources are still read: its generic code and declarations come from them
    for (l&) in c.links.items() {
        var known = false;
        for (p&) in pkgs.items() {
            if (p.name == l.name) {
                known = true;
            }
        }
        if (!known) {
            die(fmt2("--link {}=...: the package's sources are needed too (std, or --pkg {}=DIR)", S(l.name), S(l.name)));
        }
    }
    for (i) in 0..s.names.len {
        put(&s.files, { name: s.names.at(i).as_str(), text: s.texts.at(i).as_str() });
    }
    for (i) in 0..pkgs.len {
        put(&guards, { pkg: pkgs.at(i).name, sym: s.guard_names.at(i).as_str() });
    }
    // parse all units together (generic names are shared between files); a package's files live
    // in namespace <package>
    if (c.test) {
        s.test_mode = 1;
        s.test_pkgs = copy c.test_pkgs;
    }
    val bad = parse_sources(s);
    if (bad.len > 0) {
        report_diags(c, &s.files, &bad);
        std::process::exit(1);
    }
    if (shim != null) {
        for (i) in 0..s.asts.len {
            unexport(s.asts.at(i), "", s.files.at(i).name, &shim->unexport);
        }
    }
    // the runtime lives in the program's own C unit, never in a library
    var o: opts = { release: c.release, leak_check: c.leak_check, guards: move guards, lib: lib, runtime: lib == null || c.shared || c.standalone, cfg: copy c.cfg, pp_flags: preprocessor_flags(&c.cc_args), c_std: c.c_std, cpp_std: c.cpp_std, expand: c.cmd == "expand", line_info: c.profiler || (c.llvm && !c.release && (c.cmd == "build" || c.cmd == "run")), target: c.target };
    if (c.cmd == "emit-llvm") {
        o.triple = std::process::env("VOLT_TRIPLE");
    }
    for (u&) in s.units.items() {
        if (u.pkg) {
            put(&o.pkg_files, { file: u.file, pkg: u.pkg});
        }
    }
    for (l&) in c.links.items() {
        put(&o.linked, l.name);
    }
    var chk = compile_rounds(&s.files, &s.asts, move o);
    val diags = all_diags(&*chk);
    report_diags(c, &s.files, &diags);
    if (chk.errors.len > 0) {
        std::process::exit(1);
    }
    if (c.cmd == "build" || c.cmd == "run" || c.cmd == "lib") {
        val e = chk.link_go();
        if (e) {
            die(copy e);
        }
    }
    if (chk.c_includes.len > 0 || chk.c_units.len > 0) {
        c.c_unit_std = chk.c_own_std(); // Volt's C includes the C imports' headers: their standard
    }
    return chk;
}

// print a parse error in the canonical form: (error @lo:hi "msg"), with " as '
fn print_error(d: diag&) -> i32 {
    var msg: std::string = {};
    val m = d.msg.as_str();
    for (i) in 0..m.len {
        if (m[i] == '"') {
            msg.push('\'');
        } else {
            msg.push(m[i]);
        }
    }
    std::println("(error @{}:{} \"{}\")", d.span.lo, d.span.hi, msg);
    return 1;
}

// `parse FILE --sexp`: the parse tree (or the parse error) in the canonical form tests/selfhost.rs
// compares with the bootstrap's
fn parse_sexp(file: str) -> i32 {
    val text = std::fs::read_file(file) catch |e| {
        std::eprintln("voltc: can't read {}", file);
        return 1;
    };
    val src = text.as_str();
    var toks = lex(src, 0) catch |e| {
        val d = err_diag(&e);
        return print_error(&d);
    };
    var names: std::map<str, bool> = {};
    collect_generic_names(&toks, &names);
    var p: parser = { src: src, toks: &toks, pos: 0, generics: &names };
    val items = p.parse_file() catch |e| {
        for (d&) in p.errors.items() {
            print_error(d);
        }
        return 1;
    };
    var w: sexp_writer = { out: {} };
    w.items(&items);
    std::print("{}", w.out);
    return 0;
}

fn main() -> i32 {
    var c = parse_cli();
    if (c.cmd == "parse") {
        if (!c.sexp) {
            usage();
        }
        return parse_sexp(*c.files.at(0));
    }
    if (c.cmd == "lsp") {
        return lsp_main(find_std(&c));
    }
    if (c.cmd == "doc") {
        return doc_cmd(&c);
    }
    if (c.cmd == "std-dir") {
        val d = find_std(&c) ?? return 1;
        std::println("{}", d);
        return 0;
    }
    if (c.cmd == "check") {
        var s: sources = {};
        compile_cli(&c, &s);
        return 0;
    }
    if (c.cmd == "expand") {
        var s: sources = {};
        val chk = compile_cli(&c, &s);
        for (e&) in chk.expansions.items() {
            val f = chk.files.at(@cast<usize>(e.at.file));
            val lc = chk.line_col(e.at);
            if (f.name == *c.files.at(0) && (c.expand_line == 0 || lc.line == c.expand_line)) {
                std::println("{}:{}:{}: {}", f.name, lc.line, lc.col, e.text);
            }
        }
        return 0;
    }
    if (c.cmd == "emit-c") {
        var s: sources = {};
        val chk = compile_cli(&c, &s);
        val files = chk.c_files();
        val dir = c.out;
        if (dir) {
            // -o DIR: the files, ready to build with cc DIR/program.c
            var d = S(dir);
            mkdir(d.c_str(), 493); // 0755; an existing directory is fine
            for (f&) in files.items() {
                var p = S(dir);
                p.push('/');
                p.append(f.name.as_str());
                std::fs::write_file(p.as_str(), f.text.as_str()) catch |e| {
                    die(fmt("can't write {}", copy p));
                };
            }
            return 0;
        }
        // on stdout: the files program.c includes, in order, each under a line naming it
        for (k) in 0..files.len - 1 {
            std::println("// ==================== {} ====================", files.at(k).name);
            std::print("{}", files.at(k).text);
            std::println("");
        }
        return 0;
    }
    if (c.cmd == "emit-llvm") {
        var s: sources = {};
        val chk = compile_cli(&c, &s);
        var ir: std::string = {};
        val e = chk.llvm_ir(&ir);
        if (e.len() > 0) {
            die(move e);
        }
        std::print("{}", ir);
        return 0;
    }
    if (c.cmd == "build") {
        var s: sources = {};
        val chk = compile_cli(&c, &s);
        var out = S(c.out ?? "");
        if (c.out == null) {
            // named after the first file, or (only test packages) the first of them
            if (c.files.len > 0) {
                out = S(without_ext(*c.files.at(0)));
            } else {
                out = S(*c.test_pkgs.at(0));
            }
        }
        var lc = copy c;
        val cdir = fresh_dir();
        val cpp_os = cpp_objects(&*chk, &c, cdir.as_str());
        for (o&) in cpp_os.items() {
            put(&lc.cc_args, o.as_str());
        }
        if (chk.cpp_shims.len > 0) {
            put(&lc.cc_args, "-lstdc++");
        }
        for (f&) in chk.link_flags.items() {
            put(&lc.cc_args, f.as_str());
        }
        if (!c.llvm || !llvm_exe(&*chk, out.as_str(), &lc)) {
            cc(chk.c_unit().as_str(), out.as_str(), &lc, false);
        }
        write_deps(out.as_str(), &chk.import_deps);
        if (c.profiler) {
            write_voltmap(&*chk, out.as_str());
        }
        for (o&) in cpp_os.items() {
            unlink_path(o.as_str());
        }
        rmdir_path(cdir.as_str());
        return 0;
    }
    if (c.cmd == "bindings") {
        var s: sources = {};
        val chk = compile_cli(&c, &s);
        val text = chk.bindings(*c.files.at(0), c.lang) catch |e| {
            fail_diag(&c, &s.files, &e);
        };
        val out = c.out;
        if (out) {
            std::fs::write_file(out, text.as_str()) catch |e| {
                die(fmt("can't write {}", S(out)));
            };
        } else {
            std::print("{}", text);
        }
        return 0;
    }
    if (c.cmd == "lib" && c.shared) {
        // everything in one shared object: the package, what it uses from std and other packages,
        // and the runtime; its export fns are the interface (voltc bindings describes them)
        var first: sources = {};
        var s: sources = {};
        val chk = compile_lib(&c, &first, &s);
        var out = S(c.out ?? "");
        if (c.out == null) {
            out = S("lib");
            out.append(*c.files.at(0));
            out.append(".so");
        }
        var lc = copy c;
        val cdir = fresh_dir();
        val cpp_os = cpp_objects(&*chk, &c, cdir.as_str());
        for (o&) in cpp_os.items() {
            put(&lc.cc_args, o.as_str());
        }
        if (chk.cpp_shims.len > 0) {
            put(&lc.cc_args, "-lstdc++");
        }
        for (f&) in chk.link_flags.items() {
            put(&lc.cc_args, f.as_str());
        }
        if (!c.llvm || !llvm_exe(&*chk, out.as_str(), &lc)) {
            cc(chk.c_unit().as_str(), out.as_str(), &lc, false);
        }
        write_deps(out.as_str(), &chk.import_deps);
        for (o&) in cpp_os.items() {
            unlink_path(o.as_str());
        }
        rmdir_path(cdir.as_str());
        return 0;
    }
    if (c.cmd == "lib") {
        var first: sources = {};
        var s: sources = {};
        val chk = compile_lib(&c, &first, &s);
        var out = S(c.out ?? "");
        if (c.out == null) {
            out = S("lib");
            out.append(*c.files.at(0));
            out.append(".a");
        }
        // build the object in a private directory, archive it, then remove the temporaries either way
        var dir = fresh_dir();
        var obj = copy dir;
        obj.push('/');
        obj.append(*c.files.at(0));
        obj.append(".o");
        var o_c = S(without_ext(obj.as_str()));
        o_c.append(".c");
        var rt_o = copy dir;
        rt_o.append("/volt_rt.o");
        var rt_c = copy dir;
        rt_c.append("/volt_rt.c");
        var ar: std::vec<str> = {};
        put(&ar, "ar");
        put(&ar, "rcs");
        put(&ar, out.as_str());
        put(&ar, obj.as_str());
        val cpp_os = cpp_objects(&*chk, &c, dir.as_str());
        for (o&) in cpp_os.items() {
            put(&ar, o.as_str()); // the program links -lstdc++ too
        }
        var via_llvm = c.llvm;
        if (via_llvm) {
            // the object, plus the prelude's helpers (weak) for programs built by either backend
            var hdr: std::vec<str> = {};
            val e = chk.llvm_object(obj.as_str(), &hdr);
            if (e.len() > 0) {
                if (!llvm_falls_back(&*chk, &c, e.as_str())) {
                    die(move e);
                }
                via_llvm = false;
            } else {
                cc(llvm_runtime_c(&*chk, &hdr, c.standalone).as_str(), rt_o.as_str(), &c, true);
                put(&ar, rt_o.as_str());
            }
        }
        if (!via_llvm) {
            cc(chk.c_unit().as_str(), obj.as_str(), &c, true);
        }
        unlink_path(out.as_str()); // ar would add to an old archive
        // what a program linking this library needs too (use rust and the like): LIB.a.flags, which
        // --link reads
        var flags_file = copy out;
        flags_file.append(".flags");
        if (chk.link_flags.len > 0) {
            var text: std::string = {};
            for (f&) in chk.link_flags.items() {
                text.append(f.as_str());
                text.push('\n');
            }
            std::fs::write_file(flags_file.as_str(), text.as_str()) catch |e| {
                die(fmt("can't write {}", copy flags_file));
            };
        } else {
            unlink_path(flags_file.as_str());
        }
        val st = std::process::run(ar.items()) catch |e| 1;
        unlink_path(obj.as_str());
        unlink_path(o_c.as_str());
        unlink_path(rt_o.as_str());
        unlink_path(rt_c.as_str());
        for (o&) in cpp_os.items() {
            unlink_path(o.as_str());
        }
        rmdir_path(dir.as_str());
        if (st != 0) {
            die(fmt("ar couldn't write {}", copy out));
        }
        write_deps(out.as_str(), &chk.import_deps);
        return 0;
    }
    if (c.cmd == "run") {
        var s: sources = {};
        val chk = compile_cli(&c, &s);
        var dir = fresh_dir();
        var exe = copy dir;
        exe.append("/prog");
        var lc = copy c;
        val cpp_os = cpp_objects(&*chk, &c, dir.as_str());
        for (o&) in cpp_os.items() {
            put(&lc.cc_args, o.as_str());
        }
        if (chk.cpp_shims.len > 0) {
            put(&lc.cc_args, "-lstdc++");
        }
        for (f&) in chk.link_flags.items() {
            put(&lc.cc_args, f.as_str());
        }
        if (!c.llvm || !llvm_exe(&*chk, exe.as_str(), &lc)) {
            cc(chk.c_unit().as_str(), exe.as_str(), &lc, false);
        }
        for (o&) in cpp_os.items() {
            unlink_path(o.as_str());
        }
        var argv: std::vec<str> = {};
        put(&argv, exe.as_str());
        for (a&) in c.prog_args.items() {
            put(&argv, *a);
        }
        val code = std::process::run(argv.items()) catch |e| 1;
        var cf = copy exe;
        cf.append(".c");
        unlink_path(exe.as_str());
        unlink_path(cf.as_str());
        rmdir_path(dir.as_str());
        return code;
    }
    usage();
}

// --profiler: OUT.voltmap, each function's symbol and what it is in Volt, a line each (bolt hot names
// samples with it)
fn write_voltmap(chk: checker&, out: str) -> void {
    var text: std::string = {};
    for (i) in 0..chk.ir.fns.len {
        val f = chk.ir.fn_at(@cast<u32>(i));
        if (f.origin == null) {
            // glue the compiler made (a type's drop): its description, without a place
            if (f.about.len > 0) {
                text.append(f.name);
                text.push('\t');
                text.append(f.about);
                text.push('\n');
            }
            continue;
        }
        val o = f.origin ?? continue;
        text.append(f.name);
        text.push('\t');
        if (f.about.len > 0) {
            text.append(f.about);
        } else {
            text.append(f.name);
        }
        text.append(" (");
        text.append(chk.files.at(@cast<usize>(o.file)).name);
        text.push(':');
        val lc = chk.line_col(o);
        text.append_uint(@cast<u64>(lc.line));
        if (starts_with(f.about, "a closure")) {
            // two closures can share a line
            text.push(':');
            text.append_uint(@cast<u64>(lc.col));
        }
        text.append(")\n");
    }
    var p = S(out);
    p.append(".voltmap");
    std::fs::write_file(p.as_str(), text.as_str()) catch |e| {
        die(fmt("can't write {}", copy p));
    };
}

// a path without its extension (the last .xyz after the last /)
fn without_ext(p: str) -> str {
    var dot: usize? = null;
    for (i) in 0..p.len {
        if (p[i] == '.') {
            dot = i;
        } else if (p[i] == '/') {
            dot = null;
        }
    }
    if (dot) {
        if (dot > 0) {
            return p[0..dot];
        }
    }
    return p;
}

extern "C" fn mkdtemp(template: u8*) -> cstr?;
extern "C" fn unlink(path: cstr) -> i32;
extern "C" fn rmdir(path: cstr) -> i32;
extern "C" fn mkdir(path: cstr, mode: u32) -> i32;
extern "C" fn realpath(path: cstr, resolved: u8*) -> cstr?;

// a new private build directory (mkdtemp makes it 0700, under a fresh name)
fn fresh_dir() -> std::string {
    var t = S("/tmp/voltc-XXXXXX");
    t.push(0);
    val made = mkdtemp(@cast<u8*>(t.as_str().ptr)) ?? die(S("can't make a build directory in /tmp"));
    put(&build_dirs, S(t.as_str()[0..t.len() - 1]));
    return S(t.as_str()[0..t.len() - 1]);
}

// OUT.deps: the files other than the Volt sources that out was made from (what use rust and the
// like read), one a line, for a build tool deciding whether to remake out; none: no file
fn write_deps(out: str, deps: std::vec<std::string>&) -> void {
    var f = S(out);
    f.append(".deps");
    if (deps.len == 0) {
        unlink_path(f.as_str());
        return;
    }
    var text: std::string = {};
    for (d&) in deps.items() {
        text.append(d.as_str());
        text.push('\n');
    }
    std::fs::write_file(f.as_str(), text.as_str()) catch |e| {
        die(fmt("can't write {}", copy f));
    };
}

fn unlink_path(p: str) -> void {
    var s = S(p);
    unlink(s.c_str());
}

fn rmdir_path(p: str) -> void {
    var s = S(p);
    rmdir(s.c_str());
}

// compile C (written next to out as a .c file): to an executable (linked with the --link libraries),
// or with `object` to a .o
fn cc(src: str, out: str, c: cli&, object: bool) -> void {
    var c_path = S(without_ext(out));
    if (without_ext(out).len == out.len) {
        c_path = S(out);
    }
    c_path.append(".c");
    std::fs::write_file(c_path.as_str(), src) catch |e| {
        die(fmt("can't write {}", copy c_path));
    };
    var inputs: std::vec<str> = {};
    put(&inputs, c_path.as_str());
    cc_run(&inputs, out, c, object);
}

// the imports' own objects: a C++ unit per standard, and a C unit per standard Volt's C can't
// include
fn cpp_objects(chk: checker&, c: cli&, dir: str) -> std::vec<std::string> {
    var objs: std::vec<std::string> = {};
    var live: std::map<u32, bool> = {};
    if (chk.cpp_units.len > 0) {
        live = reachable(chk);
    }
    var linked: std::vec<std::string> = {};
    for (u) in 0..chk.cpp_units.len {
        val o = cpp_object(chk, c, dir, @cast<u32>(u), &live, &objs, &linked);
        if (o) {
            put(&objs, copy o);
        }
    }
    for (u) in 0..chk.c_units.len {
        var src = S(dir);
        src.append(fmt("/volt_c_{}.c", unum(@cast<u64>(u))).as_str());
        var obj = S(dir);
        obj.append(fmt("/volt_c_{}.o", unum(@cast<u64>(u))).as_str());
        var text = copy *chk.c_unit_text.at(u);
        if (chk.c_unit_weak.at(u).len() > 0) {
            text.append("\n/* functions nothing defines: a stub that says so */\n__attribute__((constructor)) static void volt_c_check(void) {\n");
            text.append(chk.c_unit_weak.at(u).as_str());
            text.append("}\n");
        }
        std::fs::write_file(src.as_str(), text.as_str()) catch |e| {
            die(fmt("can't write {}", copy src));
        };
        var argv: std::vec<str> = {};
        val cc = c_command(&argv);
        val std_flag = fmt("-std={}", S(*chk.c_units.at(u)));
        val fixed: str[4] = { std_flag.as_str(), "-fPIC", "-w", "-c" };
        for (f) in fixed {
            put(&argv, f);
        }
        put(&argv, src.as_str());
        put(&argv, "-o");
        put(&argv, obj.as_str());
        for (f&) in preprocessor_flags(&c.cc_args).items() {
            put(&argv, *f);
        }
        if (c.release) {
            put(&argv, "-O2");
        }
        val r = std::process::capture(argv.items(), "") catch |e| {
            die(fmt("can't run the C compiler '{}'", S(cc)));
        };
        unlink_path(src.as_str());
        if (r.code != 0) {
            die(fmt2("the C compiler failed on the headers imported under {}:\n{}", copy std_flag, copy r.err));
        }
        put(&objs, move obj);
    }
    return objs;
}

// the program's C++ wrappers (use cpp) of unit u compiled under its standard with $CXX (c++ unless
// set) into dir: the object, when its imports make calls
fn cpp_object(chk: checker&, c: cli&, dir: str, u: u32, live: std::map<u32, bool>&, objs: std::vec<std::string>&, linked: std::vec<std::string>&) -> std::string? {
    val text = chk.cpp_unit(u, live);
    if (text.len() == 0) {
        return null;
    }
    var src = S(dir);
    src.append(fmt("/volt_cpp_{}.cpp", unum(@cast<u64>(u))).as_str());
    var obj = S(dir);
    obj.append(fmt("/volt_cpp_{}.o", unum(@cast<u64>(u))).as_str());
    std::fs::write_file(src.as_str(), text.as_str()) catch |e| {
        die(fmt("can't write {}", copy src));
    };
    var argv: std::vec<str> = {};
    val cxx = cxx_command(&argv);
    val std_flag = fmt("-std={}", S(*chk.cpp_units.at(@cast<usize>(u))));
    val fixed: str[4] = { std_flag.as_str(), "-fPIC", "-w", "-c" };
    for (f) in fixed {
        put(&argv, f);
    }
    put(&argv, src.as_str());
    put(&argv, "-o");
    put(&argv, obj.as_str());
    for (f&) in preprocessor_flags(&c.cc_args).items() {
        put(&argv, *f);
    }
    if (c.release) {
        put(&argv, "-O2");
    } else {
        put(&argv, "-O0");
        put(&argv, "-g");
    }
    var merr = S("");
    val pp = preprocessor_flags(&c.cc_args);
    val mflags = cpp_module_flags(chk, &pp, dir, u, std_flag.as_str(), objs, linked, &merr);
    if (merr.len() > 0) {
        die(move merr);
    }
    for (f&) in mflags.items() {
        put(&argv, f.as_str());
    }
    val r = std::process::capture(argv.items(), "") catch |e| {
        die(fmt("can't run the C++ compiler '{}'", S(cxx)));
    };
    unlink_path(src.as_str());
    if (r.code != 0) {
        die(fmt2("the C++ compiler failed on the wrappers for use cpp ({}):\n{}", copy std_flag, copy r.err));
    }
    return obj;
}

// the C++20 modules unit u imports (the C++ library's std, named modules' interfaces), built by
// $CXX its own way into dir, their objects added to objs (a module once, though units of two
// standards import it: linked names it): g++ through a module mapper file naming each one's
// compiled interface, clang through --precompile and -fmodule-file. The flags the unit is compiled
// with to import them; what failed in err
fn cpp_module_flags(chk: checker&, pp: std::vec<str>&, dir: str, u: u32, std_flag: str, objs: std::vec<std::string>&, linked: std::vec<std::string>&, err: std::string&) -> std::vec<std::string> {
    var flags: std::vec<std::string> = {};
    var names: std::vec<std::string> = {};
    var paths: std::vec<std::string> = {};
    var cmd: std::vec<str> = {};
    val cxx = cxx_command(&cmd);
    for (x) in chk.cpp_std_units.items() {
        if (x == u && names.len == 0) {
            val src = std_module_source(&cmd, "std");
            if (src == null) {
                *err = fmt("import std; needs the C++ library's std module, and the C++ compiler '{}' finds no modules manifest (libstdc++.modules.json, libc++.modules.json)", S(cxx));
                return flags;
            }
            put(&names, S("std"));
            put(&paths, src ?? S(""));
        }
    }
    for (x) in chk.cpp_compat_units.items() {
        if (x == u) {
            val src = std_module_source(&cmd, "std.compat");
            if (src == null) {
                *err = fmt("import std.compat; needs the C++ library's std.compat module, and the C++ compiler '{}' finds none in its modules manifest", S(cxx));
                return flags;
            }
            put(&names, S("std.compat"));
            put(&paths, src ?? S(""));
        }
    }
    for (m&) in chk.cpp_modules.items() {
        if (m.unit == u) {
            put(&names, S(m.name));
            put(&paths, S(m.path));
        }
    }
    if (names.len == 0) {
        return flags;
    }
    var vargv = copy cmd;
    put(&vargv, "--version");
    var clang_ = false;
    val vr = std::process::capture(vargv.items(), "") catch |e| {
        *err = fmt("can't run the C++ compiler '{}'", S(cxx));
        return flags;
    };
    clang_ = contains(vr.out.as_str(), "clang");
    var files: std::vec<std::string> = {}; // each module's compiled interface
    for (i) in 0..names.len {
        var safe = S("");
        for (ch) in names.at(i).as_str() {
            if (ch == ':' || ch == '/') {
                safe.push('-');
            } else {
                safe.push(ch);
            }
        }
        if (clang_) {
            put(&files, fmt3("{}/volt_mod_{}_{}.pcm", S(dir), unum(@cast<u64>(u)), move safe));
        } else {
            put(&files, fmt3("{}/volt_mod_{}_{}.gcm", S(dir), unum(@cast<u64>(u)), move safe));
        }
    }
    if (!clang_) {
        var map = S("");
        for (i) in 0..names.len {
            map.append(fmt2("{} {}\n", copy *names.at(i), copy *files.at(i)).as_str());
        }
        val mp = fmt("{}/volt_cpp_modules.map", S(dir));
        std::fs::write_file(mp.as_str(), map.as_str()) catch |e| {
            *err = fmt("can't write {}", copy mp);
            return flags;
        };
        put(&flags, S("-fmodules"));
        put(&flags, fmt("-fmodule-mapper={}", copy mp));
    }
    for (i) in 0..names.len {
        val obj = fmt3("{}/volt_mod_{}_{}.o", S(dir), unum(@cast<u64>(u)), unum(@cast<u64>(i)));
        var argv = copy cmd;
        val fixed: str[3] = { std_flag, "-fPIC", "-w" };
        for (f) in fixed {
            put(&argv, f);
        }
        for (f&) in pp.items() {
            put(&argv, *f);
        }
        for (f&) in flags.items() {
            put(&argv, f.as_str());
        }
        if (clang_) {
            val pre: str[5] = { "-Wno-reserved-module-identifier", "--precompile", "-x", "c++-module", "-o" };
            for (f) in pre {
                put(&argv, f);
            }
            put(&argv, files.at(i).as_str());
        } else {
            val pre: str[4] = { "-c", "-x", "c++", "-o" };
            for (f) in pre {
                put(&argv, f);
            }
            put(&argv, obj.as_str());
        }
        put(&argv, paths.at(i).as_str());
        val r = std::process::capture(argv.items(), "") catch |e| {
            *err = fmt("can't run the C++ compiler '{}'", S(cxx));
            return flags;
        };
        if (r.code != 0) {
            *err = fmt2("the C++ compiler failed on the module {}:\n{}", copy *names.at(i), copy r.err);
            return flags;
        }
        if (clang_) {
            // the module's object from its precompiled interface; importers find it by name
            var oargv = copy cmd;
            val more: str[5] = { std_flag, "-fPIC", "-c", "-o", obj.as_str() };
            for (f) in more {
                put(&oargv, f);
            }
            for (f&) in flags.items() {
                put(&oargv, f.as_str());
            }
            put(&oargv, files.at(i).as_str());
            val o = std::process::capture(oargv.items(), "") catch |e| {
                *err = fmt("can't run the C++ compiler '{}'", S(cxx));
                return flags;
            };
            if (o.code != 0) {
                *err = fmt2("the C++ compiler failed on the module {}:\n{}", copy *names.at(i), copy o.err);
                return flags;
            }
            put(&flags, fmt2("-fmodule-file={}={}", copy *names.at(i), copy *files.at(i)));
        }
        var once = true;
        for (l&) in linked.items() {
            once = once && l.as_str() != names.at(i).as_str();
        }
        if (once) {
            put(linked, copy *names.at(i));
            put(objs, obj);
        }
    }
    return flags;
}

// the runtime unit `text` compiled for c's settings: from Volt's cache (runtime/rt-<hash>.o) when
// it's there, else compiled in `dir` and kept there for next time
fn runtime_object(text: str, c: cli&, dir: str) -> std::string {
    var key = S(text);
    key.append(std::process::os());
    key.append(std::process::arch());
    key.append(std::process::env("CC") ?? "cc");
    key.append(c.c_unit_std);
    if (c.profiler && on_path("clang")) {
        key.append("|clang"); // cc_run compiles --profiler builds with clang when it's there
    }
    if (c.release) {
        key.append("|release");
    }
    if (c.profiler) {
        key.append("|profiler");
    }
    if (c.shared || c.standalone) {
        key.append("|pic");
    }
    for (f&) in preprocessor_flags(&c.cc_args).items() {
        key.push('|');
        key.append(*f);
    }
    val cdir = fmt("{}/runtime", cache_base());
    val path = std::fmt::format("{}/rt-{:x}.o", cdir.as_str(), std::digest::fnv1a(key.as_str()));
    if (std::fs::exists(path.as_str())) {
        return path;
    }
    var tmp = S(dir);
    tmp.append("/volt_rt.o");
    cc(text, tmp.as_str(), c, true);
    // into the cache by rename, so a build running alongside never sees half a file
    std::fs::create_dir_all(cdir.as_str()) catch |e| { return tmp; };
    var part = std::fmt::format("{}.{}.part", path.as_str(), sys::getpid());
    std::fs::copy_file(tmp.as_str(), part.as_str()) catch |e| { return tmp; };
    std::fs::rename(part.as_str(), path.as_str()) catch |e| {
        std::fs::remove_file(part.as_str()) catch |x| {};
        return tmp;
    };
    return path;
}

// are these --cc arguments only libraries and files to link (nothing that changes how C compiles)?
fn link_args_only(args: std::vec<str>&) -> bool {
    for (a) in args.items() {
        if (starts_with(a, "-") && !starts_with(a, "-l") && !starts_with(a, "-L") && !starts_with(a, "-Wl,")) {
            return false;
        }
    }
    return true;
}

// when LLVM was only the default and it can't lower this program (a C struct only C can lay
// out; not a voltc bug), the build goes through C: say so, and why
fn llvm_falls_back(chk: checker&, c: cli&, e: str) -> bool {
    if (c.backend_set || !chk.llvm_cant_lower) {
        return false;
    }
    std::eprintln("note: building through C: {}", e);
    return true;
}

// the LLVM backend's executable: the program's object and the runtime (C), linked by cc
fn llvm_exe(chk: checker&, out: str, c: cli&) -> bool {
    var dir = fresh_dir();
    var obj = copy dir;
    obj.append("/prog.o");
    var rt_c = copy dir;
    rt_c.append("/volt_rt.c");
    var hdr: std::vec<str> = {};
    val e = chk.llvm_object(obj.as_str(), &hdr);
    if (e.len() > 0) {
        rmdir_path(dir.as_str());
        if (llvm_falls_back(chk, c, e.as_str())) {
            return false; // the caller builds it through C
        }
        die(move e);
    }
    if (c.target) {
        // bare metal: the object (start code included) linked by ld.lld alone, with no C runtime
        var argv: std::vec<str> = {};
        put(&argv, "ld.lld");
        put(&argv, "--gc-sections");
        put(&argv, "-e");
        put(&argv, "_start");
        if (c.link_script) {
            put(&argv, "-T");
            put(&argv, c.link_script);
        }
        put(&argv, "-o");
        put(&argv, out);
        put(&argv, obj.as_str());
        val st = std::process::run(argv.items()) catch |x| 127;
        unlink_path(obj.as_str());
        rmdir_path(dir.as_str());
        if (st != 0) {
            die(S("ld.lld failed (it ships with LLVM; --target links with it)"));
        }
        return true;
    }
    val rt_text = llvm_runtime_c(chk, &hdr, true);
    var inputs: std::vec<str> = {};
    put(&inputs, obj.as_str());
    var rt_o = S("");
    if (chk.c_includes.len == 0 && hdr.len == 0 && link_args_only(&c.cc_args) && cache_base().as_str() != "/tmp/volt-cache") {
        // the same runtime as every other program's: compiled once, then from the user's cache
        // (not a shared /tmp one, where another user could leave an object to be linked in)
        rt_o = runtime_object(rt_text.as_str(), c, dir.as_str());
        put(&inputs, rt_o.as_str());
    } else {
        std::fs::write_file(rt_c.as_str(), rt_text.as_str()) catch |x| {
            die(fmt("can't write {}", copy rt_c));
        };
        put(&inputs, rt_c.as_str());
    }
    cc_run(&inputs, out, c, false);
    unlink_path(obj.as_str());
    unlink_path(rt_c.as_str());
    var rt_tmp = copy dir;
    rt_tmp.append("/volt_rt.o"); // where runtime_object compiles it (the cache keeps its own copy)
    unlink_path(rt_tmp.as_str());
    rmdir_path(dir.as_str());
    return true;
}

// is there a program called name in a $PATH directory?
fn on_path(name: str) -> bool {
    val path = std::process::env("PATH") ?? return false;
    for (dir) in path.split(":").items() {
        if (dir.len > 0) {
            var p = S(dir);
            p.append("/");
            p.append(name);
            if (std::fs::exists(p.as_str())) {
                return true;
            }
        }
    }
    return false;
}

// run the C compiler on these inputs (C files, objects): an executable, or with `object` a .o
fn cc_run(inputs: std::vec<str>&, out: str, c: cli&, object: bool) -> void {
    // imported headers' prototypes are C's own: a Volt void*/cstr for their const void*/char* is fine
    var argv: std::vec<str> = {};
    var lib_flags: std::vec<std::string> = {}; // the linked libraries' LIB.a.flags lines, which argv points into
    var compiler = "clang";
    if (c.profiler && std::process::env("CC") == null && on_path("clang")) {
        // bolt hot walks frame pointers, and clang keeps them in leaf functions when told to (gcc
        // 16 drops them there anyway, and a sample in a leaf loses the leaf's caller); $CC still wins
        put(&argv, compiler);
    } else {
        compiler = c_command(&argv);
    }
    val std_flag = fmt("-std={}", S(c.c_unit_std));
    put(&argv, std_flag.as_str());
    put(&argv, "-w");
    put(&argv, "-Wno-error=incompatible-pointer-types");
    put(&argv, "-Wno-error=int-conversion");
    put(&argv, "-o");
    put(&argv, out);
    for (x&) in inputs.items() {
        put(&argv, *x);
    }
    if (object) {
        // a library's C still includes the headers its code imports: -I, -D, -U from --cc
        put(&argv, "-c");
        for (f&) in preprocessor_flags(&c.cc_args).items() {
            put(&argv, *f);
        }
    } else {
        // the order GNU ld needs: objects and flags, the archives, then the -l libraries they use
        // (Ubuntu's gcc links --as-needed, which drops a library named before anything uses it)
        var needed: std::vec<str> = {};
        for (a&) in c.cc_args.items() {
            if (a.starts_with("-l")) {
                put(&needed, *a);
            } else {
                put(&argv, *a);
            }
        }
        for (l&) in c.links.items() {
            put(&argv, l.path);
            // and what the library's imports link (voltc lib wrote them next to it)
            var ff = S(l.path);
            ff.append(".flags");
            val more = std::fs::read_file(ff.as_str()) catch |e| S("");
            for (x) in more.as_str().lines().items() {
                if (x.trim().len > 0) {
                    put(&lib_flags, S(x.trim()));
                }
            }
        }
        for (f&) in lib_flags.items() {
            put(&argv, f.as_str());
        }
        for (a&) in needed.items() {
            put(&argv, *a);
        }
        put(&argv, "-lm");
        put(&argv, "-lpthread"); // the runtime has threads (libpthread before glibc 2.34)
        if (c.shared) {
            put(&argv, "-shared");
        }
    }
    if (c.shared || c.standalone) {
        put(&argv, "-fPIC");
    }
    if (c.release) {
        put(&argv, "-O2");
        put(&argv, "-fwrapv");
        put(&argv, "-fno-math-errno"); // Volt never reads errno: sqrt and friends can be instructions
    } else {
        put(&argv, "-O0");
        put(&argv, "-g");
    }
    if (c.profiler) {
        // bolt hot: line info and frame pointers for the sampler's stack walk (where the program was
        // loaded is in the profile, so it links as it always would)
        val pf: str[4] = { "-g", "-fno-omit-frame-pointer", "-mno-omit-leaf-frame-pointer", "-DVOLT_PROFILE" };
        for (f) in pf {
            put(&argv, f);
        }
    }
    val r = std::process::capture(argv.items(), "") catch |e| {
        die(fmt("can't run {}", S(compiler)));
    };
    // a volt_pkg_ guard symbol that doesn't resolve means a --link library doesn't match its package
    if (r.code != 0) {
        val msg = r.err.as_str();
        for (i) in 0..msg.len {
            if (starts_at(msg, i, "volt_pkg_")) {
                var e = i + 9;
                while (e < msg.len && msg[e] != '_') {
                    e += 1;
                }
                val pkg = msg[i + 9..e];
                die(fmt2("the library linked for package '{}' was built from other sources or in the other mode (debug/release); rebuild it with voltc lib {}", S(pkg), S(pkg)));
            }
        }
        std::eprint("{}", r.err);
        // the linker's errors aren't the generated C's: a library it can't find, or an undefined name
        if (msg.contains("cannot find -l") || msg.contains("unable to find library")) {
            die(fmt("linking {} failed: a library above wasn't found (install it, or pass --cc -L/DIR where it is)", S(out)));
        }
        if (msg.contains("ld returned") || msg.contains("linker command failed")) {
            die(fmt("linking {} failed (the linker's errors are above): a C library or extern function may be missing; if not, this is a voltc bug", S(out)));
        }
        die(fmt("the C compiler failed on {} (this is a voltc bug)", S(*inputs.at(0))));
    }
}
