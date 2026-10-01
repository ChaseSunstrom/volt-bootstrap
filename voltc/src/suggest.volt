// "Did you mean" help for misspelled names: the candidates a name could have meant (locals, generic
// params, names in the enclosing namespaces, a namespace's members, a struct's fields) and the
// closest one by edit distance. A port of bootstrap/check/suggest.rs that picks the same one.
use std::mem;

// edits (insert, delete, replace, swap two neighbours) to turn a into b
fn distance(a: str, b: str) -> usize {
    val w = b.len + 1;
    var d: std::vec<usize> = {};
    for (k) in 0..(a.len + 1) * w {
        put(&d, 0);
    }
    for (i) in 0..a.len + 1 {
        *d.at(i * w) = i;
    }
    for (j) in 0..b.len + 1 {
        *d.at(j) = j;
    }
    for (i) in 1..a.len + 1 {
        for (j) in 1..b.len + 1 {
            var cost: usize = 1;
            if (a[i - 1] == b[j - 1]) {
                cost = 0;
            }
            var v = *d.at((i - 1) * w + j) + 1;
            val ins = *d.at(i * w + j - 1) + 1;
            if (ins < v) {
                v = ins;
            }
            val sub = *d.at((i - 1) * w + j - 1) + cost;
            if (sub < v) {
                v = sub;
            }
            if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
                val swap = *d.at((i - 2) * w + j - 2) + 1;
                if (swap < v) {
                    v = swap;
                }
            }
            *d.at(i * w + j) = v;
        }
    }
    return *d.at(a.len * w + b.len);
}

// the candidate closest to name, if it's close enough to be a likely typo (a third of the name's
// length, at least 1); ties go to the alphabetically first
fn closest(name: str, cands: std::vec<str>&) -> str? {
    var chars: usize = 0;
    for (c) in name {
        if ((c & 0xC0) != 0x80) {
            chars += 1;
        }
    }
    if (chars < 3) {
        chars = 3;
    }
    val limit = chars / 3;
    var best: str? = null;
    var best_d: usize = 0;
    for (cp&) in cands.items() {
        val c = *cp;
        if (c == name || (c.len > 0 && c[0] == '@')) {
            continue;
        }
        val d = distance(name, c);
        if (d > limit) {
            continue;
        }
        if (best == null || d < best_d || (d == best_d && str_less(c, best ?? ""))) {
            best = c;
            best_d = d;
        }
    }
    return best;
}

// the keys of a map (in slot order: callers only take the closest, so order doesn't matter)
<V: type>
fn map_keys(m: std::map<str, V>&, out: std::vec<str>&) -> void {
    for (i) in 0..m.cap {
        if (m.state[i] == 1) {
            put(out, m.keys[i]);
        }
    }
}

// every name declared in namespace n: its items and child namespaces
attach fn ns_names(this: checker&, n: u32, out: std::vec<str>&) -> void {
    map_keys(&this.ns(n).names, out);
    map_keys(&this.ns(n).children, out);
}

// what the unresolved part of path p could have meant, seen from namespace ns: for a lone name, the
// locals and generic params in scope and every name in the enclosing namespaces; for a::b, the
// members of a (and of what `use a::...` imports)
attach fn path_candidates(this: checker&, ns: u32, p: path&, locals: bool) -> std::vec<str> {
    var out: std::vec<str> = {};
    if (p.segs.len == 1 || this.lookup(ns, p.segs.at(0).name) == null) {
        if (locals && p.segs.len == 1) {
            for (s&) in this.cx.scopes.items() {
                map_keys(&s.vars, &out);
            }
            for (g&) in this.env_at(this.cx.env).generics.items() {
                put(&out, g.name);
            }
        }
        var cur: u32? = ns;
        while (cur) {
            val n = cur;
            this.ns_names(n, &out);
            cur = this.ns(n).parent;
        }
        return move out;
    }
    var prefix: path = { segs: {}, span: p.span };
    for (i) in 0..p.segs.len - 1 {
        put(&prefix.segs, copy *p.segs.at(i));
    }
    val pf = this.lookup_path_ns(ns, &prefix);
    if (pf) {
        match (pf) {
            .NS(n) => { this.ns_names(n, &out); },
            default => {},
        }
    }
    if (p.segs.len == 2) {
        // `use a::b::c;` makes c's members reachable as a::name
        var cur: u32? = ns;
        while (cur) {
            val n = cur;
            for (up&) in this.ns(n).uses.items() {
                val u = *up;
                if (u.segs.at(0).name != p.segs.at(0).name) {
                    continue;
                }
                var target: found? = found::NS(0);
                for (seg&) in u.segs.items() {
                    var next: found? = null;
                    if (target) {
                        match (target) {
                            .NS(m) => { next = this.ns_member(m, seg.name, true); },
                            default => {},
                        }
                    }
                    target = next;
                }
                if (target) {
                    match (target) {
                        .NS(m) => { this.ns_names(m, &out); },
                        default => { put(&out, u.last()); },
                    }
                }
            }
            cur = this.ns(n).parent;
        }
    }
    return move out;
}

// the primitive type names, for `unknown type` help
val PRIMITIVES: str[23] = {
    "void", "never", "bool", "type", "str", "cstr", "f16", "f32", "f64", "f128", "error",
    "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize",
};

// `unknown name 'x'` / `unknown type 'x'`, with a did-you-mean when a close name exists
attach fn unknown(this: checker&, span: span, what: str, ns: u32, p: path&, locals: bool) -> compile_error {
    val missing = this.missing_part(ns, p);
    var cands = this.path_candidates(ns, p, locals);
    if (what == "type" && p.segs.len == 1) {
        for (k) in PRIMITIVES {
            put(&cands, k);
        }
    }
    val e = fail(span, fmt2("unknown {} '{}'", S(what), S(missing)));
    val c = closest(missing, &cands);
    if (c) {
        return with_help(move e, fmt("did you mean '{}'?", S(c)));
    }
    return move e;
}

// `T has no field 'x'`, with a did-you-mean from the fields that exist
attach fn no_field(this: checker&, span: span, t: u32, name: str, fields: std::vec<str>&) -> compile_error {
    val e = fail(span, fmt2("{} has no field '{}'", this.ty_name(t), S(name)));
    val c = closest(name, fields);
    if (c) {
        return with_help(move e, fmt("did you mean '{}'?", S(c)));
    }
    return move e;
}

// the span of name inside an item's span s (all of s when it isn't there): where an error about a
// declaration points
attach fn name_span(this: checker&, s: span, name: str) -> span {
    val text = this.files.at(@cast<usize>(s.file)).text;
    var lo = @cast<usize>(s.lo);
    var hi = @cast<usize>(s.hi);
    if (lo > text.len) {
        lo = text.len;
    }
    if (hi > text.len) {
        hi = text.len;
    }
    if (name.len == 0) {
        return s;
    }
    // like Rust's str::find from the last miss: a match that isn't a whole word skips past itself
    var i = lo;
    while (i + name.len <= hi) {
        if (text[i..i + name.len] == name) {
            val before = i == lo || !is_word_byte(text[i - 1]);
            val after = i + name.len >= hi || !is_word_byte(text[i + name.len]);
            if (before && after) {
                return { file: s.file, lo: @cast<u32>(i), hi: @cast<u32>(i + name.len) };
            }
            i += name.len;
        } else {
            i += 1;
        }
    }
    return s;
}

fn is_word_byte(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}
