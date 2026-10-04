// use { "geom.rs" } as NAME; for code in another language, which the extension names (use rust {
// "geom" } as NAME; says it outright, for a crate directory or anything ambiguous). bolt does
// the language's part: `bolt import LANG` reads the code's own declarations, builds the glue, and
// writes the Volt source of namespace NAME (bodies that call the glue) and the flags a program
// using it links. voltc parses that source into the namespace, as use cpp does with what it
// writes, and links the flags. bolt keeps each import's work in a cache directory and redoes it
// only when the code changes.
use std::io;

// the language a file is in, from its extension: "cpp", "rust", "zig", "swift" or "go", or null for a C
// header (a directory with a Cargo.toml is a Rust crate, one with a go.mod a Go package). A C++ header
// named .h needs `use cpp { }`
fn language_of(path: str, dir: str) -> str? {
    var name = path;
    for (i) in 0..path.len {
        if (path[i] == '/') {
            name = path[i + 1..path.len];
        }
    }
    var at: usize? = null;
    for (i) in 0..name.len {
        if (name[i] == '.') {
            at = i + 1;
        }
    }
    var lower: std::string = {};
    if (at) {
        lower = name[at..name.len].to_lower(); // Shapes.HPP is C++ too
    }
    val ext = lower.as_str();
    val cpp: str[11] = { "hpp", "hh", "hxx", "h++", "cpp", "cc", "cxx", "c++", "ipp", "tpp", "ixx" };
    for (c) in cpp {
        if (ext == c) {
            return "cpp";
        }
    }
    if (ext == "rs") {
        return "rust";
    }
    if (ext == "zig") {
        return "zig";
    }
    if (ext == "swift") {
        return "swift";
    }
    if (ext == "go") {
        return "go";
    }
    var full = S(path);
    if (path.len == 0 || path[0] != '/') {
        full = S(dir);
        full.push('/');
        full.append(path);
    }
    var cargo = copy full;
    cargo.append("/Cargo.toml");
    if (std::fs::is_file(cargo.as_str())) {
        return "rust";
    }
    full.append("/go.mod");
    if (std::fs::is_file(full.as_str())) {
        return "go";
    }
    return null;
}

// the language a plain `use { ... }` imports: null for C headers. Every file has to be in the same one
attach fn import_language(this: checker&, files: std::vec<std::string>&, span: span) -> compile_error!(str?) {
    val dir = this.header_dir(span) ?? ".";
    var lang: str? = null;
    for (i) in 0..files.len {
        val l = language_of(files.at(i).as_str(), dir);
        if (i == 0) {
            lang = l;
        } else if ((l == null) != (lang == null) || (l != null && (l ?? "") != (lang ?? ""))) {
            return fails(span, "one use { } imports files in one language: give each language its own use");
        }
    }
    return lang;
}

attach fn import_lang(this: checker&, lang: str, args: std::vec<std::string>&, alias: str, ns: u32, span: span) -> compile_error!void {
    val from = this.header_dir(span) ?? ".";
    val bolt = find_bolt();
    val out = import_dir(lang, alias, from);
    var argv: std::vec<str> = {};
    put(&argv, bolt.as_str());
    put(&argv, "import");
    put(&argv, lang);
    put(&argv, "--as");
    put(&argv, alias);
    put(&argv, "--from");
    put(&argv, from);
    put(&argv, "--out");
    put(&argv, out.as_str());
    if (this.opts.release) {
        put(&argv, "--release");
    }
    put(&argv, "--");
    for (a&) in args.items() {
        put(&argv, a.as_str());
    }
    val r = std::process::capture(argv.items(), "") catch |e| {
        return fail(span, fmt2("use {}: can't run {}: set $BOLT to bolt, or put it next to voltc or on PATH", S(lang), copy bolt));
    };
    if (r.code != 0) {
        return fail(span, S(r.err.as_str().trim()));
    }
    var vf = copy out;
    vf.append("/import.volt");
    val text0 = std::fs::read_file(vf.as_str()) catch |e| {
        return fail(span, fmt("bolt import wrote no {}", copy vf));
    };
    var ff = copy out;
    ff.append("/import.flags");
    val flags = std::fs::read_file(ff.as_str()) catch |e| {
        return fail(span, fmt("bolt import wrote no {}", copy ff));
    };
    for (l) in flags.as_str().lines().items() {
        val f = l.trim();
        val go_pkg = f.strip_prefix("go-package ");
        if (go_pkg) {
            put(&this.go_packages, S(go_pkg));
        } else if (f.len > 0) {
            put(&this.link_flags, S(f));
        }
    }
    var df = copy out;
    df.append("/import.deps");
    val deps = std::fs::read_file(df.as_str()) catch |e| S("");
    for (l) in deps.as_str().lines().items() {
        if (l.trim().len > 0) {
            put(&this.import_deps, S(l.trim()));
        }
    }
    // VOLT_SHOW_IMPORT=1 prints it: what the code became
    if (std::process::env("VOLT_SHOW_IMPORT") != null) {
        std::eprint("{}", text0);
    }
    // it's Volt source like any other: lexed, parsed and declared in namespace `alias`
    put(&this.c_texts, move text0);
    val text = this.c_texts.at(this.c_texts.len - 1).as_str();
    var fname = fmt2("<use {} as {}>", S(lang), S(alias));
    put(this.files, { name: this.intern(move fname), text: text });
    val file = @cast<u32>(this.files.len - 1);
    val toks = try lex(text, file);
    var names: std::map<str, bool> = {};
    collect_generic_names(&toks, &names);
    var p: parser = { src: text, toks: &toks, pos: 0, generics: &names };
    val items = try p.parse_file();
    put(&this.cpp_items, bx(move items));
    val n = this.ns_child(ns, alias);
    return this.collect(*this.cpp_items.at(this.cpp_items.len - 1), n);
}

// A program's use go imports as one library: each import is a package of glue (`go-package DIR` in
// its flags), and bolt import go-link builds them all into one, with the one Go runtime a program
// can have. The error, if it fails
attach fn link_go(this: checker&) -> std::string? {
    if (this.go_packages.len == 0) {
        return null;
    }
    var key: std::string = {};
    for (p&) in this.go_packages.items() {
        key.append(p.as_str());
        key.push('\n');
    }
    val out = std::fmt::format("{}/imports/go-link-{:x}", cache_base().as_str(), std::digest::fnv1a(key.as_str()));
    val bolt = find_bolt();
    var argv: std::vec<str> = {};
    put(&argv, bolt.as_str());
    put(&argv, "import");
    put(&argv, "go-link");
    put(&argv, "--as");
    put(&argv, "program");
    put(&argv, "--out");
    put(&argv, out.as_str());
    put(&argv, "--");
    for (p&) in this.go_packages.items() {
        put(&argv, p.as_str());
    }
    val r = std::process::capture(argv.items(), "") catch |e| {
        return fmt("use go: can't run {}: set $BOLT to bolt, or put it next to voltc or on PATH", copy bolt);
    };
    if (r.code != 0) {
        return S(r.err.as_str().trim());
    }
    var ff = copy out;
    ff.append("/import.flags");
    val flags = std::fs::read_file(ff.as_str()) catch |e| {
        return fmt("bolt import go-link wrote no {}", copy ff);
    };
    for (l) in flags.as_str().lines().items() {
        if (l.trim().len > 0) {
            put(&this.link_flags, S(l.trim()));
        }
    }
    return null;
}

// bolt: $BOLT, else the bolt next to this voltc, else bolt on PATH
fn find_bolt() -> std::string {
    val e = std::process::env("BOLT");
    if (e) {
        return S(e);
    }
    val path = std::process::exe_path();
    if (path) {
        val exe = path.as_str();
        var dir_end = exe.len;
        while (dir_end > 0 && exe[dir_end - 1] != '/') {
            dir_end -= 1;
        }
        var p = S(exe[0..dir_end]);
        p.append("bolt");
        if (std::fs::exists(p.as_str())) {
            return p;
        }
    }
    return S("bolt");
}

// Volt's cache: $VOLT_CACHE, else $XDG_CACHE_HOME/volt, else ~/.cache/volt
fn cache_base() -> std::string {
    val vc = std::process::env("VOLT_CACHE");
    val xdg = std::process::env("XDG_CACHE_HOME");
    val home = std::process::env("HOME");
    if (vc) {
        return S(vc);
    } else if (xdg) {
        return fmt("{}/volt", S(xdg));
    } else if (home) {
        return fmt("{}/.cache/volt", S(home));
    }
    return S("/tmp/volt-cache");
}

// where bolt keeps one import's work: the cache's imports/LANG-ALIAS-<a hash of the importing
// directory>
fn import_dir(lang: str, alias: str, from: str) -> std::string {
    val base = cache_base();
    val dir = real_file(from) ?? S(from);
    val h = std::digest::fnv1a(dir.as_str());
    return std::fmt::format("{}/imports/{}-{}-{:x}", base.as_str(), lang, alias, h);
}
