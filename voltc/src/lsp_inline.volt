// What the language server shows inline (lsp.volt is the server): semantic tokens (what each name
// is, so themes color types, generic parameters, traits, namespaces, methods, parameters, vals and
// enum variants by meaning), inlay hints, code lenses, document highlights, rename, folding ranges
// and quick fixes. Everything comes from what the checker recorded while checking the document
// (lsp_refs, lsp_locals), its AST and its tokens.

// ---------- semantic tokens ----------

// token types, in the legend's order (lsp_token_legend)
val LK_NAMESPACE: u8 = 0;
val LK_TYPE: u8 = 1;
val LK_STRUCT: u8 = 2;
val LK_ENUM: u8 = 3;
val LK_INTERFACE: u8 = 4; // a trait
val LK_TYPE_PARAM: u8 = 5;
val LK_PARAMETER: u8 = 6;
val LK_VARIABLE: u8 = 7;
val LK_PROPERTY: u8 = 8; // a field
val LK_ENUM_MEMBER: u8 = 9;
val LK_FUNCTION: u8 = 10;
val LK_METHOD: u8 = 11; // a fn that takes this
val LK_MACRO: u8 = 12;  // an @builtin

// token modifiers, as bits in the legend's order
val LM_DECLARATION: u32 = 1;
val LM_READONLY: u32 = 2;       // a val, a parameter without var
val LM_DEFAULT_LIBRARY: u32 = 4; // declared in std

fn lsp_token_legend() -> std::json::value {
    val type_names: str[13] = { "namespace", "type", "struct", "enum", "interface", "typeParameter", "parameter", "variable", "property", "enumMember", "function", "method", "macro" };
    val mod_names: str[3] = { "declaration", "readonly", "defaultLibrary" };
    var types = std::json::array();
    for (t) in type_names {
        types.add(std::json::string(t));
    }
    var mods = std::json::array();
    for (m) in mod_names {
        mods.add(std::json::string(m));
    }
    var l = std::json::object();
    l.set("tokenTypes", move types);
    l.set("tokenModifiers", move mods);
    return l;
}

fn local_kind(l: lsp_local&) -> u8 {
    if (l.param) {
        return LK_PARAMETER;
    }
    return LK_VARIABLE;
}

fn local_mods(l: lsp_local&) -> u32 {
    if (l.mutable) {
        return 0;
    }
    return LM_READONLY;
}

// variant idx of enum eid, named in span (`.VALUE`, `shape::VALUE(..)`, a pattern)
attach fn lsp_variant_use(this: checker&, eid: u32, idx: usize, span: span) -> void {
    val info = this.ei(eid);
    val name = *info.names.at(idx);
    val at = this.lsp_word(span, name, false) ?? return;
    var def = at;
    match (this.item_of(info.decl).kind) {
        .ENUM(e&) => {
            for (v&) in e.variants.items() {
                if (v.name == name) {
                    def = this.name_span(v.span, name);
                }
            }
        },
        default => {},
    }
    put(&this.lsp_refs, { at: at, def: def, label: fmt2("{}::{}", S(info.name), S(name)), kind: LK_ENUM_MEMBER });
}

// a generic type parameter, used in span (in this instance it's t)
attach fn lsp_tparam_use(this: checker&, name: str, span: span, t: u32) -> void {
    val at = this.lsp_word(span, name, false) ?? return;
    put(&this.lsp_refs, { at: at, def: at, label: fmt2("{} = {}", S(name), this.ty_name(t)), kind: LK_TYPE_PARAM });
}

// a namespace, written in span as a path's segment
attach fn lsp_ns_use(this: checker&, name: str, span: span) -> void {
    val at = this.lsp_word(span, name, false) ?? return;
    put(&this.lsp_refs, { at: at, def: at, label: fmt("namespace {}", S(name)), kind: LK_NAMESPACE });
}

// one token: where, what it is, its modifiers
struct sem_tok {
    lo: u32;
    hi: u32;
    kind: u8;
    mods: u32;
}

fn add_tok(out: std::vec<sem_tok>&, at: span?, kind: u8, mods: u32) -> void {
    if (at) {
        put(out, { lo: at.lo, hi: at.hi, kind: kind, mods: mods });
    }
}

// the name declared by a declaration that starts with keyword kw (`fn`, `struct`, ...) in s
fn decl_name(text: str, s: span, kw: str, name: str) -> span? {
    var from = s;
    val k = find_word(text, s, kw, false);
    if (k) {
        from.lo = k.hi;
    }
    return find_word(text, from, name, false);
}

// the declarations in items: their names, fields, variants, parameters and generic parameters, and
// what use paths name
attach fn decl_tokens(this: checker&, text: str, items: std::vec<item>&, in_attach: bool, out: std::vec<sem_tok>&) -> void {
    for (it&) in items.items() {
        for (g&) in it.generics.items() {
            add_tok(out, find_word(text, g.span, g.name, false), LK_TYPE_PARAM, LM_DECLARATION);
        }
        match (it.kind) {
            .FN(f&) => {
                var kind = LK_FUNCTION;
                for (p&) in f.params.items() {
                    if (p.name == "this") {
                        kind = LK_METHOD;
                    } else if (!p.is_static) {
                        var mods = LM_DECLARATION;
                        if (!p.mutable) {
                            mods = mods | LM_READONLY;
                        }
                        add_tok(out, find_word(text, p.span, p.name, false), LK_PARAMETER, mods);
                    }
                }
                if (in_attach) {
                    kind = LK_METHOD;
                }
                add_tok(out, decl_name(text, it.span, "fn", f.name), kind, LM_DECLARATION);
            },
            .STRUCT(s&) => {
                add_tok(out, decl_name(text, it.span, "struct", s.name), LK_STRUCT, LM_DECLARATION);
                for (f&) in s.fields.items() {
                    add_tok(out, find_word(text, f.span, f.name, false), LK_PROPERTY, LM_DECLARATION);
                }
            },
            .ENUM(e&) => {
                var kw = "enum";
                if (e.is_error) {
                    kw = "error";
                }
                add_tok(out, decl_name(text, it.span, kw, e.name), LK_ENUM, LM_DECLARATION);
                for (v&) in e.variants.items() {
                    add_tok(out, find_word(text, v.span, v.name, false), LK_ENUM_MEMBER, LM_DECLARATION);
                }
            },
            .TRAIT(n, fs&) => {
                add_tok(out, decl_name(text, it.span, "trait", n), LK_INTERFACE, LM_DECLARATION);
                this.decl_tokens(text, fs, true, out);
            },
            .ATTACH(a, b, fs&) => { this.decl_tokens(text, fs, true, out); },
            .NAMESPACE(path&, xs&) => {
                // a package's files are wrapped in a namespace that isn't written: only written names
                var from = it.span;
                val k = find_word(text, it.span, "namespace", false);
                if (k) {
                    from.lo = k.hi;
                    for (n&) in path.items() {
                        val w = find_word(text, from, *n, false);
                        add_tok(out, w, LK_NAMESPACE, LM_DECLARATION);
                        if (w) {
                            from.lo = w.hi;
                        }
                    }
                }
                this.decl_tokens(text, xs, false, out);
            },
            .USE(p&) => {
                // its namespaces, and what its last name is
                var path = S("");
                var from = p.span;
                for (i) in 0..p.segs.len {
                    val seg = p.segs.at(i).name;
                    if (i > 0) {
                        path.append("::");
                    }
                    path.append(seg);
                    val w = find_word(text, from, seg, false);
                    if (w) {
                        from.lo = w.hi;
                        var kind = LK_NAMESPACE;
                        if (i + 1 == p.segs.len) {
                            match (this.lsp_find(path.as_str()) ?? found::NS(0)) {
                                .DECLS(l) => { kind = this.decl_kind(*this.list(l).at(0)); },
                                default => {},
                            }
                        }
                        add_tok(out, w, kind, 0);
                    }
                }
            },
            .GLOBAL(l&) => {
                match (l.pat.kind) {
                    .BIND(n) => {
                        var mods = LM_DECLARATION;
                        if (!l.mutable) {
                            mods = mods | LM_READONLY;
                        }
                        add_tok(out, find_word(text, l.span, n, false), LK_VARIABLE, mods);
                    },
                    default => {},
                }
            },
            .ALIAS(n, t&) => { add_tok(out, find_word(text, it.span, n, false), LK_TYPE, LM_DECLARATION); },
            default => {},
        }
    }
}

// what kind of name declaration d is
attach fn decl_kind(this: checker&, d: u32) -> u8 {
    match (this.item_of(d).kind) {
        .STRUCT(s) => { return LK_STRUCT; },
        .ENUM(e) => { return LK_ENUM; },
        .TRAIT(n, fs) => { return LK_INTERFACE; },
        .GLOBAL(l) => { return LK_VARIABLE; },
        .ALIAS(n, t) => { return LK_TYPE; },
        default => { return LK_FUNCTION; },
    }
}

// the document a request names, when its last check is of its current text: what the checker
// recorded is where it says. Null when the text has changed since (it doesn't parse yet)
attach fn fresh_doc(this: lsp_server&, params: std::json::value&) -> lsp_doc* {
    val doc = this.checked_doc(params) ?? return null;
    if (doc.chk.value.files.at(@cast<usize>(doc.file)).text != doc.text.as_str()) {
        return null;
    }
    return doc;
}

// the answer when the document isn't fresh: none while it has never been checked; ContentModified
// when its check is of older text (the editor keeps what it has, adjusted to the edits)
attach fn not_fresh(this: lsp_server&, params: std::json::value&, none: std::json::value) -> std::json::value {
    if (this.checked_doc(params) == null) {
        return none;
    }
    return lsp_error(-32801.0, S("the document changed since it was last checked"));
}

// semanticTokens/full: every name in the document, by what it is
attach fn semantic_tokens(this: lsp_server&, params: std::json::value&) -> std::json::value {
    var r = std::json::object();
    r.set("data", std::json::array());
    val doc = this.fresh_doc(params) ?? return this.not_fresh(params, move r);
    val c = &*doc.chk.value;
    val src = &*doc.src.value;
    val text = c.files.at(@cast<usize>(doc.file)).text;
    var is_std: std::vec<bool> = {};
    for (i) in 0..c.files.len {
        put(&is_std, false);
    }
    for (u&) in src.units.items() {
        if (u.pkg != null && (u.pkg ?? "") == "std") {
            *is_std.at(@cast<usize>(u.file)) = true;
        }
    }
    var toks: std::vec<sem_tok> = {};
    // what the checker resolved (uses), then what's declared here, then the @builtins
    for (rf&) in c.lsp_refs.items() {
        if (rf.at.file == doc.file && rf.kind != 255) {
            var mods = rf.mods;
            if (@cast<usize>(rf.def.file) < is_std.len && *is_std.at(@cast<usize>(rf.def.file))) {
                mods = mods | LM_DEFAULT_LIBRARY;
            }
            put(&toks, { lo: rf.at.lo, hi: rf.at.hi, kind: rf.kind, mods: mods });
        }
    }
    for (l&) in c.lsp_locals.items() {
        // this is a keyword to the grammar, and stays one
        if (l.def.file == doc.file && l.def.hi > l.def.lo && l.name != "this") {
            put(&toks, { lo: l.def.lo, hi: l.def.hi, kind: local_kind(l), mods: local_mods(l) | LM_DECLARATION });
        }
    }
    c.decl_tokens(text, src.asts.at(@cast<usize>(doc.file)), false, &toks);
    for (t&) in src.toks.at(@cast<usize>(doc.file)).items() {
        match (t.tok) {
            .BUILTIN(n) => { put(&toks, { lo: t.span.lo, hi: t.span.hi, kind: LK_MACRO, mods: 0 }); },
            default => {},
        }
    }
    toks.items().sort_by(|| (a: sem_tok&, b: sem_tok&) -> i32 {
        if (a.lo < b.lo) {
            return -1;
        }
        if (a.lo > b.lo) {
            return 1;
        }
        return 0;
    });
    r.set("data", encode_tokens(text, &toks));
    return r;
}

// LSP's relative encoding: line and start (UTF-16) from the token before, length, type, modifiers.
// Overlapping tokens keep the first (a use the checker resolved wins over a guess)
fn encode_tokens(text: str, toks: std::vec<sem_tok>&) -> std::json::value {
    var data = std::json::array();
    var pos: usize = 0;
    var line: u32 = 0;
    var col: u32 = 0;
    var prev_line: u32 = 0;
    var prev_col: u32 = 0;
    var end: u32 = 0;
    for (t&) in toks.items() {
        if (t.lo < end || @cast<usize>(t.hi) > text.len) {
            continue;
        }
        while (pos < @cast<usize>(t.lo)) {
            if (text[pos] == '\n') {
                line += 1;
                col = 0;
            } else {
                col += @cast<u32>(utf16_units(text[pos]));
            }
            pos += 1;
        }
        var len: u32 = 0;
        var newline = false;
        for (i) in @cast<usize>(t.lo)..@cast<usize>(t.hi) {
            if (text[i] == '\n') {
                newline = true;
            }
            len += @cast<u32>(utf16_units(text[i]));
        }
        if (newline || len == 0) {
            continue; // a token is on one line
        }
        var dc = col;
        if (line == prev_line) {
            dc = col - prev_col;
        }
        data.add(std::json::number(@cast<f64>(line - prev_line)));
        data.add(std::json::number(@cast<f64>(dc)));
        data.add(std::json::number(@cast<f64>(len)));
        data.add(std::json::number(@cast<f64>(t.kind)));
        data.add(std::json::number(@cast<f64>(t.mods)));
        prev_line = line;
        prev_col = col;
        end = t.hi;
    }
    return data;
}

// ---------- inlay hints ----------

// an argument of a call, and the parameter it's for
struct lsp_arg {
    at: span;
    name: str;
}

// what initialize says about inlay hints: { "inlayHints": { "types": bool, "parameters": bool } }
attach fn read_options(this: lsp_server&, o: std::json::value&) -> void {
    val h = o.get("inlayHints");
    val t = h.get("types").as_bool();
    if (t != null) {
        this.hint_types = t ?? true;
    }
    val p = h.get("parameters").as_bool();
    if (p != null) {
        this.hint_params = p ?? true;
    }
    val b = h.get("closingBraces").as_bool();
    if (b != null) {
        this.hint_braces = b ?? true;
    }
}

// a type as a hint shows it: std's default allocator argument left out
fn hint_type(c: checker&, t: u32) -> std::string {
    var s = c.ty_name(t);
    // ponytail: text replacement; a short-name mode in ty_name if more defaults need hiding
    s = replace_all(s.as_str(), ", std::mem::default_allocator>", ">");
    s = replace_all(s.as_str(), "<std::mem::default_allocator>", "");
    return s;
}

// whether a type is written right after a declared name (`x: i32`)
fn typed_after(text: str, at: usize) -> bool {
    var i = at;
    while (i < text.len && (text[i] == ' ' || text[i] == '\t')) {
        i += 1;
    }
    return i < text.len && text[i] == ':';
}

fn hint(text: str, at: usize, label: std::string, kind: f64, left: bool) -> std::json::value {
    var h = std::json::object();
    h.set("position", lsp_pos(text, at));
    h.set("label", std::json::string(label.as_str()));
    h.set("kind", std::json::number(kind));
    if (left) {
        h.set("paddingLeft", std::json::value::BOOL(true));
    } else {
        h.set("paddingRight", std::json::value::BOOL(true));
    }
    return h;
}

// the end of each declaration whose block spans CLOSING_LINES lines or more: `fn main` after its }
val CLOSING_LINES: usize = 25;

fn closing_hints(text: str, items: std::vec<item>&, out: std::json::value&) -> void {
    for (it&) in items.items() {
        var label: std::string = {};
        var kids: std::vec<item>* = null;
        match (it.kind) {
            .FN(f&) => { label = fmt("fn {}", S(f.name)); },
            .STRUCT(s&) => { label = fmt("struct {}", S(s.name)); },
            .ENUM(e&) => { label = fmt("enum {}", S(e.name)); },
            .TRAIT(n, fs&) => { label = fmt("trait {}", S(n)); },
            .ATTACH(a&, b&, fs&) => {
                label = S("attach");
                if (a.span.hi > a.span.lo) {
                    label = fmt("attach {}", S(text[@cast<usize>(a.span.lo)..@cast<usize>(a.span.hi)]));
                }
                label.append(fmt(" -> {}", S(text[@cast<usize>(b.span.lo)..@cast<usize>(b.span.hi)])).as_str());
                kids = fs;
            },
            .NAMESPACE(path&, xs&) => {
                // a package's files are wrapped in one that isn't written
                if (find_word(text, it.span, "namespace", false) != null && path.len > 0) {
                    label = fmt("namespace {}", S(*path.at(path.len - 1)));
                }
                kids = xs;
            },
            default => {},
        }
        val hi = @cast<usize>(it.span.hi);
        if (label.len() > 0 && hi <= text.len && hi > 0 && text[hi - 1] == '}') {
            var lines: usize = 0;
            for (i) in @cast<usize>(it.span.lo)..hi {
                if (text[i] == '\n') {
                    lines += 1;
                }
            }
            if (lines + 1 >= CLOSING_LINES) {
                var h = std::json::object();
                h.set("position", lsp_pos(text, hi));
                h.set("label", std::json::string(label.as_str()));
                h.set("paddingLeft", std::json::value::BOOL(true));
                out.add(move h);
            }
        }
        if (kids) {
            closing_hints(text, kids, out);
        }
    }
}

// inlayHint: a local's type where none is written (closure parameters included; not in a generic
// fn's body, where it's one instance's), the parameter each argument is for (unless the argument
// already says it), and what a long block closes
attach fn inlay_hints(this: lsp_server&, params: std::json::value&) -> std::json::value {
    var out = std::json::array();
    val doc = this.fresh_doc(params) ?? return this.not_fresh(params, move out);
    val c = &*doc.chk.value;
    val text = c.files.at(@cast<usize>(doc.file)).text;
    if (this.hint_types) {
        // this file's locals: each declaration once (a type per place; two types: no hint)
        var types: std::map<u32, u32> = {};
        var order: std::vec<usize> = {};
        for (i) in 0..c.lsp_locals.len {
            val l = c.lsp_locals.at(i);
            if (l.def.file != doc.file || l.generic || l.name == "this" || l.name == "_" || typed_after(text, @cast<usize>(l.def.hi))) {
                continue;
            }
            val have = types.get(l.def.lo);
            if (have) {
                if (*have != l.ty) {
                    *have = NO_HINT;
                }
            } else {
                types.put(l.def.lo, l.ty);
                put(&order, i);
            }
        }
        for (i&) in order.items() {
            val l = c.lsp_locals.at(*i);
            val t = *(types.get(l.def.lo) ?? continue);
            if (t != NO_HINT) {
                var label = S(": ");
                label.append(hint_type(c, t).as_str());
                out.add(hint(text, @cast<usize>(l.def.hi), move label, 1.0, false));
            }
        }
    }
    if (this.hint_params) {
        var seen: std::map<u32, bool> = {};
        for (a&) in c.lsp_args.items() {
            // one-letter names (a, b, x) say nothing the call doesn't
            if (a.at.file != doc.file || a.name.len < 2 || seen.contains(a.at.lo)) {
                continue;
            }
            seen.put(a.at.lo, true);
            // `f(name)`, `f(x.name)`, `f(&name)`: the argument says it already
            val arg = text[@cast<usize>(a.at.lo)..@cast<usize>(a.at.hi)];
            val ends = arg.len >= a.name.len && arg[arg.len - a.name.len..] == a.name && (arg.len == a.name.len || !is_word_byte(arg[arg.len - a.name.len - 1]));
            if (ends) {
                continue;
            }
            var label = S(a.name);
            label.push(':');
            out.add(hint(text, @cast<usize>(a.at.lo), move label, 2.0, true));
        }
    }
    if (this.hint_braces) {
        closing_hints(text, doc.src.value.asts.at(@cast<usize>(doc.file)), &out);
    }
    return out;
}

val NO_HINT: u32 = 4294967295;

// ---------- highlights and rename ----------

// what's declared where offset at is: a use's declaration, or a local declared there
fn def_at(c: checker&, file: u32, at: usize) -> span? {
    val r = ref_at(c, file, at);
    if (r) {
        return r->def;
    }
    for (l&) in c.lsp_locals.items() {
        if (contains(l.def, file, at)) {
            return l.def;
        }
    }
    return null;
}

// where def is used (each place once: a generic fn's instances record theirs again)
fn uses_of(c: checker&, def: span) -> std::vec<span> {
    var out: std::vec<span> = {};
    for (x&) in c.lsp_refs.items() {
        if (same_span(x.def, def) && !same_span(x.at, def)) {
            var dup = false;
            for (s&) in out.items() {
                if (same_span(*s, x.at)) {
                    dup = true;
                }
            }
            if (!dup) {
                put(&out, x.at);
            }
        }
    }
    return out;
}

// documentHighlight: the name under the cursor, its declaration and uses in this document
attach fn highlights(this: lsp_server&, params: std::json::value&) -> std::json::value {
    var out = std::json::array();
    val doc = this.fresh_doc(params) ?? return out;
    val c = &*doc.chk.value;
    val def = def_at(c, doc.file, doc_offset(doc, params)) ?? return out;
    val text = c.files.at(@cast<usize>(doc.file)).text;
    var spans = uses_of(c, def);
    put(&spans, def);
    for (s&) in spans.items() {
        if (s.file == doc.file) {
            var h = std::json::object();
            h.set("range", lsp_range(text, *s));
            out.add(move h);
        }
    }
    return out;
}

// whether a name can be renamed: it's declared in this program (not std, not made up: a namespace
// or a generic parameter's use is its own declaration)
attach fn renamable(this: lsp_server&, doc: lsp_doc&, c: checker&, at: usize) -> span? {
    val def = def_at(c, doc.file, at) ?? return null;
    val r = ref_at(c, doc.file, at);
    if (r) {
        if (r->kind == LK_NAMESPACE || r->kind == LK_TYPE_PARAM) {
            return null;
        }
    }
    for (u&) in doc.src.value.units.items() {
        if (u.file == def.file && u.pkg != null && (u.pkg ?? "") == "std") {
            return null;
        }
    }
    return def;
}

// prepareRename: the name under the cursor, when it can be renamed
attach fn prepare_rename(this: lsp_server&, params: std::json::value&) -> std::json::value {
    val doc = this.fresh_doc(params) ?? return std::json::value::NULL;
    val c = &*doc.chk.value;
    val at = doc_offset(doc, params);
    this.renamable(doc, c, at) ?? return std::json::value::NULL;
    // the word at the cursor
    val text = c.files.at(@cast<usize>(doc.file)).text;
    var lo = at;
    while (lo > 0 && is_word_byte(text[lo - 1])) {
        lo -= 1;
    }
    var hi = at;
    while (hi < text.len && is_word_byte(text[hi])) {
        hi += 1;
    }
    var r = std::json::object();
    r.set("range", lsp_range(text, { file: doc.file, lo: @cast<u32>(lo), hi: @cast<u32>(hi) }));
    r.set("placeholder", std::json::string(text[lo..hi]));
    return r;
}

// rename: the declaration and every use, in every file of the check
attach fn rename(this: lsp_server&, params: std::json::value&) -> std::json::value {
    // edits from an older check would land in the wrong places
    val doc = this.fresh_doc(params) ?? return lsp_error(-32602.0, S("the file has errors that stop it parsing: fix them, then rename"));
    val c = &*doc.chk.value;
    val name = params.get("newName").as_str() ?? "";
    var ok = name.len > 0 && !(name[0] >= '0' && name[0] <= '9') && !is_keyword(name);
    for (b) in name {
        ok = ok && is_word_byte(b);
    }
    if (!ok) {
        return lsp_error(-32602.0, fmt("'{}' isn't a name", S(name)));
    }
    val def = this.renamable(doc, c, doc_offset(doc, params)) ?? return lsp_error(-32602.0, S("this can't be renamed here"));
    var spans = uses_of(c, def);
    put(&spans, def);
    // per file: its URI and edits
    var changes = std::json::object();
    for (f) in 0..c.files.len {
        var edits = std::json::array();
        val text = c.files.at(f).text;
        for (s&) in spans.items() {
            if (@cast<usize>(s.file) == f) {
                var e = std::json::object();
                e.set("range", lsp_range(text, *s));
                e.set("newText", std::json::string(name));
                edits.add(move e);
            }
        }
        if (edits.len() > 0) {
            var uri = path_uri(c.files.at(f).name);
            if (@cast<u32>(f) == doc.file) {
                uri = copy doc.uri;
            }
            changes.set(uri.as_str(), move edits);
        }
    }
    var r = std::json::object();
    r.set("changes", move changes);
    return r;
}

// an error response's body (inline_request sends it as the error)
fn lsp_error(code: f64, msg: std::string) -> std::json::value {
    var e = std::json::object();
    e.set("code", std::json::number(code));
    e.set("message", std::json::string(msg.as_str()));
    var r = std::json::object();
    r.set("__error", move e);
    return r;
}

// ---------- folding ----------

// where each line starts
fn line_starts(text: str) -> std::vec<usize> {
    var out: std::vec<usize> = {};
    put(&out, 0);
    for (i) in 0..text.len {
        if (text[i] == '\n') {
            put(&out, i + 1);
        }
    }
    return out;
}

// the line offset at is on
fn line_at(starts: std::vec<usize>&, at: usize) -> usize {
    var lo: usize = 0;
    var hi = starts.len;
    while (hi - lo > 1) {
        val mid = (lo + hi) / 2;
        if (*starts.at(mid) <= at) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn fold(out: std::json::value&, start: usize, end: usize, kind: str?) -> void {
    var f = std::json::object();
    f.set("startLine", std::json::number(@cast<f64>(start)));
    f.set("endLine", std::json::number(@cast<f64>(end)));
    if (kind) {
        f.set("kind", std::json::string(kind));
    }
    out.add(move f);
}

// foldingRange: braces that span lines (from the current text, while it doesn't parse too), runs
// of comment lines and of use lines
attach fn folding(this: lsp_server&, params: std::json::value&) -> std::json::value {
    var out = std::json::array();
    val doc = this.find_doc(params) ?? return out;
    val text = doc.text.as_str();
    val starts = line_starts(text);
    val toks = lex(text, 0) catch |e| {
        return out;
    };
    var open: std::vec<usize> = {};
    for (t&) in toks.items() {
        match (t.tok) {
            .PUNCT(p) => {
                if (p == "{") {
                    put(&open, line_at(&starts, @cast<usize>(t.span.lo)));
                } else if (p == "}" && open.len > 0) {
                    val from = open.pop() ?? 0;
                    val to = line_at(&starts, @cast<usize>(t.span.lo));
                    if (to > from + 1) {
                        fold(&out, from, to - 1, null); // the closing brace stays in view
                    }
                }
            },
            default => {},
        }
    }
    // runs of lines that start with // or use
    var run_kind: str? = null;
    var run_start: usize = 0;
    for (l) in 0..starts.len + 1 {
        var kind: str? = null;
        if (l < starts.len) {
            var i = *starts.at(l);
            while (i < text.len && (text[i] == ' ' || text[i] == '\t')) {
                i += 1;
            }
            if (i + 1 < text.len && text[i] == '/' && text[i + 1] == '/') {
                kind = "comment";
            } else if (i + 4 < text.len && text[i..i + 4] == "use " ) {
                kind = "imports";
            }
        }
        val same = kind != null && run_kind != null && (kind ?? "") == (run_kind ?? "");
        if (!same) {
            if (run_kind != null && l - run_start > 1) {
                fold(&out, run_start, l - 1, run_kind);
            }
            run_kind = kind;
            run_start = l;
        }
    }
    return out;
}

// ---------- types: what's attached to them ----------

// the text of span s, its whitespace runs as single spaces
attach fn span_text(this: checker&, s: span) -> std::string {
    var out: std::string = {};
    val text = this.files.at(@cast<usize>(s.file)).text;
    var space = false;
    for (i) in @cast<usize>(s.lo)..@cast<usize>(s.hi) {
        if (i >= text.len) {
            break;
        }
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
    return out;
}

// the type declaration d made (its first instance, for a generic one); null when none was made
attach fn type_of_decl(this: checker&, d: u32) -> u32? {
    for (i) in 0..this.structs.len {
        val s = this.si(@cast<u32>(i));
        if (s.decl == d || s.family == d) {
            return this.t.intern(tyk::STRUCT(@cast<u32>(i)));
        }
    }
    for (i) in 0..this.enums.len {
        val e = this.ei(@cast<u32>(i));
        if (e.decl == d || e.family == d) {
            return this.t.intern(tyk::ENUM(@cast<u32>(i)));
        }
    }
    return null;
}

// a fn attached to a type, and the trait it's attached for (as its attach block writes it, generic
// arguments and all); "" for a plain attach fn
struct attached_fn {
    decl: u32;
    group: std::string;
}

// whether attached fn d takes any type (<T> attach fn eq(this: T&...), std's): it isn't a type's own
attach fn catch_all(this: checker&, d: u32) -> bool {
    val f = this.fn_decl_of(d) ?? return false;
    if (f.params.len == 0) {
        return false;
    }
    var t = &f.params.at(0).ty;
    if (*t == null) {
        return false;
    }
    var k = &t.value.kind;
    match (*k) {
        .REF(inner) => {
            match (inner.kind) {
                .PATH(p&) => {
                    if (p.is_single()) {
                        for (g&) in this.item_of(d).generics.items() {
                            if (g.name == p.segs.at(0).name) {
                                return true;
                            }
                        }
                    }
                },
                default => {},
            }
        },
        default => {},
    }
    return false;
}

// the fns attached to type t (a trait's first, then plain ones; each group by name)
attach fn attached_to(this: checker&, t: u32) -> std::vec<attached_fn> {
    var out: std::vec<attached_fn> = {};
    var names: std::vec<str> = {};
    map_keys(&this.attached, &names);
    for (n) in names.items() {
        for (d) in this.named(&this.attached, n).items() {
            if (this.catch_all(d) || !this.takes_this(d, t)) {
                continue;
            }
            var group: std::string = {};
            val parent = this.dl(d).parent;
            if (parent) {
                match (this.item_of(parent).kind) {
                    .ATTACH(tr&, target&, fs) => { group = this.span_text(tr.span); },
                    default => {},
                }
            }
            put(&out, { decl: d, group: move group });
        }
    }
    out.items().sort_by(|| (a: attached_fn&, b: attached_fn&) -> i32 {
        if (a.group.len() > 0 && b.group.len() == 0) {
            return -1;
        }
        if (a.group.len() == 0 && b.group.len() > 0) {
            return 1;
        }
        val g = a.group.as_str().cmp(b.group.as_str());
        if (g != 0) {
            return g;
        }
        return 0;
    });
    return out;
}

// the attach blocks that attach trait d (their target types, as written)
attach fn attachers(this: checker&, d: u32) -> std::vec<u32> {
    var out: std::vec<u32> = {};
    for (b&) in this.attach_blocks.items() {
        match (this.item_of(*b).kind) {
            .ATTACH(tr&, target&, fs) => {
                val bt = this.block_trait(*b);
                if (bt != null && (bt ?? return out).decl == d) {
                    put(&out, *b);
                }
            },
            default => {},
        }
    }
    return out;
}

// what hover shows for a type: its declaration (fields, variants) and every fn attached to it,
// grouped by the trait it's attached for; for a trait, its fns and the types that attach it
attach fn type_hover(this: checker&, d: u32) -> std::string {
    var out: std::string = {};
    val it = this.item_of(d);
    match (it.kind) {
        .STRUCT(s&) => {
            out.append(fmt("struct {} {{", S(s.name)).as_str());
            for (f&) in s.fields.items() {
                out.append(fmt2("\n    {}: {};", S(f.name), this.span_text(f.ty.span)).as_str());
            }
            out.append("\n}");
        },
        .ENUM(e&) => {
            var kw = "enum";
            if (e.is_error) {
                kw = "error";
            }
            out.append(fmt2("{} {} {{", S(kw), S(e.name)).as_str());
            for (v&) in e.variants.items() {
                out.append("\n    ");
                out.append(v.name);
                if (v.payload) {
                    out.append(fmt(": {}", this.span_text(v.payload.span)).as_str());
                }
                out.push(',');
            }
            out.append("\n}");
        },
        .TRAIT(n, fs&) => {
            out.append(fmt("trait {} {{", S(n)).as_str());
            for (f&) in fs.items() {
                var sig = this.span_text(f.span);
                if (sig.len() > 0 && sig.as_str()[sig.len() - 1] == ';') {
                    sig.bytes.pop();
                }
                out.append(fmt("\n    {};", move sig).as_str());
            }
            out.append("\n}");
            val bs = this.attachers(d);
            if (bs.len > 0) {
                out.append("\n// attached by");
                for (b&) in bs.items() {
                    match (this.item_of(*b).kind) {
                        .ATTACH(tr&, target&, x) => { out.append(fmt("\n{}", this.span_text(target.span)).as_str()); },
                        default => {},
                    }
                }
            }
            return out;
        },
        default => { return this.lsp_type_label(d, ""); },
    }
    val t = this.type_of_decl(d) ?? return out;
    var group: std::string = {};
    var started = false;
    for (a&) in this.attached_to(t).items() {
        if (!started || group.as_str() != a.group.as_str()) {
            started = true;
            if (a.group.len() > 0) {
                out.append(fmt("\n// {}", copy a.group).as_str());
            } else {
                out.append("\n// attached");
            }
            group = copy a.group;
        }
        out.push('\n');
        out.append(this.lsp_decl_text(a.decl).as_str());
    }
    return out;
}

// ---------- code lenses ----------

// the declaration whose item is it (by where it is)
fn decl_at(c: checker&, s: span) -> u32? {
    for (i) in 0..c.decls.len {
        if (same_span(c.decls.at(i).item.span, s)) {
            return @cast<u32>(i);
        }
    }
    return null;
}

// a lens at name: title, and the command that shows locs (volt.showLocations: the extension's)
fn lens(text: str, uri: str, name: span, title: std::string, locs: std::json::value) -> std::json::value {
    var args = std::json::array();
    args.add(std::json::string(uri));
    args.add(lsp_pos(text, @cast<usize>(name.lo)));
    args.add(move locs);
    var cmd = std::json::object();
    cmd.set("title", std::json::string(title.as_str()));
    cmd.set("command", std::json::string("volt.showLocations"));
    cmd.set("arguments", move args);
    var l = std::json::object();
    l.set("range", lsp_range(text, name));
    l.set("command", move cmd);
    return l;
}

fn plural(n: usize, one: str, many: str) -> std::string {
    if (n == 1) {
        return fmt("1 {}", S(one));
    }
    return fmt2("{} {}", unum(@cast<u64>(n)), S(many));
}

// the lenses for items: references above fns, what's attached above types (and the traits), the
// types that attach a trait, and Run above main
attach fn lenses(this: lsp_server&, doc: lsp_doc&, c: checker&, items: std::vec<item>&, in_attach: bool, out: std::json::value&) -> void {
    val text = c.files.at(@cast<usize>(doc.file)).text;
    for (it&) in items.items() {
        match (it.kind) {
            .FN(f&) => {
                val name = decl_name(text, it.span, "fn", f.name) ?? continue;
                if (f.name == "main" && !in_attach) {
                    var args = std::json::array();
                    args.add(std::json::string(doc.uri.as_str()));
                    var cmd = std::json::object();
                    cmd.set("title", std::json::string("\u{25b6} Run"));
                    cmd.set("command", std::json::string("volt.run"));
                    cmd.set("arguments", move args);
                    var l = std::json::object();
                    l.set("range", lsp_range(text, name));
                    l.set("command", move cmd);
                    out.add(move l);
                    continue;
                }
                var locs = std::json::array();
                val uses = uses_of(c, name);
                for (u&) in uses.items() {
                    locs.add(lsp_location(doc, c, *u));
                }
                out.add(lens(text, doc.uri.as_str(), name, plural(uses.len, "reference", "references"), move locs));
            },
            .STRUCT(s&) => { this.type_lens(doc, c, it, decl_name(text, it.span, "struct", s.name), out); },
            .ENUM(e&) => {
                var kw = "enum";
                if (e.is_error) {
                    kw = "error";
                }
                this.type_lens(doc, c, it, decl_name(text, it.span, kw, e.name), out);
            },
            .TRAIT(n, fs&) => {
                val name = decl_name(text, it.span, "trait", n) ?? continue;
                val d = decl_at(c, it.span) ?? continue;
                var locs = std::json::array();
                val bs = c.attachers(d);
                for (b&) in bs.items() {
                    locs.add(lsp_location(doc, c, c.item_of(*b).span));
                }
                out.add(lens(text, doc.uri.as_str(), name, plural(bs.len, "type attaches it", "types attach it"), move locs));
            },
            .ATTACH(a, b, fs&) => { this.lenses(doc, c, fs, true, out); },
            .NAMESPACE(p, xs&) => { this.lenses(doc, c, xs, false, out); },
            default => {},
        }
    }
}

// above a type: how many fns are attached to it, and for which traits
attach fn type_lens(this: lsp_server&, doc: lsp_doc&, c: checker&, it: item&, name: span?, out: std::json::value&) -> void {
    val at = name ?? return;
    val d = decl_at(c, it.span) ?? return;
    val t = c.type_of_decl(d) ?? return;
    val text = c.files.at(@cast<usize>(doc.file)).text;
    var locs = std::json::array();
    var traits: std::vec<std::string> = {};
    val fns = c.attached_to(t);
    for (a&) in fns.items() {
        val sp = c.item_of(a.decl).span;
        val f = c.fn_decl_of(a.decl);
        var where_ = sp;
        if (f) {
            where_ = c.name_span(sp, f.name);
        }
        locs.add(lsp_location(doc, c, where_));
        if (a.group.len() > 0) {
            var have = false;
            for (x&) in traits.items() {
                if (x.as_str() == a.group.as_str()) {
                    have = true;
                }
            }
            if (!have) {
                put(&traits, copy a.group);
            }
        }
    }
    var title = plural(fns.len, "attached fn", "attached fns");
    if (traits.len > 0) {
        title.append(" \u{b7} ");
        for (i) in 0..traits.len {
            if (i > 0) {
                title.append(", ");
            }
            title.append(traits.at(i).as_str());
        }
    }
    out.add(lens(text, doc.uri.as_str(), at, move title, move locs));
}

attach fn code_lenses(this: lsp_server&, params: std::json::value&) -> std::json::value {
    var out = std::json::array();
    val doc = this.fresh_doc(params) ?? return this.not_fresh(params, move out);
    val c = &*doc.chk.value;
    this.lenses(doc, c, doc.src.value.asts.at(@cast<usize>(doc.file)), false, &out);
    return out;
}

// ---------- quick fixes ----------

// e, with a quick fix: replace at with text
fn with_fix(e: compile_error, title: std::string, at: span, text: std::string) -> compile_error {
    var r = move e;
    match (r) {
        .AT(d&) => { put(&d.fixes, { title: move title, span: at, text: move text }); },
    }
    return r;
}

// e about local name (named at at), with the fix that declares it var: its val becomes var, or a
// parameter gets var in front (the language server only: it knows where locals are declared)
attach fn var_fix(this: checker&, e: compile_error, name: str, at: span) -> compile_error {
    if (!this.opts.lsp) {
        return e;
    }
    val l = this.lsp_local_named(at.file, name, @cast<usize>(at.lo)) ?? return e;
    val text = this.files.at(@cast<usize>(l.def.file)).text;
    var i = @cast<usize>(l.def.lo);
    while (i > 0 && (text[i - 1] == ' ' || text[i - 1] == '\t')) {
        i -= 1;
    }
    val title = fmt("declare '{}' with var", S(name));
    if (i >= 3 && text[i - 3..i] == "val" && (i == 3 || !is_word_byte(text[i - 4]))) {
        return with_fix(e, title, { file: l.def.file, lo: @cast<u32>(i - 3), hi: @cast<u32>(i) }, S("var"));
    }
    if (l.param) {
        return with_fix(e, title, { file: l.def.file, lo: l.def.lo, hi: l.def.lo }, S("var "));
    }
    return e;
}

// e about statement e0 that computes a value and drops it: `place + 1` gets `+=`, `place == x`
// gets `=` (the operator between the operands)
attach fn op_fix(this: checker&, e: compile_error, e0: expr&) -> compile_error {
    if (!this.opts.lsp) {
        return e;
    }
    match (e0.kind) {
        .BINARY(op, a, b) => {
            val text = this.files.at(@cast<usize>(e0.span.file)).text;
            val sym = binop_text(op);
            var meant = S(sym);
            if (op == binop::EQ) {
                meant = S("=");
            } else {
                meant.push('=');
            }
            var i = @cast<usize>(a.span.hi);
            while (i + sym.len <= @cast<usize>(b.span.lo)) {
                if (text[i..i + sym.len] == sym) {
                    val title = fmt2("change {} to {}", S(sym), copy meant);
                    return with_fix(e, title, { file: e0.span.file, lo: @cast<u32>(i), hi: @cast<u32>(i + sym.len) }, move meant);
                }
                i += 1;
            }
        },
        default => {},
    }
    return e;
}

// a diagnostic's fixes, as the data publishDiagnostics carries (and codeAction gets back)
fn fixes_json(doc: lsp_doc&, d: diag&) -> std::json::value {
    var out = std::json::array();
    if (doc.chk == null) {
        return out;
    }
    val c = &*doc.chk.value;
    for (f&) in d.fixes.items() {
        if (@cast<usize>(f.span.file) >= c.files.len) {
            continue;
        }
        var o = std::json::object();
        o.set("title", std::json::string(f.title.as_str()));
        o.set("newText", std::json::string(f.text.as_str()));
        val loc = lsp_location(doc, c, f.span);
        o.set("uri", copy *loc.get("uri"));
        o.set("range", copy *loc.get("range"));
        out.add(move o);
    }
    return out;
}

// codeAction: the quick fixes the diagnostics in the request carry
attach fn code_actions(this: lsp_server&, params: std::json::value&) -> std::json::value {
    var out = std::json::array();
    // the fixes' places are the last check's: only while the text is still that
    this.fresh_doc(params) ?? return out;
    val ds = params.get("context").get("diagnostics");
    for (i) in 0..ds.len() {
        val d = ds.at(i);
        val fs = d.get("data").get("fixes");
        for (j) in 0..fs.len() {
            val f = fs.at(j);
            var edit = std::json::object();
            edit.set("range", copy *f.get("range"));
            edit.set("newText", copy *f.get("newText"));
            var edits = std::json::array();
            edits.add(move edit);
            var changes = std::json::object();
            changes.set(f.get("uri").as_str() ?? "", move edits);
            var we = std::json::object();
            we.set("changes", move changes);
            var diags = std::json::array();
            diags.add(copy *d);
            var a = std::json::object();
            a.set("title", copy *f.get("title"));
            a.set("kind", std::json::string("quickfix"));
            a.set("diagnostics", move diags);
            a.set("isPreferred", std::json::value::BOOL(true));
            a.set("edit", move we);
            out.add(move a);
        }
    }
    return out;
}

// ---------- the requests ----------

fn lsp_inline_capabilities(caps: std::json::value&) -> void {
    var st = std::json::object();
    st.set("legend", lsp_token_legend());
    st.set("full", std::json::value::BOOL(true));
    caps.set("semanticTokensProvider", move st);
    caps.set("inlayHintProvider", std::json::value::BOOL(true));
    caps.set("documentHighlightProvider", std::json::value::BOOL(true));
    var rn = std::json::object();
    rn.set("prepareProvider", std::json::value::BOOL(true));
    caps.set("renameProvider", move rn);
    caps.set("foldingRangeProvider", std::json::value::BOOL(true));
    caps.set("codeLensProvider", std::json::object());
    var ca = std::json::object();
    var kinds = std::json::array();
    kinds.add(std::json::string("quickfix"));
    ca.set("codeActionKinds", move kinds);
    caps.set("codeActionProvider", move ca);
}

// a result, or the error lsp_error made
fn inline_reply(id: std::json::value&, r: std::json::value) -> void {
    val e = r.get("__error");
    if (e.is_null()) {
        lsp_reply(id, move r);
        return;
    }
    var m = std::json::object();
    m.set("jsonrpc", std::json::string("2.0"));
    m.set("id", lsp_id(id));
    m.set("error", copy *e);
    lsp_send(&m);
}

// answer one of the requests this file serves; false when method isn't one
attach fn inline_request(this: lsp_server&, method: str, id: std::json::value&, params: std::json::value&) -> bool {
    if (method == "textDocument/semanticTokens/full") {
        this.flush();
        inline_reply(id, this.semantic_tokens(params));
        return true;
    }
    if (method == "textDocument/inlayHint") {
        this.flush();
        inline_reply(id, this.inlay_hints(params));
        return true;
    }
    if (method == "textDocument/documentHighlight") {
        this.flush();
        lsp_reply(id, this.highlights(params));
        return true;
    }
    if (method == "textDocument/prepareRename") {
        this.flush();
        lsp_reply(id, this.prepare_rename(params));
        return true;
    }
    if (method == "textDocument/rename") {
        this.flush();
        inline_reply(id, this.rename(params));
        return true;
    }
    if (method == "textDocument/codeLens") {
        this.flush();
        inline_reply(id, this.code_lenses(params));
        return true;
    }
    if (method == "textDocument/codeAction") {
        this.flush();
        lsp_reply(id, this.code_actions(params));
        return true;
    }
    if (method == "textDocument/foldingRange") {
        lsp_reply(id, this.folding(params));
        return true;
    }
    return false;
}
