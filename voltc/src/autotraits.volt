// send and sync, the thread-safety traits the checker derives (no std): a send value may move to
// another thread, and a sync value may be shared between threads by reference. A type is what it
// holds: numbers, bool, str, cstr and fn pointers are both; a raw pointer is neither; a reference
// T& (or a view T[..]) is both when T is sync; arrays, tuples, optionals, ranges, error unions,
// structs, enums and trait values are what their parts are; a closure is what its captures are, a
// frame what its fn's parameters are, and a fn(...) value neither (what it calls is unknown).
// @send and @sync on a struct or enum claim them whenever its type arguments have them (a type
// that guards its pointers, as std's containers and locks do); @not_send and @not_sync take them
// away. A <T: send> or <T: sync> bound a type doesn't meet warns where the generic is used: Volt's
// thread-safety findings are warnings, like its borrow findings, and nothing here costs at run time.

// why a type isn't send or sync: the parts' path to it (r.p; empty for the type itself) and what
// that part is (a raw pointer (i32*))
struct auto_miss {
    path: std::string;
    what: std::string;
}

fn auto_trait_name(sync: bool) -> str {
    if (sync) {
        return "sync";
    }
    return "send";
}

// is `t` (a bound's type) send or sync, by name: the name that isn't a trait of the program's
fn auto_bound_name(t: ty&) -> str? {
    match (t.kind) {
        .PATH(p) => {
            if (p.is_single() && p.segs.at(0).args == null) {
                val n = p.segs.at(0).name;
                if (n == "send" || n == "sync") {
                    return n;
                }
            }
        },
        default => {},
    }
    return null;
}

// a decl's @send/@sync (claimed: 1) or @not_send/@not_sync (taken away: 2), or 0
attach fn auto_attr(this: checker&, decl: u32, sync: bool) -> u32 {
    val name = auto_trait_name(sync);
    for (a&) in this.item_of(decl).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, x) => {
                if (n == name) {
                    return 1;
                }
                if (n.len == name.len + 4 && n.starts_with("not_") && n.ends_with(name)) {
                    return 2;
                }
            },
            default => {},
        }
    }
    return 0;
}

// why `t` isn't send (sync false) or sync (sync true); null when it is
attach fn auto_why(this: checker&, t: u32, sync: bool) -> auto_miss? {
    var seen: idset = {};
    return this.auto_why_in(t, sync, &seen);
}

// a part of a type (a field, element, capture): why it isn't, with its name put before the path
fn auto_in_part(m: auto_miss&, name: str) -> auto_miss? {
    var path = S(name);
    if (m.path.len() > 0) {
        if (!m.path.as_str().starts_with("[")) {
            path.push('.');
        }
        path.append(m.path.as_str());
    }
    return { path: move path, what: copy m.what };
}

attach fn auto_why_in(this: checker&, t: u32, sync: bool, seen: idset&) -> auto_miss? {
    match (*this.t.get(t)) {
        .PTR(x) => { return { path: S(""), what: fmt("a raw pointer ({})", this.ty_name(t)) }; },
        .VOIDPTR => { return { path: S(""), what: S("a raw pointer (void*)") }; },
        .FN_VAL(ps, r) => { return { path: S(""), what: fmt("a fn value ({}), which could call anything", this.ty_name(t)) }; },
        .REF(x) => { return this.auto_ref(x, seen); },
        .SLICE(x) => { return this.auto_ref(x, seen); },
        .OPT(x) => { return this.auto_why_in(x, sync, seen); },
        .RANGE(x) => { return this.auto_why_in(x, sync, seen); },
        .ARRAY(x, n) => {
            val m = this.auto_why_in(x, sync, seen) ?? return null;
            return auto_in_part(&m, "[..]");
        },
        .ERR_UNION(e, x) => { return this.auto_why_in(x, sync, seen); },
        .TUPLE(es, names) => {
            for (i) in 0..es.len {
                val m = this.auto_why_in(*es.at(i), sync, seen) ?? continue;
                val nm = *names.at(i) ?? "";
                if (nm.len > 0) {
                    return auto_in_part(&m, nm);
                }
                val idx = fmt("{}", unum(@cast<u64>(i)));
                return auto_in_part(&m, idx.as_str());
            }
            return null;
        },
        .STRUCT(s) => {
            val decl = this.si(s).decl;
            val claimed = this.auto_attr(decl, sync);
            if (claimed == 2) {
                return { path: S(""), what: fmt("marked @not_{}", S(auto_trait_name(sync))) };
            }
            if (claimed == 1) {
                return this.auto_args(&this.si(s).args, sync, seen);
            }
            if (!seen.add(s * 2)) {
                return null; // it holds itself: it's what the rest of it is
            }
            val fs = this.struct_fields(s, this.item_of(decl).span) catch return null;
            for (f&) in fs.items() {
                val m = this.auto_why_in(f.ty, sync, seen) ?? continue;
                return auto_in_part(&m, f.name);
            }
            return null;
        },
        .ENUM(e) => {
            val decl = this.ei(e).decl;
            val claimed = this.auto_attr(decl, sync);
            if (claimed == 2) {
                return { path: S(""), what: fmt("marked @not_{}", S(auto_trait_name(sync))) };
            }
            if (claimed == 1) {
                return this.auto_args(&this.ei(e).args, sync, seen);
            }
            if (!seen.add(e * 2 + 1)) {
                return null;
            }
            for (k) in 0..this.ei(e).payloads.len {
                val pt = *this.ei(e).payloads.at(k) ?? continue;
                val m = this.auto_why_in(pt, sync, seen) ?? continue;
                return auto_in_part(&m, *this.ei(e).names.at(k));
            }
            return null;
        },
        .TRAIT_UNION(u) => {
            for (mt) in this.ui(u).members.items() {
                if (this.auto_why_in(mt, sync, seen)) {
                    return { path: S(""), what: fmt2("able to hold {}, which isn't {}", this.ty_name(mt), S(auto_trait_name(sync))) };
                }
            }
            return null;
        },
        .CLOSURE(c) => {
            for (cf&) in this.ci(c).caps.items() {
                val m = this.auto_why_in(cf.ty, sync, seen) ?? continue;
                return auto_in_part(&m, cf.name);
            }
            return null;
        },
        .FRAME(f) => {
            for (p&) in this.fi(f).params.items() {
                val m = this.auto_why_in(p.ty, sync, seen) ?? continue;
                return auto_in_part(&m, p.name);
            }
            return null;
        },
        default => { return null; },
    }
}

// a reference (or view) to x: send and sync when x is sync
attach fn auto_ref(this: checker&, x: u32, seen: idset&) -> auto_miss? {
    if (this.auto_why_in(x, true, seen)) {
        return { path: S(""), what: fmt("a reference to {}, which isn't sync", this.ty_name(x)) };
    }
    return null;
}

// a type marked @send/@sync: it is when each of its type arguments is
attach fn auto_args(this: checker&, args: std::vec<gval>&, sync: bool, seen: idset&) -> auto_miss? {
    for (a&) in args.items() {
        match (*a) {
            .TY(x) => {
                if (this.auto_why_in(x, sync, seen)) {
                    return { path: S(""), what: fmt2("holding {}, which isn't {}", this.ty_name(x), S(auto_trait_name(sync))) };
                }
            },
            default => {},
        }
    }
    return null;
}

// a generic's instance for `args` (fn_inst): a send or sync bound an argument doesn't meet warns
// at the use
attach fn warn_auto_bounds(this: checker&, d: u32, args: std::vec<gval>&, span: span) -> void {
    val gps = this.fn_generics(d);
    for (i) in 0..gps.len {
        if (i >= args.len) {
            break;
        }
        for (b&) in gps.at(i).bounds.items() {
            val bt = *b ?? continue;
            val name = auto_bound_name(bt) ?? continue;
            if (this.bound_trait(bt, this.dl(d).ns)) {
                continue; // a trait of the program's own named send or sync
            }
            match (*args.at(i)) {
                .TY(t) => {
                    val sync = name == "sync";
                    val m = this.auto_why(t, sync) ?? continue;
                    var what = this.ty_name(t);
                    match (*this.t.get(t)) {
                        .CLOSURE(c) => { what = S("the closure"); },
                        default => {},
                    }
                    var why = fmt("it's {}", copy m.what);
                    if (m.path.len() > 0) {
                        why = fmt2("{} is {}", copy m.path, copy m.what);
                    }
                    var fname = S(this.decl_name(d));
                    var dg: diag = { span: span, msg: fmt5("{} isn't {}, but {}'s {} must be: {}", move what, S(name), move fname, S(gps.at(i).name), move why), warning: true };
                    put(&this.warnings, move dg);
                },
                default => {},
            }
        }
    }
}
