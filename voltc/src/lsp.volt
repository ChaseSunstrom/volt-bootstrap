// voltc lsp: the language server editors talk to (editors/vscode), over stdin and stdout: JSON-RPC
// messages with Content-Length headers, the Language Server Protocol.
//
// Every change re-checks the document with std (and, in a bolt package, with the other files of its
// src/ directory). While checking, the checker records each name it resolves (lsp_refs: where it's
// used, where it's declared, what hover shows) and each local; hover, go to definition and
// references read those. Completion and signature help read the text before the cursor, against
// the last version of the document that parsed.

// ---------- what the checker records (opts.lsp) ----------

// a name used in the program: where it's written, where it's declared, what hover shows
struct lsp_ref {
    at: span;
    def: span;
    label: std::string;
    kind: u8 = 255; // what it is, for semantic tokens (LK_*, lsp_inline.volt); 255: none
    mods: u32 = 0;  // LM_* (readonly for a val)
    decl: u32? = null; // a declared type's decl (hover lists what's attached to it)
}

// a local variable or parameter: its place, name, type and where it's declared
struct lsp_local {
    c: u32;
    name: str;
    ty: u32;
    def: span;
    mutable: bool = false;
    param: bool = false;
    generic: bool = false; // in an instance of a generic fn: its type is one instance's
}

attach fn lsp_add_local(this: checker&, c: u32, name: str, ty: u32, def: span, mutable: bool, param: bool) -> void {
    // a hidden local (an if binding's or a struct update's) isn't in the source to show
    if (name.len > 0 && name[0] == '@') {
        return;
    }
    this.lsp_local_idx.put(c, this.lsp_locals.len);
    val generic = this.env_at(this.cx.env).generics.len > 0;
    put(&this.lsp_locals, { c: c, name: name, ty: ty, def: def, mutable: mutable, param: param, generic: generic });
}

// parameter `name` of fn decl d, bound to place c
attach fn lsp_param(this: checker&, d: u32, name: str, c: u32, ty: u32) -> void {
    var def = this.item_of(d).span;
    val f = this.fn_decl_of(d) ?? return;
    var mutable = false;
    for (p&) in f.params.items() {
        if (p.name == name) {
            def = p.span;
            mutable = p.mutable;
        }
    }
    this.lsp_add_local(c, name, ty, this.name_span(def, name), mutable, true);
}

// local c used at span
attach fn lsp_local_use(this: checker&, c: u32, name: str, ty: u32, span: span) -> void {
    val i = this.lsp_local_idx.get(c) ?? return;
    val l = this.lsp_locals.at(*i);
    put(&this.lsp_refs, { at: span, def: l.def, label: fmt2("{}: {}", S(name), this.ty_name(ty)), kind: local_kind(l), mods: local_mods(l) });
}

// a use of fn decl d (instance inst, when there is one) somewhere in span: a call, or d as a value
attach fn lsp_fn_use(this: checker&, d: u32, inst: u32?, span: span) -> void {
    val f = this.fn_decl_of(d) ?? return;
    val at = this.lsp_word(span, f.name, false) ?? return; // not written there: an operator, a hook
    var label = this.lsp_decl_text(d);
    if (label.len() == 0 && inst != null) {
        label = this.lsp_c_signature(inst ?? 0);
    }
    // the name after `fn` (an attribute before it may spell it too)
    var def = this.item_of(d).span;
    val kw = this.lsp_word(def, "fn", false);
    if (kw) {
        def.lo = kw.hi;
    }
    var kind = LK_FUNCTION;
    for (p&) in f.params.items() {
        if (p.name == "this") {
            kind = LK_METHOD;
        }
    }
    put(&this.lsp_refs, { at: at, def: this.name_span(def, f.name), label: move label, kind: kind });
}

// field `name` (of type ty) of struct instance sid, used at the end of span (x.name)
attach fn lsp_field_use(this: checker&, sid: u32, name: str, ty: u32, span: span) -> void {
    val at = this.lsp_word(span, name, true) ?? return;
    var def = at;
    match (this.item_of(this.si(sid).decl).kind) {
        .STRUCT(sd&) => {
            for (f&) in sd.fields.items() {
                if (f.name == name) {
                    def = this.name_span(f.span, name);
                }
            }
        },
        default => {},
    }
    put(&this.lsp_refs, { at: at, def: def, kind: LK_PROPERTY, label: fmt2("{}: {}", S(name), this.ty_name(ty)) });
}

// decl d (a global), named `name` at the end of span
attach fn lsp_decl_use(this: checker&, d: u32, name: str, span: span, label: std::string) -> void {
    val at = this.lsp_word(span, name, true) ?? return;
    var kind = LK_TYPE;
    var mods: u32 = 0;
    match (this.item_of(d).kind) {
        .STRUCT(s) => { kind = LK_STRUCT; },
        .ENUM(e) => { kind = LK_ENUM; },
        .TRAIT(n, fs) => { kind = LK_INTERFACE; },
        .GLOBAL(l&) => {
            kind = LK_VARIABLE;
            if (!l.mutable) {
                mods = LM_READONLY;
            }
        },
        .FN(f) => { kind = LK_FUNCTION; },
        default => {},
    }
    put(&this.lsp_refs, { at: at, def: this.name_span(this.item_of(d).span, name), label: move label, kind: kind, mods: mods, decl: d });
}

// what hover says about a type: struct point, enum color, error parse_error, trait shape
attach fn lsp_type_label(this: checker&, d: u32, name: str) -> std::string {
    var kw = "type";
    match (this.item_of(d).kind) {
        .STRUCT(s) => { kw = "struct"; },
        .ENUM(e&) => {
            kw = "enum";
            if (e.is_error) {
                kw = "error";
            }
        },
        .TRAIT(n, fs) => { kw = "trait"; },
        .ALIAS(n, t&) => {
            // what it names, as written (a C typedef's type has the `use c` span: no Volt source)
            if (t.span.lo > this.item_of(d).span.lo && @cast<usize>(t.span.file) < this.files.len) {
                return fmt2("type {} = {}", S(name), this.span_text(t.span));
            }
        },
        default => {},
    }
    return fmt2("{} {}", S(kw), S(name));
}

// where name is written in s as a whole word (the first place, or the last); null when it isn't
attach fn lsp_word(this: checker&, s: span, name: str, last: bool) -> span? {
    if (@cast<usize>(s.file) >= this.files.len) {
        return null;
    }
    return find_word(this.files.at(@cast<usize>(s.file)).text, s, name, last);
}

fn find_word(text: str, s: span, name: str, last: bool) -> span? {
    var hi = @cast<usize>(s.hi);
    if (hi > text.len) {
        hi = text.len;
    }
    var found: span? = null;
    var i = @cast<usize>(s.lo);
    while (name.len > 0 && i + name.len <= hi) {
        val before = i == 0 || !is_word_byte(text[i - 1]);
        val after = i + name.len >= text.len || !is_word_byte(text[i + name.len]);
        if (before && after && text[i..i + name.len] == name) {
            found = { file: s.file, lo: @cast<u32>(i), hi: @cast<u32>(i + name.len) };
            if (!last) {
                return found;
            }
            i += name.len;
        } else {
            i += 1;
        }
    }
    return found;
}

// fn instance inst's Volt signature (for a fn read from a C header: it has no declaration to show)
attach fn lsp_c_signature(this: checker&, inst: u32) -> std::string {
    var s = S("fn ");
    val f = this.fi(inst);
    val fd = this.fn_decl_of(f.decl);
    if (fd) {
        s.append(fd.name);
    }
    s.push('(');
    for (i) in 0..f.params.len {
        if (i > 0) {
            s.append(", ");
        }
        s.append(f.params.at(i).name);
        s.append(": ");
        s.append(this.ty_name(f.params.at(i).ty).as_str());
    }
    s.append(") -> ");
    s.append(this.ty_name(f.ret).as_str());
    return s;
}

// fn decl d's declaration as written, without its body, on one line; empty when it isn't written
// in Volt (a fn read from a C header has its `use` as its place)
attach fn lsp_decl_text(this: checker&, d: u32) -> std::string {
    var out: std::string = {};
    val f = this.fn_decl_of(d) ?? return {};
    val sp = this.item_of(d).span;
    // an operator's line starts at `operator`: its name (operator+, or eq for ==) isn't a word there
    var found = this.lsp_word(sp, "fn", false);
    if (found == null || this.lsp_word(sp, f.name, false) == null) {
        found = this.lsp_word(sp, "operator", false);
    }
    val kw = found ?? return {};
    val text = this.files.at(@cast<usize>(sp.file)).text;
    // from the start of the `fn` line (with `attach`, `extern "C"`...), not the attributes before it
    var lo = @cast<usize>(kw.lo);
    while (lo > @cast<usize>(sp.lo) && text[lo - 1] != '\n') {
        lo -= 1;
    }
    var hi = @cast<usize>(sp.hi);
    if (f.body) {
        hi = @cast<usize>(f.body.span.lo);
    }
    if (hi > text.len) {
        hi = text.len;
    }
    var space = false;
    for (i) in lo..hi {
        if (is_space(text[i])) {
            space = out.len() > 0;
        } else {
            if (space) {
                out.push(' ');
                space = false;
            }
            out.push(text[i]);
        }
    }
    if (out.len() > 0 && out.as_str()[out.len() - 1] == ';') {
        out.bytes.pop();
    }
    return out;
}

// the local named `name` declared in file last before offset at (else the first declared)
attach fn lsp_local_named(this: checker&, file: u32, name: str, at: usize) -> lsp_local* {
    var best: lsp_local* = null;
    for (l&) in this.lsp_locals.items() {
        if (l.def.file == file && l.name == name) {
            if (best == null || @cast<usize>(l.def.lo) <= at) {
                best = l;
            }
        }
    }
    return best;
}

// completion items for a value of type t0: its fields and the methods that take it as this
attach fn lsp_members(this: checker&, t0: u32, out: std::json::value&) -> void {
    val t = this.t.ref_inner(t0) ?? t0;
    match (*this.t.get(t)) {
        .STRUCT(sid) => {
            val fs = this.struct_fields(sid, {}) catch |e| {
                return;
            };
            for (f&) in fs.items() {
                out.add(lsp_item(f.name, 5.0, this.ty_name(f.ty).as_str()));
            }
        },
        default => {},
    }
    var names: std::vec<str> = {};
    map_keys(&this.attached, &names);
    for (n) in names.items() {
        for (d) in this.named(&this.attached, n).items() {
            if (this.takes_this(d, t)) {
                out.add(lsp_item(n, 2.0, this.lsp_decl_text(d).as_str()));
                break;
            }
        }
    }
}

// what path (a::b, from the root namespace) names
attach fn lsp_find(this: checker&, path: str) -> found? {
    var f: found? = null;
    var i: usize = 0;
    while (i < path.len) {
        var j = i;
        while (j < path.len && path[j] != ':') {
            j += 1;
        }
        val seg = path[i..j];
        if (i == 0) {
            f = this.lookup(0, seg);
        } else {
            match (f ?? return null) {
                .NS(n) => {
                    val child = this.ns(n).children.get(seg);
                    val l = this.ns(n).names.get(seg);
                    if (child) {
                        f = found::NS(*child);
                    } else if (l) {
                        f = found::DECLS(*l);
                    } else {
                        return null;
                    }
                },
                default => { return null; },
            }
        }
        i = j + 2;
    }
    return f;
}

// completion items for what path (a::b) names: a namespace's members (with those `use a::c;`
// makes reachable as a::name), or an enum's variants
attach fn lsp_path_members(this: checker&, path: str, out: std::json::value&) -> void {
    match (this.lsp_find(path) ?? return) {
        .NS(n) => { this.lsp_ns_items(n, out); },
        .DECLS(l) => {
            for (d) in this.list(l).items() {
                match (this.item_of(d).kind) {
                    .ENUM(e&) => {
                        for (v&) in e.variants.items() {
                            out.add(lsp_item(v.name, 20.0, ""));
                        }
                    },
                    default => {},
                }
            }
            return;
        },
    }
    for (u) in this.ns(0).uses.items() {
        var prefix: std::string = {};
        var full: std::string = {};
        for (k) in 0..u.segs.len {
            if (k > 0) {
                full.append("::");
            }
            full.append(u.segs.at(k).name);
            if (k + 2 == u.segs.len) {
                prefix = copy full;
            }
        }
        if (prefix.as_str() == path) {
            match (this.lsp_find(full.as_str()) ?? continue) {
                .NS(n) => { this.lsp_ns_items(n, out); },
                default => {},
            }
        }
    }
}

// completion items for namespace n's names and child namespaces
attach fn lsp_ns_items(this: checker&, n: u32, out: std::json::value&) -> void {
    var names: std::vec<str> = {};
    map_keys(&this.ns(n).names, &names);
    for (name) in names.items() {
        val l = this.ns(n).names.get(name) ?? continue;
        val d = *this.list(*l).at(0);
        match (this.recv_of(d)) {
            .NONE => {},
            default => { continue; }, // a method
        }
        var kind = 6.0; // variable
        var detail: std::string = {};
        match (this.item_of(d).kind) {
            .FN(f&) => {
                kind = 3.0;
                detail = this.lsp_decl_text(d);
            },
            .STRUCT(s&) => { kind = 22.0; },
            .ENUM(e&) => { kind = 13.0; },
            .TRAIT(a, b) => { kind = 8.0; },
            default => {},
        }
        out.add(lsp_item(name, kind, detail.as_str()));
    }
    var kids: std::vec<str> = {};
    map_keys(&this.ns(n).children, &kids);
    for (name) in kids.items() {
        out.add(lsp_item(name, 9.0, ""));
    }
}

// what path names, like lsp_find, or else through a `use a::c;` (a::name meaning a::c::name)
attach fn lsp_resolve(this: checker&, path: str) -> found? {
    val f = this.lsp_find(path);
    if (f != null) {
        return f;
    }
    var i = path.len;
    while (i > 0 && path[i - 1] != ':') {
        i -= 1;
    }
    if (i < 2) {
        return null;
    }
    val prefix = path[0..i - 2];
    for (u) in this.ns(0).uses.items() {
        if (u.segs.len < 2) {
            continue;
        }
        var full: std::string = {};
        var head: std::string = {}; // the use's path without its last name
        for (k) in 0..u.segs.len {
            if (k > 0) {
                full.append("::");
            }
            full.append(u.segs.at(k).name);
            if (k + 2 == u.segs.len) {
                head = copy full;
            }
        }
        if (head.as_str() != prefix) {
            continue;
        }
        full.append("::");
        full.append(path[i..path.len]);
        val g = this.lsp_find(full.as_str());
        if (g != null) {
            return g;
        }
    }
    return null;
}

// the fns a call of callee (a name, a::b, or a method's name when method) could mean
attach fn lsp_callees(this: checker&, callee: str, method: bool) -> std::vec<u32> {
    var out: std::vec<u32> = {};
    if (method) {
        return this.named(&this.attached, callee);
    }
    match (this.lsp_resolve(callee) ?? return {}) {
        .DECLS(l) => {
            for (d) in this.list(l).items() {
                if (this.fn_decl_of(d) != null) {
                    put(&out, d);
                }
            }
        },
        default => {},
    }
    return out;
}

// ---------- JSON pieces ----------

fn lsp_item(label: str, kind: f64, detail: str) -> std::json::value {
    var o = std::json::object();
    o.set("label", std::json::string(label));
    o.set("kind", std::json::number(kind));
    if (detail.len > 0) {
        o.set("detail", std::json::string(detail));
    }
    return o;
}

// the byte offset of LSP position pos (a line, and a column in UTF-16 code units) in text
fn lsp_offset(text: str, pos: std::json::value&) -> usize {
    val line = @cast<usize>(pos.get("line").as_num() ?? 0.0);
    val col = @cast<usize>(pos.get("character").as_num() ?? 0.0);
    var i: usize = 0;
    var l: usize = 0;
    while (l < line && i < text.len) {
        if (text[i] == '\n') {
            l += 1;
        }
        i += 1;
    }
    var units: usize = 0;
    while (i < text.len && text[i] != '\n' && units < col) {
        units += utf16_units(text[i]);
        i += 1;
        while (i < text.len && text[i] >= 128 && text[i] < 192) {
            i += 1;
        }
    }
    return i;
}

// UTF-16 code units for the character a UTF-8 byte starts (0 for a continuation byte)
fn utf16_units(b: u8) -> usize {
    if (b >= 240) {
        return 2;
    }
    if (b >= 128 && b < 192) {
        return 0;
    }
    return 1;
}

// the LSP position of byte offset at in text
fn lsp_pos(text: str, at0: usize) -> std::json::value {
    var at = at0;
    if (at > text.len) {
        at = text.len;
    }
    var line: usize = 0;
    var start: usize = 0;
    for (i) in 0..at {
        if (text[i] == '\n') {
            line += 1;
            start = i + 1;
        }
    }
    var units: usize = 0;
    for (i) in start..at {
        units += utf16_units(text[i]);
    }
    var p = std::json::object();
    p.set("line", std::json::number(@cast<f64>(line)));
    p.set("character", std::json::number(@cast<f64>(units)));
    return p;
}

fn lsp_range(text: str, s: span) -> std::json::value {
    var r = std::json::object();
    r.set("start", lsp_pos(text, @cast<usize>(s.lo)));
    r.set("end", lsp_pos(text, @cast<usize>(s.hi)));
    return r;
}

fn contains(s: span, file: u32, at: usize) -> bool {
    return s.file == file && @cast<usize>(s.lo) <= at && at <= @cast<usize>(s.hi);
}

// a file:// URI's path, %XX escapes decoded
fn uri_path(uri: str) -> std::string {
    var s = uri;
    if (starts_with(s, "file://")) {
        s = s[7..s.len];
    }
    var out: std::string = {};
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' && i + 2 < s.len) {
            val hi = digit_value(s[i + 1]);
            val lo = digit_value(s[i + 2]);
            if (hi < 16 && lo < 16) {
                out.push(@cast<u8>(hi * 16 + lo));
                i += 3;
                continue;
            }
        }
        out.push(s[i]);
        i += 1;
    }
    return out;
}

// the file:// URI of a path
fn path_uri(path: str) -> std::string {
    var out = S("file://");
    val hex = "0123456789ABCDEF";
    for (b) in path {
        if (is_alnum(b) || b == '/' || b == '-' || b == '.' || b == '_' || b == '~') {
            out.push(b);
        } else {
            out.push('%');
            out.push(hex[@cast<usize>(b >> 4)]);
            out.push(hex[@cast<usize>(b & 15)]);
        }
    }
    return out;
}

// ---------- the server ----------

// an open document, and the last check of it that parsed: its sources, the checker (with the
// index) and which of the sources it is
struct lsp_doc {
    uri: std::string;
    text: std::string = {};
    chk: std::box<checker>? = null;
    src: std::box<sources>? = null;
    file: u32 = 0;
    dirty: bool = false; // changed since the last check
}

struct lsp_server {
    std_dir: std::string? = null;
    hint_types: bool = true;  // inlay hints the client asked for (initializationOptions)
    hint_params: bool = true;
    hint_braces: bool = true;
    docs: std::vec<lsp_doc> = {};
    down: bool = false; // shutdown was asked for: exit is expected
    bolt: std::vec<bolt_libs> = {}; // per bolt package root
}

// the libraries a bolt package's code can use (its own and every dependency's), from
// `bolt metadata`, and the bolt.toml text they were read for
struct bolt_libs {
    root: std::string;
    manifest: std::string;
    names: std::vec<std::string> = {};
    dirs: std::vec<std::string> = {};
}

// the libraries for the package at root, read again when its bolt.toml changed
attach fn libs_for(this: lsp_server&, root: str) -> bolt_libs& {
    var toml = S(root);
    toml.append("/bolt.toml");
    val text = std::fs::read_file(toml.as_str()) catch S("");
    var at: usize? = null;
    for (i) in 0..this.bolt.len {
        if (this.bolt.at(i).root.as_str() == root) {
            at = i;
        }
    }
    if (at == null) {
        put(&this.bolt, { root: S(root), manifest: move text });
        val fresh = this.bolt.at(this.bolt.len - 1);
        read_bolt(fresh);
        return fresh;
    }
    val b = this.bolt.at(at ?? 0);
    if (b.manifest.as_str() != text.as_str()) {
        b.manifest = move text;
        read_bolt(b);
    }
    return b;
}

// `bolt metadata` for the package at out.root: each package with a library, and its directory.
// None when bolt isn't on PATH or fails (a git dependency not fetched yet: the server stays offline)
fn read_bolt(out: bolt_libs&) -> void {
    out.names = {};
    out.dirs = {};
    var toml = copy out.root;
    toml.append("/bolt.toml");
    val argv: str[] = { "bolt", "metadata", "--offline", "--quiet", "--manifest-path", toml.as_str() };
    val r = std::process::capture(argv[..], "") catch |e| {
        return;
    };
    if (r.code != 0) {
        return;
    }
    val meta = std::json::parse(r.out.as_str()) catch |e| {
        return;
    };
    val pkgs = meta.get("packages");
    for (k) in 0..pkgs.len() {
        val p = pkgs.at(k);
        val name = p.get("name").as_str() ?? "";
        // a library directory must be inside its package (next to its bolt.toml): a crafted
        // manifest can't send the server walking the disk, or stand in for std
        val manifest = p.get("manifest_path").as_str() ?? "";
        var home = manifest.len;
        while (home > 0 && manifest[home - 1] != '/') {
            home -= 1;
        }
        if (name.len == 0 || name == "std" || home == 0) {
            continue;
        }
        val ts = p.get("targets");
        for (j) in 0..ts.len() {
            val t = ts.at(j);
            val dir = t.get("src_path").as_str() ?? "";
            if ((t.get("kind").as_str() ?? "") == "lib" && starts_with(dir, manifest[0..home]) && !has_dotdot(dir)) {
                put(&out.names, S(name));
                put(&out.dirs, S(dir));
            }
        }
    }
}

// add_file for the server: a file it can't read is left out (a file that vanished, or an
// unreadable one in an untrusted repository), where the command line would stop
fn lsp_add_file(s: sources&, path: str, pkg: str?) -> void {
    val text = std::fs::read_file(path) catch |e| {
        return;
    };
    put(&s.names, S(path));
    put(&s.texts, move text);
    put(&s.units, { file: @cast<u32>(s.names.len - 1), pkg: pkg });
}

// does path climb out anywhere (a /../ part)?
fn has_dotdot(path: str) -> bool {
    var i: usize = 0;
    while (i + 3 <= path.len) {
        if (path[i..i + 3] == "/..") {
            if (i + 3 == path.len || path[i + 3] == '/') {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

// the directory holding the nearest bolt.toml above path (null: none)
fn package_root(path: str) -> std::string? {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            var toml = S(path[0..i]);
            toml.append("/bolt.toml");
            if (sys::access(toml.c_str(), 0) == 0) {
                return S(path[0..i]);
            }
        }
    }
    return null;
}

// reads messages from stdin
struct lsp_reader {
    buf: std::string = {};
}

// the next message's body; null when the input ends
attach fn next(this: lsp_reader&) -> std::string? {
    loop {
        val b = this.buf.as_str();
        var h: usize = 0;
        while (h + 4 <= b.len && b[h..h + 4] != "\r\n\r\n") {
            h += 1;
        }
        if (h + 4 <= b.len) {
            val len = content_length(b[0..h]);
            val end = h + 4 + len;
            if (b.len >= end) {
                val body = S(b[h + 4..end]);
                this.buf = S(b[end..b.len]);
                return body;
            }
        }
        var chunk: u8[65536];
        var n = sys::read(0, @cast<void*>(&chunk[0]), 65536);
        while (n < 0 && std::process::interrupted()) {
            n = sys::read(0, @cast<void*>(&chunk[0]), 65536);
        }
        if (n <= 0) {
            return null;
        }
        this.buf.append(@cast<str>(@slice(&chunk[0], @cast<usize>(n))));
    }
}

// more input is waiting (typing sends a change per key: checking waits for the last)
attach fn pending(this: lsp_reader&) -> bool {
    if (this.buf.len() > 0) {
        return true;
    }
    var p: sys::pollfd = { fd: 0, events: 1, revents: 0 }; // POLLIN
    return sys::poll(&p, 1, 0) > 0;
}

// the Content-Length in a message's headers
fn content_length(headers: str) -> usize {
    val key = "Content-Length:";
    var n: usize = 0;
    var i: usize = 0;
    while (i + key.len <= headers.len) {
        if (headers[i..i + key.len] == key) {
            var j = i + key.len;
            while (j < headers.len && headers[j] == ' ') {
                j += 1;
            }
            while (j < headers.len && is_digit(headers[j])) {
                n = n * 10 + @cast<usize>(headers[j] - '0');
                j += 1;
            }
            return n;
        }
        i += 1;
    }
    return n;
}

fn lsp_send(msg: std::json::value&) -> void {
    val body = msg.text();
    var out = S("Content-Length: ");
    out.append_uint(@cast<u64>(body.len()));
    out.append("\r\n\r\n");
    out.append(body.as_str());
    val s = out.as_str();
    var done: usize = 0;
    while (done < s.len) {
        val n = sys::write(1, @cast<void*>(s[done..s.len].ptr), s.len - done);
        if (n < 0 && std::process::interrupted()) {
            continue;
        }
        if (n <= 0) {
            std::process::exit(1);
        }
        done += @cast<usize>(n);
    }
}

// a request's id (a number or a string) for its response
fn lsp_id(id: std::json::value&) -> std::json::value {
    val s = id.as_str();
    if (s) {
        return std::json::string(s);
    }
    return std::json::number(id.as_num() ?? 0.0);
}

fn lsp_reply(id: std::json::value&, result: std::json::value) -> void {
    var m = std::json::object();
    m.set("jsonrpc", std::json::string("2.0"));
    m.set("id", lsp_id(id));
    m.set("result", move result);
    lsp_send(&m);
}

fn lsp_notify(method: str, params: std::json::value) -> void {
    var m = std::json::object();
    m.set("jsonrpc", std::json::string("2.0"));
    m.set("method", std::json::string(method));
    m.set("params", move params);
    lsp_send(&m);
}

fn lsp_capabilities() -> std::json::value {
    var caps = std::json::object();
    caps.set("textDocumentSync", std::json::number(1.0)); // the whole text on every change
    caps.set("hoverProvider", std::json::value::BOOL(true));
    caps.set("definitionProvider", std::json::value::BOOL(true));
    caps.set("referencesProvider", std::json::value::BOOL(true));
    caps.set("documentSymbolProvider", std::json::value::BOOL(true));
    var trig = std::json::array();
    trig.add(std::json::string("."));
    trig.add(std::json::string(":"));
    var comp = std::json::object();
    comp.set("triggerCharacters", move trig);
    caps.set("completionProvider", move comp);
    var sig_trig = std::json::array();
    sig_trig.add(std::json::string("("));
    sig_trig.add(std::json::string(","));
    var sig = std::json::object();
    sig.set("triggerCharacters", move sig_trig);
    caps.set("signatureHelpProvider", move sig);
    lsp_inline_capabilities(&caps);
    var info = std::json::object();
    info.set("name", std::json::string("voltc"));
    var r = std::json::object();
    r.set("capabilities", move caps);
    r.set("serverInfo", move info);
    return r;
}

// `voltc lsp`: serve until exit (or the end of the input)
fn lsp_main(std_dir: std::string?) -> i32 {
    var srv: lsp_server = { std_dir: move std_dir };
    var r: lsp_reader = {};
    loop {
        val body = r.next() ?? break;
        val msg = std::json::parse(body.as_str()) catch |e| {
            continue;
        };
        if (srv.handle(&msg)) {
            break;
        }
        if (!r.pending()) {
            srv.flush();
        }
    }
    if (srv.down) {
        return 0;
    }
    return 1;
}

// the index of the document at uri (added when it's new)
attach fn doc_index(this: lsp_server&, uri: str) -> usize {
    for (i) in 0..this.docs.len {
        if (this.docs.at(i).uri.as_str() == uri) {
            return i;
        }
    }
    put(&this.docs, { uri: S(uri) });
    return this.docs.len - 1;
}

// the open document a request's params name; null when it isn't open
attach fn find_doc(this: lsp_server&, params: std::json::value&) -> lsp_doc* {
    val uri = params.get("textDocument").get("uri").as_str() ?? "";
    for (d&) in this.docs.items() {
        if (d.uri.as_str() == uri) {
            return d;
        }
    }
    return null;
}

// the document a request's params name, with its last check; null when it has none
attach fn checked_doc(this: lsp_server&, params: std::json::value&) -> lsp_doc* {
    val d = this.find_doc(params) ?? return null;
    if (d.chk == null) {
        return null;
    }
    return d;
}

// handle one message; true when it's exit
attach fn handle(this: lsp_server&, msg: std::json::value&) -> bool {
    val method = msg.get("method").as_str() ?? "";
    val id = msg.get("id");
    val params = msg.get("params");
    if (method == "exit") {
        return true;
    } else if (method == "initialize") {
        this.read_options(params.get("initializationOptions"));
        lsp_reply(id, lsp_capabilities());
    } else if (method == "shutdown") {
        this.down = true;
        lsp_reply(id, std::json::value::NULL);
    } else if (method == "textDocument/didOpen") {
        val td = params.get("textDocument");
        val i = this.doc_index(td.get("uri").as_str() ?? "");
        this.docs.at(i).text = S(td.get("text").as_str() ?? "");
        this.docs.at(i).dirty = true;
    } else if (method == "textDocument/didChange") {
        val changes = params.get("contentChanges");
        if (changes.len() > 0) {
            val i = this.doc_index(params.get("textDocument").get("uri").as_str() ?? "");
            this.docs.at(i).text = S(changes.at(changes.len() - 1).get("text").as_str() ?? "");
            this.docs.at(i).dirty = true;
        }
    } else if (method == "textDocument/didClose") {
        val i = this.doc_index(params.get("textDocument").get("uri").as_str() ?? "");
        val doc = this.docs.at(i);
        doc.dirty = false;
        doc.chk = null;
        doc.src = null;
        var p = std::json::object();
        p.set("uri", std::json::string(doc.uri.as_str()));
        p.set("diagnostics", std::json::array());
        lsp_notify("textDocument/publishDiagnostics", move p);
    } else if (method == "textDocument/hover") {
        this.flush();
        lsp_reply(id, this.hover(params));
    } else if (method == "textDocument/definition") {
        this.flush();
        lsp_reply(id, this.definition(params));
    } else if (method == "textDocument/references") {
        this.flush();
        lsp_reply(id, this.references(params));
    } else if (method == "textDocument/documentSymbol") {
        lsp_reply(id, this.symbols(params));
    } else if (method == "textDocument/completion") {
        lsp_reply(id, this.complete(params));
    } else if (method == "textDocument/signatureHelp") {
        lsp_reply(id, this.signature(params));
    } else if (method == "volt/expand") {
        this.flush();
        lsp_reply(id, this.expand(params));
    } else if (this.inline_request(method, id, params)) {
        // lsp_inline.volt answered it
    } else if (!id.is_null()) {
        var err = std::json::object();
        err.set("code", std::json::number(-32601.0));
        err.set("message", std::json::string("method not found"));
        var m = std::json::object();
        m.set("jsonrpc", std::json::string("2.0"));
        m.set("id", lsp_id(id));
        m.set("error", move err);
        lsp_send(&m);
    }
    return false;
}

// re-check the documents that changed, publishing their diagnostics
attach fn flush(this: lsp_server&) -> void {
    for (i) in 0..this.docs.len {
        if (this.docs.at(i).dirty) {
            this.docs.at(i).dirty = false;
            this.update(i);
        }
    }
}

// re-check document i and publish its diagnostics
attach fn update(this: lsp_server&, i: usize) -> void {
    val doc = this.docs.at(i);
    val diags = this.check_doc(doc);
    val text = doc.text.as_str();
    var list = std::json::array();
    for (d&) in diags.items() {
        var o = std::json::object();
        o.set("range", lsp_range(text, d.span));
        var sev = 1.0;
        if (d.warning) {
            sev = 2.0;
        }
        o.set("severity", std::json::number(sev));
        o.set("source", std::json::string("voltc"));
        var m = copy d.msg;
        for (n&) in d.notes.items() {
            m.push('\n');
            m.append(n.as_str());
        }
        o.set("message", std::json::string(m.as_str()));
        if (d.fixes.len > 0) {
            var data = std::json::object();
            data.set("fixes", fixes_json(doc, d));
            o.set("data", move data);
        }
        list.add(move o);
    }
    var p = std::json::object();
    p.set("uri", std::json::string(doc.uri.as_str()));
    p.set("diagnostics", move list);
    lsp_notify("textDocument/publishDiagnostics", move p);
}

// Check doc: std, the libraries its bolt package can use (bolt metadata), the other files of its
// program (the .volt files under the src/ it's in), and its text. Keeps the check when everything
// parsed. The document's diagnostics
attach fn check_doc(this: lsp_server&, doc: lsp_doc&) -> std::vec<diag> {
    var diags: std::vec<diag> = {};
    var sb = bx<sources>({});
    val s = &*sb;
    val path = uri_path(doc.uri.as_str());
    if (this.std_dir != null) {
        for (f&) in volt_files(this.std_dir.value.as_str()).items() {
            lsp_add_file(s, f.as_str(), "std");
        }
    }
    // the libraries its bolt package can use; a document inside one of them is part of it
    var own: str? = null;
    val root = package_root(path.as_str());
    if (root) {
        val libs = this.libs_for(root.as_str());
        for (k) in 0..libs.names.len {
            put(&s.pkg_names, copy *libs.names.at(k));
            val name = s.pkg_names.at(s.pkg_names.len - 1).as_str(); // outlives a bolt.toml change
            var dir = copy *libs.dirs.at(k);
            dir.push('/');
            if (starts_with(path.as_str(), dir.as_str())) {
                own = name;
            }
            for (f&) in volt_files(libs.dirs.at(k).as_str()).items() {
                if (f.as_str() != path.as_str()) {
                    lsp_add_file(s, f.as_str(), name);
                }
            }
        }
    }
    if (own == null) {
        for (f&) in package_files(path.as_str()).items() {
            if (f.as_str() != path.as_str()) {
                lsp_add_file(s, f.as_str(), null);
            }
        }
    }
    put(&s.names, copy path);
    put(&s.texts, copy doc.text);
    put(&s.units, { file: @cast<u32>(s.names.len - 1), pkg: own });
    val file = @cast<u32>(s.names.len - 1);
    for (i) in 0..s.names.len {
        put(&s.files, { name: s.names.at(i).as_str(), text: s.texts.at(i).as_str() });
    }
    s.test_mode = 2; // test blocks are checked as plain fns
    val bad = parse_sources(s);
    if (bad.len > 0) {
        for (b&) in bad.items() {
            var d = copy *b;
            if (d.span.file != file) {
                // another file of the program doesn't parse: say so at the top
                d.msg = fmt2("{} doesn't parse: {}", S(s.files.at(@cast<usize>(d.span.file)).name), copy d.msg);
                d.span = { file: file };
            }
            put(&diags, move d);
        }
        return diags;
    }
    var o: opts = { lsp: true };
    for (u&) in s.units.items() {
        if (u.pkg) {
            put(&o.pkg_files, { file: u.file, pkg: u.pkg });
        }
    }
    val chk = compile(&s.files, &s.asts, move o);
    for (d&) in all_diags(&*chk).items() {
        if (d.span.file == file) {
            put(&diags, copy *d);
        }
    }
    doc.file = file;
    doc.chk = move chk;
    doc.src = move sb;
    return diags;
}

// lex and parse every source (a package's files wrapped in its namespace); every error, in order
// (a lexer error stops its file, a parse error its item)
fn parse_sources(s: sources&) -> std::vec<diag> {
    var errors: std::vec<diag> = {};
    var lexed: std::vec<bool> = {};
    for (i) in 0..s.files.len {
        val t = lex(s.files.at(i).text, @cast<u32>(i)) catch |e| {
            put(&errors, err_diag(&e));
            put(&s.toks, {});
            put(&lexed, false);
            continue;
        };
        put(&s.toks, move t);
        put(&lexed, true);
    }
    var names: std::map<str, bool> = {};
    for (t&) in s.toks.items() {
        collect_generic_names(t, &names);
    }
    for (i) in 0..s.toks.len {
        // a file that fails keeps its place in s.asts (empty), so indexes still match s.files
        if (!*lexed.at(i)) {
            put(&s.asts, {});
            continue;
        }
        var p: parser = { src: s.files.at(i).text, toks: s.toks.at(i), pos: 0, generics: &names };
        val items = p.parse_file() catch |e| {
            for (d&) in p.errors.items() {
                put(&errors, copy *d);
            }
            put(&s.asts, {});
            continue;
        };
        val u = s.units.at(i);
        if (u.pkg) {
            var wrapped: std::vec<item> = {};
            var path: std::vec<str> = {};
            put(&path, u.pkg);
            put(&wrapped, { kind: item_kind::NAMESPACE(move path, move items), span: { file: u.file }, attrs: {}, vis: vis::PUBLIC, generics: {} });
            put(&s.asts, move wrapped);
        } else {
            put(&s.asts, move items);
        }
    }
    for (d&) in test_items(s).items() {
        put(&errors, copy *d);
    }
    sort_diags(&errors);
    return errors;
}

// test blocks (fns the parser makes from `test "name" { }`, named in a @test attribute): left out
// (s.test_mode 0), run instead of main from a main written here over std::testing::run_main (1:
// --test, the program's own tests and --test-pkg packages'), or kept as plain fns (2: the language
// server)
fn test_items(s: sources&) -> std::vec<diag> {
    var found: std::vec<std::string> = {}; // the generated main's `{ name: "...", body: path },`s
    for (i) in 0..s.asts.len {
        var own = false;
        if (i < s.units.len) {
            val pkg = s.units.at(i).pkg;
            own = pkg == null;
            for (t&) in s.test_pkgs.items() {
                if (pkg != null && (pkg ?? "") == *t) {
                    own = true;
                }
            }
        }
        keep_tests(s.asts.at(i), S(""), s.test_mode != 0 && own, s.test_mode == 1 && own, &s.test_names, &found);
    }
    if (s.test_mode != 1) {
        return {};
    }
    var src = S("fn main() -> i32 {\n    val tests: std::testing::test[");
    src.append_uint(@cast<u64>(found.len));
    src.append("] = {");
    for (f&) in found.items() {
        src.append(f.as_str());
    }
    src.append(" };\n    return std::testing::run_main(tests[..]);\n}\n");
    return add_source(s, "<tests>", move src);
}

// takes the tests out of items, or (keep) names them __test<n> (into names), public (the generated
// main calls a package's) and without their @test attribute, and (drop_main) takes main out; each
// kept test's entry for the generated main into found
fn keep_tests(items: std::vec<item>&, prefix: std::string, keep: bool, drop_main: bool, names: std::vec<std::string>&, found: std::vec<std::string>&) -> void {
    var rev: std::vec<item> = {};
    loop {
        var it = items.pop() ?? break;
        put(&rev, move it);
    }
    loop {
        var it = rev.pop() ?? break;
        var out = true;
        val label = test_label(&it.attrs);
        match (it.kind) {
            .FN(f&) => {
                if (label != null) {
                    out = keep;
                    if (keep) {
                        var n = S("__test");
                        n.append_uint(@cast<u64>(names.len + 1));
                        put(names, move n);
                        f.name = names.at(names.len - 1).as_str();
                        var e = S(" { name: \"");
                        escape_label(label ?? "", &e);
                        e.append("\", body: ");
                        e.append(prefix.as_str());
                        e.append(f.name);
                        e.append(" },");
                        put(found, move e);
                    }
                } else if (drop_main && prefix.len() == 0 && f.name == "main") {
                    out = false;
                }
            },
            .NAMESPACE(p&, inner&) => {
                var sub = copy prefix;
                for (seg&) in p.items() {
                    sub.append(*seg);
                    sub.append("::");
                }
                keep_tests(inner, move sub, keep, drop_main, names, found);
            },
            default => {},
        }
        if (out) {
            if (label != null) {
                it.attrs = {};
                it.vis = vis::PUBLIC;
            }
            put(items, move it);
        }
    }
}

// a @test attribute's name, if attrs has one
fn test_label(attrs: std::vec<expr>&) -> str? {
    for (a&) in attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g&, args&) => {
                if (n != "test") {
                    continue;
                }
                val al = ptr_of(args) ?? continue;
                if (al.len > 0) {
                    match (*al.at(0)) {
                        .EXPR(e&) => {
                            match (e.kind) {
                                .STR(text&) => { return text.as_str(); },
                                default => {},
                            }
                        },
                        default => {},
                    }
                }
            },
            default => {},
        }
    }
    return null;
}

// a test's name as the inside of a Volt string literal
fn escape_label(s: str, out: std::string&) -> void {
    val hex = "0123456789abcdef";
    for (c) in s {
        if (c == '"' || c == '\\') {
            out.push('\\');
            out.push(c);
        } else if (c >= 0x20 && c < 0x7f) {
            out.push(c);
        } else {
            out.append("\\x");
            out.push(hex[c >> 4]);
            out.push(hex[c & 15]);
        }
    }
}

// one more file of the program, written here (name: what errors in it say): lexed and parsed like
// the others
fn add_source(s: sources&, name: str, text: std::string) -> std::vec<diag> {
    var errors: std::vec<diag> = {};
    put(&s.names, S(name));
    put(&s.texts, move text);
    val i = s.names.len - 1;
    put(&s.units, { file: @cast<u32>(i), pkg: null });
    put(&s.files, { name: s.names.at(i).as_str(), text: s.texts.at(i).as_str() });
    val t = lex(s.files.at(i).text, @cast<u32>(i)) catch |e| {
        put(&errors, err_diag(&e));
        return errors;
    };
    put(&s.toks, move t);
    var names: std::map<str, bool> = {};
    var p: parser = { src: s.files.at(i).text, toks: s.toks.at(i), pos: 0, generics: &names };
    val items = p.parse_file() catch |e| {
        for (d&) in p.errors.items() {
            put(&errors, copy *d);
        }
        return errors;
    };
    put(&s.asts, move items);
    return errors;
}

// the program files of the bolt package path is in (under DIR/src/, with DIR/bolt.toml); none
// when it isn't in one
fn package_files(path: str) -> std::vec<std::string> {
    var i = path.len;
    while (i > 4) {
        i -= 1;
        if (path[i] == '/' && path[i - 4..i] == "/src") {
            var toml = S(path[0..i - 4]);
            toml.append("/bolt.toml");
            if (sys::access(toml.c_str(), 0) == 0) {
                return volt_files(path[0..i]);
            }
        }
    }
    return {};
}

// the byte offset a request's position names in the checked text of doc
fn doc_offset(doc: lsp_doc&, params: std::json::value&) -> usize {
    val c = &*doc.chk.value;
    return lsp_offset(c.files.at(@cast<usize>(doc.file)).text, params.get("position"));
}

// the name at offset at: the use there, else the declaration there (a use of it names it)
fn ref_at(c: checker&, file: u32, at: usize) -> lsp_ref* {
    var best: lsp_ref* = null;
    for (r&) in c.lsp_refs.items() {
        if (contains(r.at, file, at)) {
            if (best == null || r.at.hi - r.at.lo < best->at.hi - best->at.lo) {
                best = r;
            }
        }
    }
    if (best == null) {
        for (r&) in c.lsp_refs.items() {
            if (contains(r.def, file, at)) {
                return r;
            }
        }
    }
    return best;
}

// a location: the span in its file, by URI
fn lsp_location(doc: lsp_doc&, c: checker&, s: span) -> std::json::value {
    var l = std::json::object();
    val f = c.files.at(@cast<usize>(s.file));
    if (s.file == doc.file) {
        l.set("uri", std::json::string(doc.uri.as_str()));
    } else {
        l.set("uri", std::json::string(path_uri(f.name).as_str()));
    }
    l.set("range", lsp_range(f.text, s));
    return l;
}

attach fn hover(this: lsp_server&, params: std::json::value&) -> std::json::value {
    val doc = this.checked_doc(params) ?? return std::json::value::NULL;
    val c = &*doc.chk.value;
    val at = doc_offset(doc, params);
    var label: std::string = {};
    val r = ref_at(c, doc.file, at);
    if (r) {
        label = copy r->label;
        if (r->decl != null && (r->kind == LK_STRUCT || r->kind == LK_ENUM || r->kind == LK_INTERFACE)) {
            label = c.type_hover(r->decl ?? 0);
        }
    } else {
        // a local declared here and never used
        for (l&) in c.lsp_locals.items() {
            if (contains(l.def, doc.file, at)) {
                label = fmt2("{}: {}", S(l.name), c.ty_name(l.ty));
            }
        }
    }
    val exp = expansion_at(c, doc.file, at);
    if (label.len() == 0 && exp.len() == 0) {
        return std::json::value::NULL;
    }
    var text: std::string = {};
    if (label.len() > 0) {
        text.append("```volt\n");
        text.append(label.as_str());
        text.append("\n```\n");
    }
    if (exp.len() > 0) {
        text.append("expands to\n```volt\n");
        text.append(exp.as_str());
        text.append("\n```");
    }
    var contents = std::json::object();
    contents.set("kind", std::json::string("markdown"));
    contents.set("value", std::json::string(text.as_str()));
    var h = std::json::object();
    h.set("contents", move contents);
    return h;
}

// what the comptime code at offset at became: the notes on the innermost span recorded there
// (a generic fn's body has one per instance; the same text shows once)
fn expansion_at(c: checker&, file: u32, at: usize) -> std::string {
    var width: u32? = null;
    for (e&) in c.expansions.items() {
        if (contains(e.at, file, at) && (width == null || e.at.hi - e.at.lo < (width ?? 0))) {
            width = e.at.hi - e.at.lo;
        }
    }
    var out: std::string = {};
    var seen: std::vec<str> = {};
    for (e&) in c.expansions.items() {
        if (contains(e.at, file, at) && e.at.hi - e.at.lo == (width ?? 0)) {
            var dup = false;
            for (s&) in seen.items() {
                if (*s == e.text.as_str()) {
                    dup = true;
                }
            }
            if (!dup) {
                put(&seen, e.text.as_str());
                if (out.len() > 0) {
                    out.push('\n');
                }
                out.append(e.text.as_str());
            }
        }
    }
    return out;
}

// volt/expand: what the comptime code in a document (or on params.line, 0-based) became, as
// [{ range, text }] in the order it was checked
attach fn expand(this: lsp_server&, params: std::json::value&) -> std::json::value {
    var out = std::json::array();
    val doc = this.checked_doc(params) ?? return out;
    val c = &*doc.chk.value;
    val text = c.files.at(@cast<usize>(doc.file)).text;
    val line = params.get("line").as_num();
    for (e&) in c.expansions.items() {
        if (e.at.file == doc.file && (line == null || @cast<f64>(c.line_col(e.at).line - 1) == (line ?? 0.0))) {
            var o = std::json::object();
            o.set("range", lsp_range(text, e.at));
            o.set("text", std::json::string(e.text.as_str()));
            out.add(move o);
        }
    }
    return out;
}

attach fn definition(this: lsp_server&, params: std::json::value&) -> std::json::value {
    val doc = this.checked_doc(params) ?? return std::json::value::NULL;
    val c = &*doc.chk.value;
    val r = ref_at(c, doc.file, doc_offset(doc, params)) ?? return std::json::value::NULL;
    return lsp_location(doc, c, r->def);
}

attach fn references(this: lsp_server&, params: std::json::value&) -> std::json::value {
    val doc = this.checked_doc(params) ?? return std::json::array();
    val c = &*doc.chk.value;
    val at = doc_offset(doc, params);
    var def: span? = null;
    val r = ref_at(c, doc.file, at);
    if (r) {
        def = r->def;
    } else {
        for (l&) in c.lsp_locals.items() {
            if (contains(l.def, doc.file, at)) {
                def = l.def;
            }
        }
    }
    val d = def ?? return std::json::array();
    var out = std::json::array();
    if (params.get("context").get("includeDeclaration").as_bool() ?? false) {
        out.add(lsp_location(doc, c, d));
    }
    var seen: std::vec<span> = {};
    for (x&) in c.lsp_refs.items() {
        if (same_span(x.def, d)) {
            var dup = false;
            for (s&) in seen.items() {
                if (same_span(*s, x.at)) {
                    dup = true;
                }
            }
            if (!dup) {
                put(&seen, x.at);
                out.add(lsp_location(doc, c, x.at));
            }
        }
    }
    return out;
}

// the document's declarations (from its current text; none while it doesn't parse)
attach fn symbols(this: lsp_server&, params: std::json::value&) -> std::json::value {
    val doc = this.find_doc(params) ?? return std::json::array();
    val text = doc.text.as_str();
    val toks = lex(text, 0) catch |e| {
        return std::json::array();
    };
    var names: std::map<str, bool> = {};
    collect_generic_names(&toks, &names);
    var p: parser = { src: text, toks: &toks, pos: 0, generics: &names };
    val items = p.parse_file() catch |e| {
        return std::json::array();
    };
    var out = std::json::array();
    add_symbols(text, &items, &out);
    return out;
}

fn add_symbols(text: str, items: std::vec<item>&, out: std::json::value&) -> void {
    for (it&) in items.items() {
        var name = "";
        var kind = 0.0;
        var kids = std::json::array();
        match (it.kind) {
            .FN(f&) => {
                name = f.name;
                kind = 12.0;
                if (f.is_attach) {
                    kind = 6.0;
                }
            },
            .STRUCT(s&) => {
                name = s.name;
                kind = 23.0;
                for (f&) in s.fields.items() {
                    kids.add(symbol(text, f.name, 8.0, f.span, std::json::array()));
                }
            },
            .ENUM(e&) => {
                name = e.name;
                kind = 10.0;
                for (v&) in e.variants.items() {
                    kids.add(symbol(text, v.name, 22.0, v.span, std::json::array()));
                }
            },
            .TRAIT(n, fs&) => {
                name = n;
                kind = 11.0;
                add_symbols(text, fs, &kids);
            },
            .ATTACH(a, b, fs&) => { add_symbols(text, fs, out); },
            .ALIAS(n, t) => {
                name = n;
                kind = 26.0; // TypeParameter: LSP has no alias kind (rust-analyzer uses this one too)
            },
            .NAMESPACE(path&, xs&) => {
                if (path.len > 0) {
                    name = *path.at(path.len - 1);
                }
                kind = 3.0;
                add_symbols(text, xs, &kids);
            },
            .GLOBAL(l&) => {
                match (l.pat.kind) {
                    .BIND(n) => {
                        name = n;
                        kind = 13.0;
                    },
                    default => {},
                }
            },
            default => {},
        }
        if (name.len > 0) {
            out.add(symbol(text, name, kind, it.span, move kids));
        }
    }
}

// a DocumentSymbol: its whole span, and where its name is
fn symbol(text: str, name: str, kind: f64, s: span, kids: std::json::value) -> std::json::value {
    var o = std::json::object();
    o.set("name", std::json::string(name));
    o.set("kind", std::json::number(kind));
    o.set("range", lsp_range(text, s));
    o.set("selectionRange", lsp_range(text, find_word(text, s, name, false) ?? s));
    o.set("children", move kids);
    return o;
}

// completion at the cursor: after `x.`, x's fields and methods; after `a::`, what a declares;
// otherwise the locals, the program's names and the keywords (the editor filters by what's typed)
attach fn complete(this: lsp_server&, params: std::json::value&) -> std::json::value {
    val doc = this.find_doc(params) ?? return std::json::array();
    var out = std::json::array();
    val text = doc.text.as_str();
    val at = lsp_offset(text, params.get("position"));
    var i = at;
    while (i > 0 && is_word_byte(text[i - 1])) {
        i -= 1;
    }
    if (doc.chk == null) {
        for (k) in KEYWORDS {
            out.add(lsp_item(k, 14.0, ""));
        }
        return out;
    }
    val c = &*doc.chk.value;
    if (i > 0 && text[i - 1] == '.') {
        var k = i - 1;
        while (k > 0 && is_word_byte(text[k - 1])) {
            k -= 1;
        }
        val l = c.lsp_local_named(doc.file, text[k..i - 1], at);
        if (l) {
            c.lsp_members(l->ty, &out);
        }
        return out;
    }
    if (i > 1 && text[i - 1] == ':' && text[i - 2] == ':') {
        var k = i - 2;
        while (k > 0 && (is_word_byte(text[k - 1]) || text[k - 1] == ':')) {
            k -= 1;
        }
        c.lsp_path_members(text[k..i - 2], &out);
        return out;
    }
    var seen: std::map<str, bool> = {};
    for (l&) in c.lsp_locals.items() {
        if (l.def.file == doc.file && @cast<usize>(l.def.lo) <= at && seen.get(l.name) == null) {
            seen.put(l.name, true);
            out.add(lsp_item(l.name, 6.0, c.ty_name(l.ty).as_str()));
        }
    }
    c.lsp_ns_items(0, &out);
    for (k) in KEYWORDS {
        out.add(lsp_item(k, 14.0, ""));
    }
    return out;
}

// signature help inside a call's parentheses: the callee's declarations, and which argument the
// cursor is in
attach fn signature(this: lsp_server&, params: std::json::value&) -> std::json::value {
    val doc = this.checked_doc(params) ?? return std::json::value::NULL;
    val c = &*doc.chk.value;
    val text = doc.text.as_str();
    // back to the ( the cursor is inside, counting the commas at its level
    var i = lsp_offset(text, params.get("position"));
    var depth = 0;
    var commas = 0.0;
    var open: usize? = null;
    while (i > 0 && open == null) {
        i -= 1;
        val ch = text[i];
        if (ch == ')' || ch == ']' || ch == '}') {
            depth += 1;
        } else if (ch == '(' || ch == '[' || ch == '{') {
            if (depth == 0) {
                if (ch != '(') {
                    return std::json::value::NULL;
                }
                open = i;
            }
            depth -= 1;
        } else if (ch == ',' && depth == 0) {
            commas += 1.0;
        } else if (ch == ';') {
            return std::json::value::NULL;
        } else if (ch == '"') {
            // back past the string
            while (i > 0 && !(text[i - 1] == '"' && (i < 2 || text[i - 2] != '\\'))) {
                i -= 1;
            }
            if (i > 0) {
                i -= 1;
            }
        }
    }
    val o = open ?? return std::json::value::NULL;
    var k = o;
    while (k > 0 && (is_word_byte(text[k - 1]) || text[k - 1] == ':')) {
        k -= 1;
    }
    val method = k > 0 && text[k - 1] == '.';
    var recv: lsp_local* = null;
    if (method) {
        commas += 1.0; // the receiver is `this`
        var r = k - 1;
        while (r > 0 && is_word_byte(text[r - 1])) {
            r -= 1;
        }
        recv = c.lsp_local_named(doc.file, text[r..k - 1], o);
    }
    var sigs = std::json::array();
    for (d) in c.lsp_callees(text[k..o], method).items() {
        if (recv) {
            val rt = c.t.ref_inner(recv->ty) ?? recv->ty;
            if (!c.takes_this(d, rt)) {
                continue;
            }
        }
        val label = c.lsp_decl_text(d);
        if (label.len() > 0) {
            var sig = std::json::object();
            sig.set("label", std::json::string(label.as_str()));
            sig.set("parameters", param_labels(label.as_str()));
            sigs.add(move sig);
        }
    }
    if (sigs.len() == 0) {
        return std::json::value::NULL;
    }
    var h = std::json::object();
    h.set("signatures", move sigs);
    h.set("activeSignature", std::json::number(0.0));
    h.set("activeParameter", std::json::number(commas));
    return h;
}

// a declaration's parameters, as ParameterInformation labels: the text between its first ( and
// the matching ), split at the commas at that level
fn param_labels(label: str) -> std::json::value {
    var out = std::json::array();
    var i: usize = 0;
    while (i < label.len && label[i] != '(') {
        i += 1;
    }
    var depth = 0;
    var start = i + 1;
    var j = i + 1;
    while (j < label.len) {
        val ch = label[j];
        if (ch == '(' || ch == '[' || ch == '{' || (ch == '<')) {
            depth += 1;
        } else if (ch == ']' || ch == '}' || (ch == '>' && label[j - 1] != '-')) {
            depth -= 1;
        } else if (ch == ')') {
            if (depth == 0) {
                break;
            }
            depth -= 1;
        } else if (ch == ',' && depth == 0) {
            add_param(&out, label[start..j]);
            start = j + 1;
        }
        j += 1;
    }
    if (j > start) {
        add_param(&out, label[start..j]);
    }
    return out;
}

fn add_param(out: std::json::value&, text: str) -> void {
    var a: usize = 0;
    var b = text.len;
    while (a < b && is_space(text[a])) {
        a += 1;
    }
    while (b > a && is_space(text[b - 1])) {
        b -= 1;
    }
    if (b > a) {
        var p = std::json::object();
        p.set("label", std::json::string(text[a..b]));
        out.add(move p);
    }
}
