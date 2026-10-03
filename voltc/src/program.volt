// The whole program: roots, function bodies, globals, the C main wrapper. A port of the program
// part of bootstrap/check/mod.rs. The result is checker.ir, which a backend turns into code.
use std::mem;

// check the whole program from its roots (main, and every non-generic fn) into this.ir
attach fn program(this: checker&) -> compile_error!void {
    val lib = this.opts.lib;
    var main: u32? = null;
    if (lib == null) {
        val l = this.ns(0).names.get("main");
        if (l) {
            main = *this.list(*l).at(0);
        } else if (!this.opts.lsp) { // the language server checks a file being written, or a library's
            return with_help(fails(NO_SPAN, "no main function"), S("a program starts at fn main() -> void { ... }"));
        }
    }
    var mi: u32? = null;
    if (main) {
        val m = main;
        val i = try this.fn_inst(m, {}, this.item_of(m).span);
        this.use_fn(i);
        mi = i;
    }
    // every non-generic fn is a root, used or not, so its body is always checked (templates are
    // checked per instance, like C++); exported fns have to exist for C anyway. A library only
    // roots its own package
    for (di) in 0..this.decls.len {
        val d = @cast<u32>(di);
        val f = this.fn_decl_of(d) ?? continue;
        var in_trait = false;
        val parent = this.dl(d).parent;
        if (parent) {
            match (this.item_of(parent).kind) {
                .TRAIT(n, fs) => { in_trait = true; },
                default => {},
            }
        }
        var mine = lib == null;
        if (!mine) {
            val pkg = this.pkg_of(d);
            mine = pkg != null && (pkg ?? "") == (lib ?? "");
        }
        if (mine && (f.is_export || (f.body != null && f.spec == null && !f.is_comptime && !in_trait && this.fn_generics(d).len == 0))) {
            val i = this.fn_inst(d, {}, this.item_of(d).span) catch |e| {
                put(&this.errors, err_diag(&e));
                continue;
            };
            this.use_fn(i);
        }
    }
    // a library defines every global of its package: a template that a program instantiates may
    // use one the library's own code never does
    if (lib != null) {
        for (di) in 0..this.decls.len {
            val d = @cast<u32>(di);
            var is_global = false;
            match (this.item_of(d).kind) {
                .GLOBAL(l) => { is_global = true; },
                default => {},
            }
            val pkg = this.pkg_of(d);
            if (is_global && pkg != null && (pkg ?? "") == (lib ?? "")) {
                this.global(d, this.item_of(d).span) catch |e| {
                    put(&this.errors, err_diag(&e));
                    continue;
                };
            }
        }
    }
    this.check_traits();
    // an error stops only its own function: the others are still checked, so one run finds
    // every independent error (--error-limit picks how many are shown)
    while (this.queue.len > 0) {
        val i = this.queue.pop() ?? 0;
        val depth = this.ct.len;
        this.gen_fn(i) catch |e| {
            while (this.ct.len > depth) {
                this.ct.pop();
            }
            this.ct_flow = null;
            put(&this.errors, err_diag(&e));
        };
    }
    // what can't change, lent to fns that write through it (lends.volt)
    this.check_lends();
    this.warn_var_params();
    if (this.errors.len > 0) {
        return; // compile() reports this.errors
    }
    // the guard symbol ties a program to the exact library build it was checked against
    val u8t = U8;
    for (g&) in this.opts.guards.items() {
        if (lib != null && (lib ?? "") == g.pkg) {
            put(&this.ir.globals, { name: g.sym, ty: u8t, init: this.ir.int(0, u8t), mutable: false, link: linkage::EXPORTED });
        } else {
            var linked = false;
            for (x&) in this.opts.linked.items() {
                if (*x == g.pkg) {
                    linked = true;
                }
            }
            if (linked) {
                put(&this.ir.globals, { name: g.sym, ty: u8t, init: null, mutable: false, link: linkage::EXTERNAL });
                val gi = @cast<u32>(this.ir.globals.len - 1);
                val at = this.ir.conv(this.ir.addr(this.ir.node(ir_kind::GLOBAL(gi), u8t), this.t.ref_to(u8t)), VOIDPTR);
                var rn = S(g.sym);
                rn.append("_ref");
                put(&this.ir.globals, { name: this.intern(move rn), ty: VOIDPTR, init: at, mutable: false, link: linkage::STATIC, keep: true });
            }
        }
    }
    if (mi) {
        try this.main_wrapper(main ?? 0, mi);
    }
    try this.check_frame_cycles();
    this.error_table();
}

// int main(int argc, char **argv): set up the runtime, run v_main, turn its result into an exit code
attach fn main_wrapper(this: checker&, main: u32, mi: u32) -> compile_error!void {
    val ret = this.fi(mi).ret;
    val span = this.item_of(main).span;
    val argv_t = this.t.intern(tyk::PTR(this.t.intern(tyk::PTR(U8))));
    var irf: ir_fn = { name: "main", params: {}, ret: I32, link: linkage::EXPORTED, used: true, origin: span, about: "the C entry point: runs main" };
    put(&irf.locals, { name: "argc", ty: I32 });
    put(&irf.locals, { name: "argv", ty: argv_t });
    put(&irf.params, 0);
    put(&irf.params, 1);
    put(&this.ir.fns, bx(move irf));
    val f = @cast<u32>(this.ir.fns.len - 1);
    this.cx = new_cx(I32, 0, f);
    val call = this.call_fn(this.fi(mi).ir, {}, ret);
    // main's result as an int
    var body: std::vec<u32> = {};
    var code: u32 = 0;
    if (ret == VOID) {
        put(&body, call);
        code = this.ir.int(0, I32);
    } else if (this.t.int_of(ret) != null) {
        code = this.ir.conv(call, I32);
    } else {
        var t = VOID;
        var ok = false;
        match (*this.t.get(ret)) {
            .ERR_UNION(e, x) => {
                t = x;
                ok = true;
            },
            default => {},
        }
        if (!ok || (t != VOID && this.t.int_of(t) == null)) {
            return fails(span, "main must return void or an integer");
        }
        val r = this.new_ir_local("_r", ret);
        val c = this.new_ir_local("_code", I32);
        put(&body, this.ir.decl(r.id, call));
        val ec = this.eu_code(ret, r.c);
        val name = this.call_fn(this.err_name_fn(), nodes(ec), CSTR);
        val msg = this.ir.rt_call("volt_dprintf", nodes3(this.ir.int(2, I32), this.ir.node(ir_kind::CSTR("error: %s\n"), CSTR), name), I32);
        var good = this.ir.int(0, I32);
        if (t != VOID) {
            good = this.ir.conv(this.ir.field(r.c, 1, t), I32);
        }
        put(&body, this.ir.decl(c.id, null));
        put(&body, this.ir.if_(this.nonzero(ec), this.ir.block(nodes2(msg, this.ir.assign(c.c, this.ir.int(1, I32)))), this.ir.assign(c.c, good)));
        code = c.c;
    }
    if (this.fi(mi).params.len > 0) {
        return fails(span, "main takes no parameters");
    }
    var all: std::vec<u32> = {};
    val argc_g = this.runtime_global("volt_argc", I32);
    val argv_g = this.runtime_global("volt_argv", argv_t);
    put(&all, this.ir.assign(argc_g, this.ir.node(ir_kind::LOCAL(0), I32)));
    put(&all, this.ir.assign(argv_g, this.ir.node(ir_kind::LOCAL(1), argv_t)));
    for (s&) in body.items() {
        put(&all, *s);
    }
    if (this.opts.leak_check && !this.opts.release) {
        val rc = this.new_ir_local("_rc", I32);
        put(&all, this.ir.decl(rc.id, code));
        val live = this.runtime_global("volt_live_allocs", USIZE);
        val leak = this.ir.rt_call("volt_dprintf", nodes3(this.ir.int(2, I32), this.ir.node(ir_kind::CSTR("leak: %zu allocation(s) never freed\n"), CSTR), live), I32);
        put(&all, this.ir.if_(this.nonzero(live), this.ir.block(nodes2(leak, this.ir.ret(this.ir.int(102, I32)))), null));
        put(&all, this.ir.ret(rc.c));
    } else {
        put(&all, this.ir.ret(code));
    }
    this.ir.fn_at(f).body = this.ir.block(move all);
    put(&this.ir.order, f);
    put(&this.ir.bodies, f);
}

// a global the runtime defines (declared by the prelude)
attach fn runtime_global(this: checker&, name: str, t: u32) -> u32 {
    for (i) in 0..this.ir.globals.len {
        if (this.ir.globals.at(i).name == name) {
            return this.ir.node(ir_kind::GLOBAL(@cast<u32>(i)), t);
        }
    }
    put(&this.ir.globals, { name: name, ty: t, init: null, mutable: true, link: linkage::EXTERNAL, header: true });
    return this.ir.node(ir_kind::GLOBAL(@cast<u32>(this.ir.globals.len - 1)), t);
}

// Check a fn instance's body into its ir fn. Parameters become locals of the outermost scope; an
// async fn's body becomes the step function of its frame (gen_async).
// an error in a template's body belongs to one instance: say which, and where each template on the
// way asked for the next, back to the first caller that isn't a template (8 at most; a span that
// repeats is labelled once)
attach fn instantiation_chain(this: checker&, idx: u32, e: compile_error) -> compile_error {
    var d = move e;
    var at: u32? = idx;
    var last: span? = null;
    for (k) in 0..8 {
        val i = at ?? break;
        val f = this.fi(i);
        if (this.fn_generics(f.decl).len == 0) {
            break;
        }
        var repeat = false;
        if (last) {
            repeat = last.file == f.used_at.file && last.lo == f.used_at.lo && last.hi == f.used_at.hi;
        }
        if (!repeat) {
            d = with_label(move d, f.used_at, fmt("{} is instantiated here", S(f.name)));
        }
        last = f.used_at;
        at = f.used_in;
    }
    return move d;
}

attach fn gen_fn(this: checker&, idx: u32) -> compile_error!void {
    val inst = this.fi(idx);
    val decl = inst.decl;
    val it = this.item_of(decl);
    val f = this.fn_decl_of(decl) ?? return fails(it.span, "not a function");
    if (f.body == null) {
        return fails(it.span, "no body");
    }
    val body = &f.body.value;
    val irf = inst.ir;
    val ret = inst.ret;
    this.cx = new_cx(ret, inst.env, irf);
    this.cx.body = body_key(BODY_FN, idx);
    if (f.is_async) {
        if (f.extern_abi != null || f.is_export || inst.c_name == "v_main") {
            return fails(it.span, "main, extern and export fns can't be async");
        }
        if (ret == NEVER) {
            return fails(it.span, "an async fn can't return never");
        }
        val step = this.async_step_fn(idx);
        this.cx.irf = step;
        this.cx.frame = idx;
        this.cx.frame_ptr = this.ir.node(ir_kind::LOCAL(0), this.t.ref_to(this.t.intern(tyk::FRAME(idx))));
        this.frame_of(idx); // it has a frame, even with nothing in it
    }
    var stmts: std::vec<u32> = {};
    var param_cs: std::vec<u32> = {};
    var k: usize = 0;
    for (i) in 0..inst.params.len {
        val p = *inst.params.at(i);
        if (p.is_comptime) {
            continue;
        }
        var c: u32 = 0;
        if (p.ty == VOID) {
            c = this.ir.zero(VOID); // an empty pack: nothing to pass
        } else if (f.is_async) {
            // frame fields share one struct with the locals, so they take unique ids too
            c = this.slot(p.name, p.ty);
            put(&param_cs, c);
            k += 1;
        } else {
            val lid = *this.ir.fn_at(irf).params.at(k);
            c = this.ir.node(ir_kind::LOCAL(lid), p.ty);
            k += 1;
        }
        var l: local = { c: c, ty: p.ty, mutable: p.mutable, root: p.name, param: true, own: c };
        // var this takes the receiver by value (it consumes it): that's what its var is for
        if (p.mutable && p.name != "this") {
            put(&this.cx.var_params, { c: c, name: p.name });
        }
        if (this.holds(p.ty)) {
            val rv: reach = { k: @cast<u32>(i), off: 0 }; // what it reaches is parameter i's memory
            l.via = rv;
        }
        if (try this.needs_drop(p.ty)) {
            // by-value params are owned by the callee
            val flag = this.flag_for(c);
            put(&stmts, this.decl_at(flag, this.ir.boolean(true)));
            val d = try this.drop_fn(p.ty);
            put(&this.cx.scopes.at(0).exits, exit::DROP(c, d, flag));
            l.flag = flag;
        }
        this.cx.scopes.at(0).vars.put(p.name, l);
        if (this.opts.lsp) {
            this.lsp_param(decl, p.name, c, p.ty);
        }
    }
    val saved_fn = this.gen_fn_idx;
    this.gen_fn_idx = idx;
    val bc = this.block_code(body) catch |e| {
        this.gen_fn_idx = saved_fn;
        return this.instantiation_chain(idx, copy e);
    };
    this.gen_fn_idx = saved_fn;
    this.note_var_params(decl, f);
    var div = bc.div;
    put(&stmts, bc.c);
    if (!div && this.cx.scopes.at(0).exits.len > 0) {
        // params: deleted when the body finishes without returning
        for (x&) in (try this.scope_exit_code(0, 0, false)).items() {
            put(&stmts, *x);
        }
    }
    if (!div) {
        match (*this.t.get(ret)) {
            .ERR_UNION(e, t) => {
                if (t == VOID) {
                    put(&stmts, this.fn_exit(this.ir.zero(ret), {}, this.ret_slot()));
                    div = true;
                }
            },
            default => {},
        }
    }
    if (!div && ret != VOID) {
        return fail(body.span, fmt2("'{}' can reach its end without returning a {}", S(f.name), this.ty_name(ret)));
    }
    if (f.is_async) {
        if (!div) {
            put(&stmts, this.fn_exit(null, {}, this.ret_slot()));
        }
        return this.gen_async(idx, this.ir.block(move stmts), &param_cs);
    }
    this.ir.fn_at(irf).body = this.ir.block(move stmts);
    put(&this.ir.bodies, irf);
}

// check a whole program: collect every file's items, then generate from the roots
// how many errors a run reports before it stops checking

// check the program: afterwards c.errors holds its errors (none: c.ir is the program) and c.warnings
// its warnings
fn compile(files: std::vec<source_file>&, asts: std::vec<std::vec<item>>&, o: opts) -> std::box<checker> {
    var c = bx(new_checker(files, move o));
    var ok = true;
    for (a&) in asts.items() {
        c.collect(a, 0) catch |e| {
            put(&c.errors, err_diag(&e));
            ok = false;
            break;
        };
    }
    if (ok) {
        c.program() catch |e| {
            put(&c.errors, err_diag(&e));
        };
    }
    return move c;
}

// a run's diagnostics in source order, each once (an error in a shared template instance can come
// up twice)
// ponytail: the dedupe and sort_diags are O(n^2) in the errors found (no longer capped at 20);
// fine for hundreds, switch to a hashed dedupe and a merge sort if generated code ever has thousands
fn all_diags(c: checker&) -> std::vec<diag> {
    var out: std::vec<diag> = {};
    for (w&) in c.warnings.items() {
        put(&out, copy *w);
    }
    for (e&) in c.errors.items() {
        var seen = false;
        for (d&) in out.items() {
            if (same_span(d.span, e.span) && d.msg.as_str() == e.msg.as_str()) {
                seen = true;
            }
        }
        if (!seen) {
            put(&out, copy *e);
        }
    }
    sort_diags(&out);
    return move out;
}

// a stable insertion sort by (file, lo), like Rust's sort_by_key
fn sort_diags(out: std::vec<diag>&) -> void {
    for (x) in 1..out.len {
        var j = x;
        while (j > 0 && (out.at(j - 1).span.file > out.at(j).span.file || (out.at(j - 1).span.file == out.at(j).span.file && out.at(j - 1).span.lo > out.at(j).span.lo))) {
            val t = @read(out.at(j));
            @write(out.at(j), @read(out.at(j - 1)));
            @write(out.at(j - 1), t);
            j -= 1;
        }
    }
}

// ---------- traits and attach blocks ----------

// a trait's fns are signatures only; each attach block names a trait it may use and holds every
// fn the trait requires, taking as many arguments
attach fn check_traits(this: checker&) -> void {
    for (d) in 0..this.decls.len {
        val id = @cast<u32>(d);
        match (this.item_of(id).kind) {
            .TRAIT(n, fs&) => {
                this.check_trait(fs) catch |e| {
                    put(&this.errors, err_diag(&e));
                    continue;
                };
            },
            .ATTACH(tr, target, fs) => {
                this.check_attach_block(id) catch |e| {
                    put(&this.errors, err_diag(&e));
                    continue;
                };
            },
            default => {},
        }
    }
}

attach fn check_trait(this: checker&, fns: std::vec<item>&) -> compile_error!void {
    for (f&) in fns.items() {
        match (f.kind) {
            .FN(fd&) => {
                if (fd.body != null) {
                    return fails(this.name_span(f.span, fd.name), "a trait fn is only a signature; its body goes in each attach block");
                }
            },
            default => {},
        }
    }
}

attach fn check_attach_block(this: checker&, b: u32) -> compile_error!void {
    val ns = this.decls.at(@cast<usize>(b)).ns;
    match (this.item_of(b).kind) {
        .ATTACH(tr&, target&, fs&) => {
            match (tr.kind) {
                .PATH(p&) => {
                    val r = this.bound_trait(tr, ns) ?? return this.not_a_trait(tr.span, ns, p);
                    try this.visible(r.decl, tr.span);
                    return this.check_required(r.decl, fs, tr.span);
                },
                default => {
                    return fails(tr.span, "an attach block names a trait: attach t_name -> type { ... }");
                },
            }
        },
        default => {},
    }
}

// the error for an attach block's trait path that names no trait
attach fn not_a_trait(this: checker&, span: span, ns: u32, p: path&) -> compile_error {
    var f: found? = null;
    if (p.segs.len == 1) {
        f = this.lookup(ns, p.segs.at(0).name);
    } else {
        f = this.lookup_path_ns(ns, p);
    }
    match (f ?? found::NS(0)) {
        .DECLS(l) => {
            if (f != null) {
                return fail(span, fmt("'{}' isn't a trait", S(p.last())));
            }
        },
        default => {},
    }
    return this.unknown(span, "trait", ns, p, false);
}

// every fn trait tr declares is among fns (an attach block's, whose trait name is at), taking as
// many arguments
attach fn check_required(this: checker&, tr: u32, fns: std::vec<item>&, at: span) -> compile_error!void {
    match (this.item_of(tr).kind) {
        .TRAIT(tname, required&) => {
            for (r&) in required.items() {
                match (r.kind) {
                    .FN(rf&) => {
                        val wanted = this.name_span(r.span, rf.name);
                        // the block's fns of that name (overloads): one has to take the trait's arguments
                        var first: item* = null;
                        var ok = false;
                        for (f&) in fns.items() {
                            match (f.kind) {
                                .FN(g&) => {
                                    if (g.name == rf.name) {
                                        if (first == null) {
                                            first = f;
                                        }
                                        if (arg_count(g) == arg_count(rf)) {
                                            ok = true;
                                        }
                                    }
                                },
                                default => {},
                            }
                        }
                        if (first == null) {
                            val msg = fmt2("this attach block is missing fn '{}', which trait '{}' requires", S(rf.name), S(tname));
                            return with_label(fail(at, msg), wanted, S("required here"));
                        }
                        if (!ok) {
                            match (first->kind) {
                                .FN(g&) => {
                                    val msg = fmt4("'{}' takes {} here but {} in trait '{}'", S(g.name), args_text(arg_count(g)), args_text(arg_count(rf)), S(tname));
                                    return with_label(fail(this.name_span(first->span, g.name), msg), wanted, S("declared here"));
                                },
                                default => {},
                            }
                        }
                    },
                    default => {},
                }
            }
        },
        default => {},
    }
}

// how many arguments a call to f passes: its parameters besides this
fn arg_count(f: fn_decl&) -> u64 {
    var n: u64 = 0;
    for (q&) in f.params.items() {
        if (q.name != "this") {
            n += 1;
        }
    }
    return n;
}

// n arguments, in words
fn args_text(n: u64) -> std::string {
    if (n == 0) {
        return S("no arguments");
    }
    if (n == 1) {
        return S("1 argument");
    }
    return fmt("{} arguments", unum(n));
}
