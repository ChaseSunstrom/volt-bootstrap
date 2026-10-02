// What can't change stays unchanged through references. A port of bootstrap/check/lends.rs (the
// rules are there, by depth, with std::write's writer and the copy and as_str hooks). A body is a
// u64: what it is in the low two bits (BODY_FN, BODY_CLOSURE, or BODY_VALUE: whatever a fn value of
// a type holds, or BODY_SITE: a call's result, written through like a parameter) and the fn instance,
// closure, type or site above them. A reference a fn returns points where its argument did: each body
// records where what it returns points (rets), solved into a summary a body; a call whose result is a
// reference is a site, whose writes reach that call's arguments through the callee's summary.

val BODY_FN: u64 = 0;
val BODY_CLOSURE: u64 = 1;
val BODY_VALUE: u64 = 2;
val BODY_SITE: u64 = 3;

// a via's parameter at or above this is call site k - SITE's result, not a parameter of the body
val SITE: u32 = 16777216;

fn body_key(kind: u64, id: u32) -> u64 {
    return (@cast<u64>(id) << 2) | kind;
}

fn body_id(b: u64) -> u32 {
    return @cast<u32>(b >> 2);
}

// where a reference points, as a parameter's memory: depth e past what it points at is depth e +
// off past what parameter k points at
struct reach {
    k: u32;
    off: i32;
}

fn deeper(v: reach?, n: i32) -> reach? {
    if (v) {
        val r: reach = { k: v.k, off: v.off + n };
        return r;
    }
    return null;
}

// a write mask moved by `by` depths (memory above a parameter's isn't the caller's)
fn shift(w: u64, by: i32) -> u64 {
    if (by == 0) {
        return w;
    }
    if (by > 0 && by < 64) {
        return w << @cast<u32>(by);
    }
    if (by < 0 && by > -64) {
        return w >> @cast<u32>(-by);
    }
    return 0;
}

// a parameter of one body passed on (off depths further in) to a parameter of another
struct lend_edge {
    from: u64;
    k: usize;
    off: i32;
    to: u64;
    j: usize;
}

// what a call whose result is a reference lends one reference parameter
struct site_arg {
    param: usize;
    ro: u32;
    via: reach?;
    root: str;
    root_param: bool;
    at: span;
}

// a call whose result is a reference: what it calls, from where, and what it lends
struct call_site {
    callee: u64;
    caller: u64?;
    args: std::vec<site_arg> = {};
}

// where what a body returns points (k may name a site)
struct ret_entry {
    body: u64;
    k: u32;
    off: i32;
}

// a call lending a read-only reference to a parameter, an error if the callee writes through it
struct lend {
    at: span;
    callee: u64;
    param: usize;
    mask: u32; // the depths that can't change
    root: str;
    root_param: bool; // the root is a parameter (without var), not a val
}

// whether a value of this type reaches other memory a fn could write through: a reference, a
// pointer or a slice
attach fn reaches(this: checker&, t: u32) -> bool {
    match (*this.t.get(t)) {
        .REF(x) => { return true; },
        .PTR(x) => { return true; },
        .SLICE(x) => { return true; },
        default => { return false; },
    }
}

// r = &place: read-only where the place can't change (depth 0) and where what it holds points at
// what can't (deeper); the parameter memory it is
fn addr_prov(r: tval&, place: tval&) -> void {
    var ro = place.ro << 1;
    if (place.lv && !place.mutable) {
        ro = ro | 1;
    }
    r.ro = ro;
    r.via = place.pvia;
    if (r.via == null) {
        r.via = deeper(place.via, -1);
    }
    r.root = place.root;
}

// the place a reference (pointer, slice) value r reaches: mutable unless r's pointee is read-only,
// the parameter memory r points at, and what it holds one depth further
fn through(place: tval&, r: tval) -> void {
    place.mutable = place.mutable && (r.ro & 1) == 0;
    place.rop = (r.ro & 1) != 0;
    place.pvia = r.via;
    place.ro = r.ro >> 1;
    place.via = deeper(r.via, 1);
    place.root = r.root;
}

// a value from either of two (a ?? b, match arms): read-only where either is
fn merge_prov(into: tval&, v: tval&) -> void {
    into.ro = into.ro | v.ro;
    if (into.via == null) {
        into.via = v.via;
    }
    if (into.root == null) {
        into.root = v.root;
    }
}

attach fn mark(this: checker&, b: u64, k: usize, w: u64) -> bool {
    if (!this.writes.contains(b)) {
        this.writes.put(b, {});
    }
    val ws = this.writes.get(b);
    if (ws) {
        while (ws.len <= k) {
            put(ws, 0);
        }
        val old = *ws.at(k);
        *ws.at(k) = old | w;
        return (w & ~old) != 0;
    }
    return false;
}

attach fn written(this: checker&, b: u64, k: usize) -> u64 {
    val ws = this.writes.get(b);
    if (ws) {
        if (k < ws.len) {
            return *ws.at(k);
        }
    }
    return 0;
}

// the body a via's k is a parameter of: the body being checked, or (k >= SITE) a call's result
attach fn via_body(this: checker&, k: u32) -> u64? {
    if (k >= SITE) {
        return body_key(BODY_SITE, k - SITE);
    }
    return this.cx.body;
}

fn via_param(k: u32) -> usize {
    if (k >= SITE) {
        return 0;
    }
    return @cast<usize>(k);
}

// assigning to place: a write through the parameter it's reached through
attach fn note_write(this: checker&, place: tval&) -> void {
    val pv = place.pvia;
    if (pv) {
        val b = this.via_body(pv.k);
        if (b != null && pv.off >= 0 && pv.off < 64) {
            this.mark(b ?? 0, via_param(pv.k), @cast<u64>(1) << @cast<u32>(pv.off));
        }
    }
}

// returning v from the body being checked: where it points, when it's a reference
attach fn note_return(this: checker&, v: tval&) -> void {
    val vv = v.via;
    if (vv) {
        if (this.cx.body != null && this.reaches(v.ty)) {
            put(&this.rets, { body: this.cx.body ?? 0, k: vv.k, off: vv.off });
        }
    }
}

// a call to callee returning ret: a site when that's a reference (its arguments are noted into it, and
// its result points at it)
attach fn open_site(this: checker&, callee: u64, ret: u32) -> u32? {
    if (!this.reaches(ret)) {
        return null;
    }
    put(&this.sites, { callee: callee, caller: this.cx.body });
    return @cast<u32>(this.sites.len - 1);
}

// a call's result, pointing at its site
fn site_result(v: tval, site: u32?) -> tval {
    var r = v;
    if (site) {
        val rv: reach = { k: SITE + site, off: 0 };
        r.via = rv;
    }
    return r;
}

// passing v (a reference, pointer or slice) to parameter param of callee (at call site, when its result
// is a reference)
attach fn note_arg(this: checker&, callee: u64, param: usize, v: tval&, span: span, site: u32?) -> void {
    if ((callee & 3) == BODY_FN) {
        val f = body_id(callee);
        if (param >= this.fi(f).params.len || !this.reaches(this.fi(f).params.at(param).ty) || this.fi(f).intrinsic != null) {
            return;
        }
        val fd = this.fn_decl_of(this.fi(f).decl);
        if (fd) {
            if (fd.extern_abi != null && fd.body == null) {
                return; // C: unchecked
            }
        }
    }
    val root = v.root ?? "this";
    var root_param = false;
    val l = this.lookup_local(root);
    if (l) {
        root_param = l.param;
    }
    if (site) {
        put(&this.sites.at(@cast<usize>(site)).args, { param: param, ro: v.ro, via: v.via, root: root, root_param: root_param, at: span });
    }
    if (v.ro != 0) {
        put(&this.lends, { at: span, callee: callee, param: param, mask: v.ro, root: root, root_param: root_param });
    }
    val vv = v.via;
    if (vv) {
        val b = this.via_body(vv.k);
        if (b != null) {
            put(&this.lend_edges, { from: b ?? 0, k: via_param(vv.k), off: vv.off, to: callee, j: param });
        }
    }
}

// fn values of the same signature share a key, whichever kind they are
attach fn value_key(this: checker&, fv: u32) -> u32 {
    match (*this.t.get(fv)) {
        .FN_PTR(ps, r, va) => { return this.t.intern(tyk::FN_VAL(copy ps, r)); },
        default => { return fv; },
    }
}

// body b made into a fn value of type fv (fn(...) or a C fn pointer): a call through one writes
// through what b does
attach fn escape(this: checker&, b: u64, fv: u32) -> void {
    val key = body_key(BODY_VALUE, this.value_key(fv));
    var n: usize = 0;
    match (*this.t.get(fv)) {
        .FN_PTR(ps, r, va) => { n = ps.len; },
        .FN_VAL(ps, r) => { n = ps.len; },
        default => {},
    }
    for (j) in 0..n {
        put(&this.lend_edges, { from: key, k: j, off: 0, to: b, j: j });
    }
}

// for messages: what body b is called, and its parameter k's name
attach fn body_name(this: checker&, b: u64, k: usize, mask: u64, pname: std::string&) -> std::string {
    val id = body_id(b);
    if ((b & 3) == BODY_FN) {
        val f = this.fi(id);
        if (k < f.params.len) {
            *pname = S(f.params.at(k).name);
        }
        val fd = this.fn_decl_of(f.decl);
        if (fd) {
            return S(fd.name);
        }
        return S(f.name);
    }
    if ((b & 3) == BODY_CLOSURE) {
        val names = &this.closures.at(@cast<usize>(id)).names;
        if (k < names.len) {
            *pname = S(*names.at(k));
        }
        return S("a closure");
    }
    if ((b & 3) == BODY_SITE) {
        return S("a call");
    }
    // the first body behind the value that writes where it's read-only
    for (e&) in this.lend_edges.items() {
        if (e.from == b && e.k == k && (this.written(e.to, e.j) & mask) != 0) {
            val f = this.body_name(e.to, k, mask, pname);
            return fmt2("{} (called as a {} value)", move f, this.ty_name(id));
        }
    }
    return S("a fn value");
}

// where what each body returns points: (parameter, depth) pairs, through the calls it returns the
// results of (a fixpoint, so recursion works; depths past 63 are dropped)
attach fn return_summaries(this: checker&) -> std::map<u64, std::vec<reach>> {
    var sums: std::map<u64, std::vec<reach>> = {};
    var changed = true;
    while (changed) {
        changed = false;
        for (r&) in this.rets.items() {
            var found: std::vec<reach> = {};
            this.expand(&sums, r.k, r.off, &found);
            for (x&) in found.items() {
                if (add_reach(&sums, r.body, *x)) {
                    changed = true;
                }
            }
        }
        // a fn value's results point where any fn made into one does
        for (e&) in this.lend_edges.items() {
            if ((e.from & 3) != BODY_VALUE) {
                continue;
            }
            val gs = sums.get(e.to);
            if (gs) {
                val got = copy *gs;
                for (x&) in got.items() {
                    if (add_reach(&sums, e.from, *x)) {
                        changed = true;
                    }
                }
            }
        }
    }
    return move sums;
}

// adds r to body b's summary; whether it's new
fn add_reach(sums: std::map<u64, std::vec<reach>>&, b: u64, r: reach) -> bool {
    if (!sums.contains(b)) {
        sums.put(b, {});
    }
    val v = sums.get(b);
    if (v) {
        for (x&) in v.items() {
            if (x.k == r.k && x.off == r.off) {
                return false;
            }
        }
        put(v, r);
        return true;
    }
    return false;
}

// (via k, off) as parameter memory: itself, or for a call's result, where the callee's result points as
// that call's arguments (a call's arguments are calls made before it, so this ends)
attach fn expand(this: checker&, sums: std::map<u64, std::vec<reach>>&, k: u32, off: i32, out: std::vec<reach>&) -> void {
    if (off >= 64 || off <= -64) {
        return;
    }
    if (k < SITE) {
        put(out, { k: k, off: off });
        return;
    }
    val st = this.sites.at(@cast<usize>(k - SITE));
    val ps = sums.get(st.callee);
    if (ps) {
        for (p&) in ps.items() {
            for (a&) in st.args.items() {
                val av = a.via;
                if (av) {
                    if (a.param == @cast<usize>(p.k)) {
                        this.expand(sums, av.k, av.off + p.off + off, out);
                    }
                }
            }
        }
    }
}

// Solve the writes (a parameter is written through when its body writes through it, or passes it
// on to one that's written through, or a call's result into it is) and report each lend to one.
attach fn check_lends(this: checker&) -> void {
    val sums = this.return_summaries();
    var changed = true;
    while (changed) {
        changed = false;
        for (i) in 0..this.lend_edges.len {
            val e = *this.lend_edges.at(i);
            val w = shift(this.written(e.to, e.j), e.off);
            if (w != 0 && this.mark(e.from, e.k, w)) {
                changed = true;
            }
        }
        // a site's writes reach the arguments its result may point into
        for (s) in 0..this.sites.len {
            val w = this.written(body_key(BODY_SITE, @cast<u32>(s)), 0);
            if (w == 0) {
                continue;
            }
            val st = this.sites.at(s);
            val ps = sums.get(st.callee);
            if (ps) {
                for (p&) in ps.items() {
                    for (a&) in st.args.items() {
                        val av = a.via;
                        if (av) {
                            if (a.param == @cast<usize>(p.k)) {
                                var to: u64? = st.caller;
                                if (av.k >= SITE) {
                                    to = body_key(BODY_SITE, av.k - SITE);
                                }
                                if (to != null && this.mark(to ?? 0, via_param(av.k), shift(w, p.off + av.off))) {
                                    changed = true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    // a write through a call's result into an argument that can't change
    for (s) in 0..this.sites.len {
        val w = this.written(body_key(BODY_SITE, @cast<u32>(s)), 0);
        if (w == 0) {
            continue;
        }
        val st = this.sites.at(s);
        val ps = sums.get(st.callee);
        if (ps) {
            for (a&) in st.args.items() {
                var hit = false;
                for (p&) in ps.items() {
                    if (a.param == @cast<usize>(p.k) && (@cast<u64>(a.ro) & shift(w, p.off)) != 0) {
                        hit = true;
                    }
                }
                if (!hit) {
                    continue;
                }
                var unused: std::string = {};
                val fname = this.body_name(st.callee, a.param, 0, &unused);
                var what = "a val";
                if (a.root_param) {
                    what = "a parameter without var";
                }
                val e = this.var_fix(fail(a.at, fmt3("'{}' is {}, and it's changed through what {} returns: declare it with var", S(a.root), S(what), move fname)), a.root, a.at);
                put(&this.errors, err_diag(&e));
            }
        }
    }
    this.sites.clear();
    this.rets.clear();
    for (l&) in this.lends.items() {
        val mask = @cast<u64>(l.mask);
        if ((this.written(l.callee, l.param) & mask) == 0) {
            continue;
        }
        var pname: std::string = {};
        val fname = this.body_name(l.callee, l.param, mask, &pname);
        var what = "a val";
        if (l.root_param) {
            what = "a parameter without var";
        }
        var thru: std::string = {};
        if (pname.len() > 0) {
            thru = fmt(" (through {})", move pname);
        }
        val e = this.var_fix(fail(l.at, fmt4("'{}' is {}, and {} changes it{}: declare it with var", S(l.root), S(what), move fname, move thru)), l.root, l.at);
        put(&this.errors, err_diag(&e));
    }
    this.lends.clear();
    for (h&) in this.ro_hooks.items() {
        if ((this.written(body_key(BODY_FN, *h), 0) & 1) != 0) {
            var unused: std::string = {};
            val fname = this.body_name(body_key(BODY_FN, *h), 0, 1, &unused);
            val e = fail(this.item_of(this.fi(*h).decl).span, fmt("{} changes this, but copying or printing a val calls it too: it can only read this", move fname));
            put(&this.errors, err_diag(&e));
        }
    }
    this.ro_hooks.clear();
}
