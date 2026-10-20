// The borrow warnings, which never stop a build. A view is a local holding a slice, str, reference,
// pointer or iterator that a method gave out of a container it took by reference, a local or a
// chain of its fields (`val s = xs.items()`, `this.items.items()`): the view has a loan on that
// place. A change at a place reaches the views into it and its fields: a call to a method std marks
// @invalidates (push, insert, reserve, clear...), which may move or free the storage, or a new value
// (`xs = ys`) when the old value had something to delete. The views it reaches go stale; using a
// stale view warns. A fn not attached to a container lends its result the same way out of its
// first reference parameter (`str_views(&names)`), and a result holding views counts too when it's
// an owned container of them (std::vec<str>). The end of a block is a change at each local it
// deletes. A view is stale on the paths where such a change came after it: its id with
// STALE set rides in cx.moved, so every merge the move checker does (ifs, matches, loops, breaks)
// applies to stale views too. A closure held in a
// local is followed where it's called by that name: one that captured a view has the view's loan,
// and one whose body changes a captured container makes that change at each call.

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

// the place e names when it's a local or a chain of its fields (`xs`, `this.items`; `*this` is
// this), else null
attach fn place_at_of(this: checker&, e: expr&) -> place_at? {
    match (e.kind) {
        .UNARY(op, x) => {
            if (op == unop::DEREF) {
                return this.place_at_of(x);
            }
        },
        .PATH(p&) => {
            if (p.is_single()) {
                val name = p.segs.at(0).name;
                val l = this.lookup_local(name) ?? return null;
                return { root: l.own ?? l.c, path: "", name: name };
            }
        },
        .THIS => {
            val l = this.lookup_local("this") ?? return null;
            return { root: l.own ?? l.c, path: "", name: "this" };
        },
        .FIELD(b, n, gargs) => {
            if (gargs != null) {
                return null;
            }
            val pb = this.place_at_of(b) ?? return null;
            var path = S(pb.path);
            path.push('.');
            path.append(n);
            var name = S(pb.name);
            name.push('.');
            name.append(n);
            return { root: pb.root, path: this.place_name(move path), name: this.place_name(move name) };
        },
        default => {},
    }
    return null;
}

// s, kept once however often it's named (place_at_of runs for each method call and assignment)
attach fn place_name(this: checker&, s: std::string) -> str {
    val got = this.place_names.get(s.as_str());
    if (got) {
        return *got;
    }
    val k = this.intern(move s);
    this.place_names.put(k, k);
    return k;
}

// does a change at place p reach what's at place q: q is p or a field of it (a change at this.b
// leaves this.a alone, and a field written leaves the views its container's methods gave)
fn covers(p: place_at&, q: place_at&) -> bool {
    if (p.root != q.root || !q.path.starts_with(p.path)) {
        return false;
    }
    return q.path.len == p.path.len || q.path[p.path.len] == '.';
}

// a change at place p, at span: a call of the method what that may move or free its storage, or a
// new value when what is "" (via: the closure whose call makes it). The views into p or a field of
// it go stale, closures using one too; in a closure's body, a change at a captured container is kept
// for the closure's calls
attach fn changed(this: checker&, p: place_at&, what: str, via: str?, span: span) -> void {
    if (this.cx.dead > 0) {
        return;
    }
    for (e) in this.cx.loans.iter() {
        if (covers(p, &e.value->owner)) {
            this.cx.moved.add(*e.key | STALE);
            this.cx.stale_notes.put(*e.key, { span: span, at: p.name, what: what, via: via });
        }
    }
    val outer = this.cx.cap_roots.get(p.root);
    if (outer) {
        put(&this.cx.cap_changes, { at: { root: *outer, path: p.path, name: p.name }, what: what });
    }
}

// the block of scope sc ended at span (its closing brace): each local it deletes, unless given away
// on some path, is gone, so the views into it go stale
attach fn scope_ended(this: checker&, sc: usize, span: span) -> void {
    if (this.cx.dead > 0 || this.cx.loans.len == 0) {
        return;
    }
    for (x&) in this.cx.scopes.at(sc).exits.items() {
        match (*x) {
            .DROP(c, d, flag) => {
                if (!this.cx.moved.has(c)) {
                    val p: place_at = { root: c, path: "", name: "" };
                    for (e) in this.cx.loans.iter() {
                        if (covers(&p, &e.value->owner)) {
                            this.cx.moved.add(*e.key | STALE);
                            this.cx.stale_notes.put(*e.key, { span: span, at: this.local_at(c), what: "", gone: true });
                        }
                    }
                }
            },
            default => {},
        }
    }
}

// the place e names (of type t) was given a new value at span: when the old one had something to
// delete, the views into it look at what's gone, and a loop over its items (or a field's) warns.
// Plain data or a view given another (a reference pointed elsewhere) frees nothing: the views made
// through it look into what it held, which it no longer names, so they're no longer its
attach fn assigned(this: checker&, e: expr&, t: u32, span: span) -> void {
    val p = this.place_at_of(e) ?? return;
    if (this.needs_drop(t) catch false) {
        this.changed(&p, "", null, span);
        this.changed_in_loop(&p, "", span);
        return;
    }
    var gone: std::vec<u32> = {};
    for (en) in this.cx.loans.iter() {
        if (covers(&p, &en.value->owner)) {
            put(&gone, *en.key);
        }
    }
    for (k&) in gone.items() {
        this.cx.loans.remove(*k);
        this.cx.moved.remove(*k | STALE);
    }
}

// inst is called on the container at place owner: when it may move or free the container's storage,
// the views into it go stale, and a for loop going over its items is warned about here
attach fn invalidate(this: checker&, inst: u32, owner: place_at&, span: span) -> void {
    if (this.cx.dead > 0 || !this.invalidates(inst)) {
        return;
    }
    // the method's own name (the instance's has its generic arguments)
    var what = this.fi(inst).name;
    val fd = this.fn_decl_of(this.fi(inst).decl);
    if (fd) {
        what = fd->name;
    }
    this.changed(owner, what, null, span);
    this.changed_in_loop(owner, what, span);
}

// a change at place p at span (a call of the method what, or a new value when what is ""): a for
// loop going over the items at p or a field of it is warned about
attach fn changed_in_loop(this: checker&, p: place_at&, what: str, span: span) -> void {
    if (this.cx.dead > 0) {
        return;
    }
    for (it&) in this.cx.iterating.items() {
        if (covers(p, &it.owner)) {
            var msg = S(p.name);
            var does = "may move or free";
            if (what.len == 0) {
                msg.append(" given a new value");
                does = "frees";
            } else {
                msg.push('.');
                msg.append(what);
            }
            msg.append(" inside a loop over ");
            msg.append(it.owner.name);
            msg.append("'s items: the loop goes on over the old ones, which this ");
            msg.append(does);
            msg.append("; collect the changes and make them after the loop");
            var d: diag = { span: span, msg: move msg, warning: true };
            put(&d.labels, { span: it.span, msg: fmt("the loop over {}", S(it.owner.name)) });
            put(&this.warnings, move d);
        }
    }
}

// f(...) at span, where callee names a closure held in a local: a view it uses that's stale warns,
// and the changes its body makes at captured containers are made here. (A closure passed away, or
// reached another way, isn't followed.)
attach fn called_closure(this: checker&, callee: expr&, span: span) -> void {
    var name = "";
    match (callee.kind) {
        .PATH(p&) => {
            if (!p.is_single()) {
                return;
            }
            name = p.segs.at(0).name;
        },
        default => { return; },
    }
    val l = this.lookup_local(name) ?? return;
    val ln = this.cx.loans.get(l.c);
    if (ln != null && ln->uses != null) {
        this.read_loan(&l, callee.span);
    }
    match (*this.t.get(l.ty)) {
        .CLOSURE(id) => {
            val n = this.ci(id).changes.len;
            for (i) in 0..n {
                val ch = *this.ci(id).changes.at(i);
                this.changed(&ch.at, ch.what, name, span);
            }
        },
        default => {},
    }
}

// v, a closure capturing caps: when one is a view, the closure has its loan
attach fn closure_loan(this: checker&, v: tval&, caps: std::vec<capture>&) -> void {
    for (c&) in caps.items() {
        val l = this.lookup_local(c.name);
        if (l) {
            val ln = this.cx.loans.get(l.c);
            if (ln != null && ln->uses == null) {
                // ponytail: one loan per closure; one using views of two containers is followed for the first
                v.loan = ln->owner;
                v.loan_uses = c.name;
                if (c.mode == cap_mode::REF) {
                    v.loan_uses_at = l.c;
                }
                return;
            }
        }
    }
}

// the local at place c (named name) was just given v: when v looks into a container, the local is a
// fresh view of it (not stale); otherwise it's no view. A closure that captured it by reference sees
// the new value too
attach fn note_loan(this: checker&, c: u32, name: str, v: tval&) -> void {
    this.fresh_loan(c, v.loan);
    var gone: std::vec<u32> = {};
    for (e) in this.cx.loans.iter() {
        if (e.value->uses_at != null && (e.value->uses_at ?? 0) == c) {
            put(&gone, *e.key);
        }
    }
    for (k&) in gone.items() {
        this.fresh_loan(*k, v.loan);
    }
    if (v.loan == null) {
        return;
    }
    this.cx.loans.put(c, { owner: v.loan ?? { root: 0, path: "", name: "" }, view_name: name, uses: v.loan_uses, uses_at: v.loan_uses_at });
}

// the view (or closure using one) at place c is fresh: not stale, on the loop's next pass either;
// it looks into owner now, or is no view when that's null
attach fn fresh_loan(this: checker&, c: u32, owner: place_at?) -> void {
    this.cx.moved.remove(c | STALE);
    for (i) in 0..this.cx.loops.len {
        this.cx.loops.at(i).fresh_views.add(c);
    }
    if (owner == null) {
        this.cx.loans.remove(c);
        return;
    }
    val ln = this.cx.loans.get(c);
    if (ln) {
        ln->owner = owner ?? { root: 0, path: "", name: "" };
    }
}

// a read of the local l at span: when it's a view, warn if it may be stale, and keep the read for the
// back edges of the loops around it that it was made before. (A closure using a view is checked
// where it's called, by called_closure.)
attach fn read_view(this: checker&, l: local&, span: span) -> void {
    val ln = this.cx.loans.get(l.c) ?? return;
    if (ln->uses == null) {
        this.read_loan(l, span);
    }
}

attach fn read_loan(this: checker&, l: local&, span: span) -> void {
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
    val note = this.cx.stale_notes.get(c);
    var what = "";
    if (note) {
        what = note->what;
    }
    val gone = note != null && note->gone;
    val renewed = note != null && what == "" && !gone;
    var msg: std::string = {};
    if (ln->uses) {
        // a closure using the view
        msg = fmt2("'{}' uses '{}', which looks into '", S(ln->view_name), S(ln->uses ?? ""));
        msg.append(ln->owner.name);
        if (gone) {
            msg.append("', deleted since at the end of its block");
        } else if (renewed) {
            msg.append("', given a new value since");
        } else {
            msg.append("', changed since by ");
            msg.append(what);
        }
        if (next_pass) {
            msg.append(" (on the loop's next pass)");
        }
    } else if (gone) {
        msg = fmt2("'{}' looks into '{}', which was deleted at the end of its block: keep '", S(ln->view_name), S(ln->owner.name));
        msg.append(note->at);
        msg.append("' as long as '");
        msg.append(ln->view_name);
        msg.append("' (declare it outside the block)");
    } else {
        msg = fmt2("'{}' looks into '{}', ", S(ln->view_name), S(ln->owner.name));
        if (renewed) {
            msg.append("which was given a new value since");
        } else {
            msg.append("whose items may have moved or been freed since");
        }
        if (next_pass) {
            msg.append(" (on the loop's next pass)");
        }
        msg.append(": get '");
        msg.append(ln->view_name);
        if (renewed) {
            msg.append("' again after it");
        } else {
            msg.append("' again after the change");
        }
    }
    var d: diag = { span: span, msg: move msg, warning: true };
    if (note) {
        var lm: std::string = {};
        if (gone) {
            lm = fmt("{} is deleted here", S(note->at));
        } else if (note->via) {
            lm = fmt("{}() ", S(note->via ?? ""));
            if (renewed) {
                lm.append("gives ");
                lm.append(note->at);
                lm.append(" a new value here");
            } else {
                lm.append("calls ");
                lm.append(note->at);
                lm.push('.');
                lm.append(what);
                lm.append(" here, which may move or free them");
            }
        } else if (renewed) {
            lm = S("given a new value here");
        } else {
            lm = fmt2("{}.{} may move or free them here", S(note->at), S(what));
        }
        put(&d.labels, { span: note->span, msg: move lm });
    }
    put(&this.warnings, move d);
}

// v, what a call of inst on the container at place owner gave: a view of it when the method gives
// out a view in its own right (a reference, pointer, slice, str or iterator; not one of its generic
// parameters, such as pop's T, which is a value whatever it holds)
attach fn lent_by(this: checker&, v: tval, inst: u32, owner: place_at?) -> tval {
    if (owner == null) {
        return v;
    }
    var declared = false;
    match (this.item_of(this.fi(inst).decl).kind) {
        .FN(f&) => {
            if (f.ret) {
                declared = this.gives_views(v.ty, &f.ret, this.fi(inst).env);
            }
        },
        default => {},
    }
    if (!declared) {
        return v;
    }
    var r = v;
    r.loan = owner;
    return r;
}

// whether a value of type t, declared as a, holds views it gives out: a view (view_type_ast), or an
// owned generic container whose type arguments, declared outside the fn's generic parameters, are
// such (std::vec<str>, not std::vec<T> with T = str, which holds values whatever they are)
attach fn gives_views(this: checker&, t: u32, a: ty&, env: u32) -> bool {
    if (this.is_view(t)) {
        return this.view_type_ast(a, env);
    }
    var s: u32 = 0;
    match (*this.t.get(t)) {
        .STRUCT(x) => { s = x; },
        default => { return false; },
    }
    match (a.kind) {
        .PATH(p&) => {
            val given = &p.segs.at(p.segs.len - 1).args;
            if (*given == null) {
                return false;
            }
            // (the arguments left out, last, take their defaults: std::vec<str>'s allocator)
            val gas = &(*given).value;
            if (gas.len > this.si(s).args.len) {
                return false;
            }
            for (i) in 0..gas.len {
                // (copied: gives_views may make new struct instances, moving si's storage)
                val g = *this.si(s).args.at(i);
                match (g) {
                    .TY(x) => {
                        match (*gas.at(i)) {
                            .TYPE(ga&) => {
                                if (this.gives_views(x, ga, env)) {
                                    return true;
                                }
                            },
                            default => {},
                        }
                    },
                    default => {},
                }
            }
        },
        default => {},
    }
    return false;
}

// the place a reference argument points at: what `&e` takes, or the reference local (or field chain
// of one) e passed on, else null
attach fn arg_place(this: checker&, e: expr&) -> place_at? {
    match (e.kind) {
        .UNARY(op, x) => {
            if (op == unop::ADDR) {
                return this.place_at_of(x);
            }
            return null;
        },
        default => {},
    }
    return this.place_at_of(e);
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
