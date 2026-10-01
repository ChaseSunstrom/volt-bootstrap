// What can't change stays unchanged through references. A port of bootstrap/check/lends.rs (the
// rules are there, by depth, with std::write's writer and the copy and as_str hooks). A body is a
// u64: what it is in the low two bits (BODY_FN, BODY_CLOSURE, or BODY_VALUE: whatever a fn value of
// a type holds) and the fn instance, closure or type above them.

val BODY_FN: u64 = 0;
val BODY_CLOSURE: u64 = 1;
val BODY_VALUE: u64 = 2;

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

// assigning to place: a write through the parameter it's reached through
attach fn note_write(this: checker&, place: tval&) -> void {
    val pv = place.pvia;
    if (pv) {
        if (this.cx.body != null && pv.off >= 0 && pv.off < 64) {
            this.mark(this.cx.body ?? 0, @cast<usize>(pv.k), @cast<u64>(1) << @cast<u32>(pv.off));
        }
    }
}

// passing v (a reference, pointer or slice) to parameter param of callee
attach fn note_arg(this: checker&, callee: u64, param: usize, v: tval&, span: span) -> void {
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
    if (v.ro != 0) {
        val root = v.root ?? "this";
        var root_param = false;
        val l = this.lookup_local(root);
        if (l) {
            root_param = l.param;
        }
        put(&this.lends, { at: span, callee: callee, param: param, mask: v.ro, root: root, root_param: root_param });
    }
    val vv = v.via;
    if (vv) {
        if (this.cx.body != null) {
            put(&this.lend_edges, { from: this.cx.body ?? 0, k: @cast<usize>(vv.k), off: vv.off, to: callee, j: param });
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
    // the first body behind the value that writes where it's read-only
    for (e&) in this.lend_edges.items() {
        if (e.from == b && e.k == k && (this.written(e.to, e.j) & mask) != 0) {
            val f = this.body_name(e.to, k, mask, pname);
            return fmt2("{} (called as a {} value)", move f, this.ty_name(id));
        }
    }
    return S("a fn value");
}

// Solve the writes (a parameter is written through when its body writes through it, or passes it
// on to one that's written through) and report each lend to one.
attach fn check_lends(this: checker&) -> void {
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
    }
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
        val e = fail(l.at, fmt4("'{}' is {}, and {} changes it{}: declare it with var", S(l.root), S(what), move fname, move thru));
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
