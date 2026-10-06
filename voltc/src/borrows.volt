// The borrow warnings, which never stop a build. A view is a local holding a slice, str, reference,
// pointer or iterator that a method gave out of a local container it took by reference
// (`val s = xs.items()`): the view has a loan on the container. A call to a method std marks
// @invalidates (push, insert, reserve, clear...) on the container may move or free its storage, so
// the views into it go stale; using a stale view warns. A view is stale on the paths where such a
// call came after it: its id with STALE set rides in cx.moved, so every merge the move checker does
// (ifs, matches, loops, breaks) applies to stale views too.

val STALE: u32 = 2147483648;

// whether a value of type t looks into memory something else owns: a reference, pointer, slice, str
// or cstr, an optional of one, or a value with nothing to delete that holds one (an iterator)
attach fn is_view(this: checker&, t: u32) -> bool {
    match (*this.t.get(t)) {
        .REF(x) => { return true; },
        .PTR(x) => { return true; },
        .SLICE(x) => { return true; },
        .STR => { return true; },
        .CSTR => { return true; },
        .OPT(x) => { return this.is_view(x); },
        .STRUCT(s) => { return this.ref_parts(t) != 0 && !(this.needs_drop(t) catch true); },
        default => { return false; },
    }
}

// does the fn instance carry @invalidates (it may move or free its receiver's storage)?
attach fn invalidates(this: checker&, inst: u32) -> bool {
    for (a&) in this.item_of(this.fi(inst).decl).attrs.items() {
        if (attr_named(a, "invalidates")) {
            return true;
        }
    }
    return false;
}

// inst is called on the container at place owner (named name): when it may move or free the
// container's storage, the views into it go stale, and a for loop going over its items is warned
// about here
attach fn invalidate(this: checker&, inst: u32, owner: u32, span: span) -> void {
    if (this.cx.dead > 0 || !this.invalidates(inst)) {
        return;
    }
    val name = this.local_at(owner);
    // the method's own name (the instance's has its generic arguments)
    var what = this.fi(inst).name;
    val fd = this.fn_decl_of(this.fi(inst).decl);
    if (fd) {
        what = fd->name;
    }
    for (e) in this.cx.loans.iter() {
        if (e.value->owner == owner) {
            this.cx.moved.add(*e.key | STALE);
            this.cx.stale_notes.put(*e.key, { span: span, what: what });
        }
    }
    for (it&) in this.cx.iterating.items() {
        if (it.owner == owner) {
            var msg = S(name);
            msg.push('.');
            msg.append(what);
            msg.append(" inside a loop over ");
            msg.append(name);
            msg.append("'s items: the loop goes on over the old ones, which this may move or free; collect the changes and make them after the loop");
            var d: diag = { span: span, msg: move msg, warning: true };
            put(&d.labels, { span: it.span, msg: fmt("the loop over {}", S(name)) });
            put(&this.warnings, move d);
        }
    }
}

// the local at place c (named name) was just given v: when v looks into a container, the local is a
// fresh view of it (not stale); otherwise it's no view
attach fn note_loan(this: checker&, c: u32, name: str, v: tval&) -> void {
    this.cx.moved.remove(c | STALE);
    // a view given a new value in a loop isn't read stale on the loop's next pass
    for (i) in 0..this.cx.loops.len {
        this.cx.loops.at(i).fresh_views.add(c);
    }
    if (v.loan == null) {
        this.cx.loans.remove(c);
        return;
    }
    this.cx.loans.put(c, { owner: v.loan ?? 0, owner_name: v.loan_name ?? "it", view_name: name });
}

// a read of the local l at span: when it's a view, warn if it may be stale, and keep the read for the
// back edges of the loops around it that it was made before
attach fn read_view(this: checker&, l: local&, span: span) -> void {
    if (this.cx.loans.get(l.c) == null) {
        return;
    }
    if (this.cx.moved.has(l.c | STALE)) {
        this.warn_stale(l.c, span, false);
    }
    var outer: usize = 0;
    for (i) in 0..this.cx.loops.len {
        val lc = this.cx.loops.at(i);
        if (!lc.is_block) {
            outer += 1;
            if (l.loops < outer && !lc.fresh_views.has(l.c)) {
                put(&lc.view_reads, { c: l.c, span: span });
            }
        }
    }
}

// a loop going around (its end, or a continue): a view read in it that's stale now is read stale on
// the next pass
attach fn stale_at_back_edge(this: checker&, li: usize) -> void {
    for (r&) in this.cx.loops.at(li).view_reads.items() {
        if (this.cx.moved.has(r.c | STALE)) {
            this.warn_stale(r.c, r.span, true);
        }
    }
}

// the warning for the stale view at place c, read at span (once per view)
attach fn warn_stale(this: checker&, c: u32, span: span, next_pass: bool) -> void {
    val ln = this.cx.loans.get(c) ?? return;
    if (!this.warned_views.add(c)) {
        return;
    }
    var msg = fmt2("'{}' looks into '{}', whose items may have moved or been freed since", S(ln->view_name), S(ln->owner_name));
    if (next_pass) {
        msg.append(" (on the loop's next pass)");
    }
    msg.append(": get '");
    msg.append(ln->view_name);
    msg.append("' again after the change");
    var d: diag = { span: span, msg: move msg, warning: true };
    val note = this.cx.stale_notes.get(c);
    if (note) {
        put(&d.labels, { span: note->span, msg: fmt2("{}.{} may move or free them here", S(ln->owner_name), S(note->what)) });
    }
    put(&this.warnings, move d);
}

// v, what a call of inst on the container at place owner gave: a view of it when the method gives
// out a view in its own right (a reference, pointer, slice, str or iterator; not one of its generic
// parameters, such as pop's T, which is a value whatever it holds)
attach fn lent_by(this: checker&, v: tval, inst: u32, owner: u32?) -> tval {
    if (owner == null || !this.is_view(v.ty)) {
        return v;
    }
    var declared = false;
    match (this.item_of(this.fi(inst).decl).kind) {
        .FN(f&) => {
            if (f.ret) {
                declared = this.view_type_ast(&f.ret, this.fi(inst).env);
            }
        },
        default => {},
    }
    if (!declared) {
        return v;
    }
    var r = v;
    r.loan = owner;
    r.loan_name = this.local_at(owner ?? 0);
    return r;
}

// whether a declared type gives out a view in its own right: a reference, pointer or slice, an
// optional of one, or a named type that isn't one of the fn's generic parameters (str, an iterator)
attach fn view_type_ast(this: checker&, t: ty&, env: u32) -> bool {
    match (t.kind) {
        .REF(x) => { return true; },
        .PTR(x) => { return true; },
        .SLICE(x) => { return true; },
        .OPTIONAL(x) => { return this.view_type_ast(x, env); },
        .PATH(p&) => { return !(p.is_single() && this.env_generic(env, p.segs.at(0).name) != null); },
        default => { return false; },
    }
}

// the name of the local at place c (for messages)
attach fn local_at(this: checker&, c: u32) -> str {
    var i = this.cx.scopes.len;
    while (i > 0) {
        i -= 1;
        for (e) in this.cx.scopes.at(i).vars.iter() {
            if (e.value->c == c) {
                return *e.key;
            }
        }
    }
    return "it";
}

// A local whose value holds a reference to one of this function's own locals (`val v = { x: &n }`,
// `val r = &n`): returning it hands out what's gone once the function returns. (Returning the
// literal or the & itself is an error: escapes.)

// the local of this function that e takes a reference to, in itself or in a part of the literal it
// is, or through a local that holds one
attach fn held_ref(this: checker&, e: expr&) -> str? {
    match (e.kind) {
        .UNARY(op, x) => {
            if (op == unop::ADDR) {
                return this.frame_root(x);
            }
        },
        .CAST(x, t) => { return this.held_ref(x); },
        .MOVE(x) => { return this.held_ref(x); },
        .LITERAL(items&) => {
            for (it&) in items.items() {
                val n = this.held_ref(&it.value);
                if (n) {
                    return n;
                }
            }
        },
        .TUPLE(xs&) => {
            for (x&) in xs.items() {
                val n = this.held_ref(x);
                if (n) {
                    return n;
                }
            }
        },
        .PATH(p&) => {
            if (p.is_single()) {
                val l = this.lookup_local(p.segs.at(0).name) ?? return null;
                val h = this.cx.ref_holders.get(l.c) ?? return null;
                return *h;
            }
        },
        default => {},
    }
    return null;
}

// the local at place c (of type t) was given e (all of it when whole, else a part): remember the
// local of this function it now holds a reference to
attach fn note_held(this: checker&, c: u32, t: u32, e: expr&, whole: bool) -> void {
    val n = this.held_ref(e);
    if (n != null && (this.holds(t) || this.is_view(t))) {
        this.cx.ref_holders.put(c, n ?? "");
    } else if (whole) {
        this.cx.ref_holders.remove(c);
    }
}

// `return e`: warn when e is a local holding a reference to one of this function's own
attach fn warn_held_return(this: checker&, e: expr&) -> void {
    match (e.kind) {
        .PATH(p&) => {
            if (!p.is_single() || this.cx.dead > 0) {
                return;
            }
            val name = p.segs.at(0).name;
            val l = this.lookup_local(name) ?? return;
            val h = this.cx.ref_holders.get(l.c) ?? return;
            var msg = fmt2("'{}' holds a reference to '{}', which is gone once this function returns: return what it refers to, or keep '", S(name), S(*h));
            msg.append(*h);
            msg.append("' where the caller can");
            put(&this.warnings, { span: e.span, msg: move msg, warning: true });
        },
        default => {},
    }
}
