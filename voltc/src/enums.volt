// Enums and error sets: a port of bootstrap/check/enums.rs. Payload-less enums are plain integers (their
// backing type); enums with payloads are { tag; union { v0; v1; ... } }. Error variants get
// program-wide codes, so any error set converts to `error` (any) by taking the code.
use std::mem;

// the enum type for decl d with these generic args, creating the instance (names, values, tag type) on
// first use; payload types wait for enum_payloads
attach fn enum_inst(this: checker&, d: u32, args: std::vec<gval>, span: span) -> compile_error!u32 {
    val key = this.inst_key(d, &args);
    val have = this.enum_ids.get(key.as_str());
    if (have) {
        return this.t.intern(tyk::ENUM(*have));
    }
    val dns = this.dl(d).ns;
    var ed: enum_decl* = null;
    match (this.item_of(d).kind) {
        .ENUM(x&) => { ed = x; },
        default => {},
    }
    val e = ed ?? return fails(span, "not an enum");
    val env = this.inst_env(dns, this.gparams_of(d), &args);
    var full = this.ns_path(dns, "::");
    if (full.len() > 0) {
        full.append("::");
    }
    full.append(e.name);
    val name = this.inst_name(full.as_str(), &args);
    var base = S("v_");
    base.append(e.name);
    val c_name = this.fresh_c_name(base.as_str());
    var names: std::vec<str> = {};
    for (v&) in e.variants.items() {
        put(&names, v.name);
    }
    var values: std::vec<i128> = {};
    if (e.is_error) {
        for (v&) in e.variants.items() {
            if (v.value != null) {
                return fails(v.span, "error variants can't set values");
            }
            // a hash of the qualified name: the same code in every C unit, whatever the order
            // (0 means ok and 1 is the plain `error`)
            var qual = S(name);
            qual.append("::");
            qual.append(v.name);
            var code = fnv32(qual.as_str());
            while (code < 2) {
                var again = copy qual;
                again.append_uint(@cast<u64>(code));
                code = fnv32(again.as_str());
            }
            val q = this.intern(move qual);
            val at = this.error_index(code);
            if (at < this.error_names.len && this.error_names.at(at).code == code) {
                val other = this.error_names.at(at).qual;
                if (other != q) {
                    return fail(v.span, fmt2("error {} has the same code as {}; rename one", S(q), S(other)));
                }
                *this.error_names.at(at) = { code: code, name: v.name, qual: q };
            } else {
                insert_at(&this.error_names, at, { code: code, name: v.name, qual: q });
            }
            put(&values, @cast<i128>(code));
        }
    } else {
        var next: i128 = 0;
        for (v&) in e.variants.items() {
            var x = next;
            if (v.value) {
                x = try this.const_int(&v.value, env);
            }
            for (y&) in values.items() {
                if (*y == x) {
                    return fail(v.span, fmt("two variants have the value {}", num(x)));
                }
            }
            put(&values, x);
            next = x + 1;
        }
    }
    // the tag type: an explicit backing type must hold every value; without one, the smallest int that does
    var tag = int_ty::I128;
    if (e.is_error) {
        tag = int_ty::U32;
    } else if (e.backing) {
        val bt = try this.resolve_type(&e.backing, env);
        tag = this.t.int_of(bt) ?? return fails(e.backing.span, "an enum's backing type must be an integer");
    } else {
        var lo: i128 = 0;
        var hi: i128 = 0;
        for (i) in 0..values.len {
            val x = *values.at(i);
            if (i == 0 || x < lo) {
                lo = x;
            }
            if (i == 0 || x > hi) {
                hi = x;
            }
        }
        val order: int_ty[] = { int_ty::U8, int_ty::I8, int_ty::U16, int_ty::I16, int_ty::U32, int_ty::I32, int_ty::U64, int_ty::I64 };
        for (k) in order {
            if (k.fits(lo) && k.fits(hi)) {
                tag = k;
                break;
            }
        }
    }
    for (i) in 0..values.len {
        val x = *values.at(i);
        if (!tag.fits(x)) {
            return fail(e.variants.at(i).span, fmt2("{} doesn't fit in the backing type {}", num(x), S(tag.name())));
        }
    }
    var has_payload = false;
    for (v&) in e.variants.items() {
        if (v.payload != null) {
            has_payload = true;
        }
    }
    val id = @cast<u32>(this.enums.len);
    put(&this.enums, bx<enum_info>({ decl: d, family: d, args: move args, env: env, name: name, c_name: c_name, tag: tag, is_error: e.is_error, has_payload: has_payload, names: move names, values: move values }));
    this.enum_ids.put(this.intern(move key), id);
    return this.t.intern(tyk::ENUM(id));
}

// where code is (or goes) in the sorted error table
attach fn error_index(this: checker&, code: u32) -> usize {
    var i: usize = 0;
    while (i < this.error_names.len && this.error_names.at(i).code < code) {
        i += 1;
    }
    return i;
}

// inserts x at index at, shifting the rest up
<T: type>
fn insert_at(v: std::vec<T>&, at: usize, x: T) -> void {
    put(v, move x);
    var i = v.len - 1;
    while (i > at) {
        swap(v.at(i), v.at(i - 1));
        i -= 1;
    }
}

// each variant's payload type (null = no payload, including a void one), resolved once and cached
attach fn enum_payloads(this: checker&, eid: u32, span: span) -> compile_error!(std::vec<u32?>&) {
    val info = this.ei(eid);
    if (info.has_payloads) {
        return &info.payloads;
    }
    val decl = info.decl;
    val env = info.env;
    var ed: enum_decl* = null;
    match (this.item_of(decl).kind) {
        .ENUM(x&) => { ed = x; },
        default => {},
    }
    val e = ed ?? return fails(span, "not an enum");
    // placeholder so a payload behind a reference to this enum doesn't loop
    for (v&) in e.variants.items() {
        put(&info.payloads, null);
    }
    info.has_payloads = true;
    var out: std::vec<u32?> = {};
    for (v&) in e.variants.items() {
        if (v.payload) {
            val t = try this.resolve_type(&v.payload, env);
            if (t == VOID) {
                put(&out, null);
            } else {
                put(&out, t);
            }
        } else {
            put(&out, null);
        }
    }
    this.ei(eid).payloads = move out;
    return &this.ei(eid).payloads;
}

attach fn enum_of(this: checker&, t: u32) -> u32? {
    match (*this.t.get(t)) {
        .ENUM(e) => { return e; },
        default => { return null; },
    }
}

attach fn variant_index(this: checker&, eid: u32, name: str) -> usize? {
    val ns = &this.ei(eid).names;
    for (i) in 0..ns.len {
        if (*ns.at(i) == name) {
            return i;
        }
    }
    return null;
}

// the tag (or error code) of an enum value
attach fn tag_of(this: checker&, eid: u32, c: u32) -> u32 {
    val info = this.ei(eid);
    if (info.has_payload) {
        return this.ir.field(c, 0, int_id(info.tag));
    }
    return c;
}

// the tag constant of variant idx
attach fn tag_const(this: checker&, eid: u32, idx: usize) -> u32 {
    val info = this.ei(eid);
    return this.ir.int(*info.values.at(idx), int_id(info.tag));
}

// build variant idx of enum t from optional payload args
attach fn make_variant(this: checker&, t: u32, idx: usize, args: std::vec<expr>*, span: span) -> compile_error!tval {
    val eid = this.enum_of(t) ?? return fails(span, "not an enum");
    if (this.opts.lsp) {
        this.lsp_variant_use(eid, idx, span);
    }
    val pt = *(try this.enum_payloads(eid, span)).at(idx);
    val info = this.ei(eid);
    val vname = *info.names.at(idx);
    val value = *info.values.at(idx);
    val has_payload = info.has_payload;
    var payload: tval? = null;
    if (pt == null) {
        if (args != null && (args ?? return fails(span, "")).len > 0) {
            return fail(span, fmt("{} has no payload", S(vname)));
        }
    } else {
        val a = args ?? return fail(span, fmt2("{} needs a payload: {}(...)", S(vname), S(vname)));
        val p = pt ?? VOID;
        var tuple_n: usize = 0;
        match (*this.t.get(p)) {
            .TUPLE(ts, names) => { tuple_n = ts.len; },
            default => {},
        }
        if (tuple_n > 1 && a.len == tuple_n) {
            val v = try this.tuple(a, p, span);
            payload = try this.coerce(v, p, span);
        } else if (a.len == 1) {
            val v = try this.expr(a.at(0), p);
            payload = try this.take_into(v, p, a.at(0).span);
        } else {
            return fail(span, fmt("{} takes one payload value", S(vname)));
        }
    }
    if (!has_payload) {
        return vpure(t, this.ir.int(value, t));
    }
    var inits: std::vec<field_init> = {};
    put(&inits, { field: 0, value: this.tag_const(eid, idx) });
    if (payload) {
        val pv = payload;
        put(&inits, { field: @cast<u32>(idx) + 1, value: pv.c });
        var r = vnew(t, this.ir.node(ir_kind::AGG(move inits), t));
        r.pure = pv.pure;
        return r;
    }
    return vpure(t, this.ir.node(ir_kind::AGG(move inits), t));
}

// the error code inside an error union value
attach fn eu_code(this: checker&, eu_ty: u32, c: u32) -> u32 {
    var e = ANYERR;
    match (*this.t.get(eu_ty)) {
        .ERR_UNION(x, t) => { e = x; },
        default => {},
    }
    val errv = this.ir.field(c, 0, e);
    val eid = this.enum_of(e);
    if (eid) {
        return this.tag_of(eid, errv);
    }
    return errv;
}

// the code of an error value (an error-set enum or `error`)
attach fn err_code(this: checker&, t: u32, c: u32) -> u32 {
    val eid = this.enum_of(t);
    if (eid) {
        return this.tag_of(eid, c);
    }
    return c;
}

// an error value's type: `error` or an error set
attach fn is_error_ty(this: checker&, t: u32) -> bool {
    if (t == ANYERR) {
        return true;
    }
    val eid = this.enum_of(t) ?? return false;
    return this.ei(eid).is_error;
}

// volt_err_name(code): the variant name of an error code, for printing
attach fn error_table(this: checker&) -> void {
    val f = this.err_name_fn();
    val c = this.ir.node(ir_kind::LOCAL(0), U32);
    var cases: std::vec<case_arm> = {};
    for (e&) in this.error_names.items() {
        val s = this.ir.node(ir_kind::CSTR(e.name), CSTR);
        put(&cases, { value: @cast<i128>(e.code), body: this.ir.ret(s) });
    }
    val dflt = this.ir.ret(this.ir.node(ir_kind::CSTR("<error>"), CSTR));
    val sw = this.ir.node(ir_kind::SWITCH(c, move cases, dflt), NEVER);
    this.ir.fn_at(f).body = this.ir.block(nodes(sw));
    put(&this.ir.bodies, f);
}
