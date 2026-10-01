// The checker: a port of bootstrap/check (types, templates, ownership, comptime, async), lowering each
// function instance to IR (ir.volt) as it checks it. This file: its state, declarations, lookup.
use std::mem;

struct source_file {
    name: str;
    text: str;
}

// a collected item: the namespace and file it was declared in, and its enclosing trait or attach block
struct decl {
    item: item&;
    ns: u32;
    file: u32;
    parent: u32?; // enclosing trait or attach block
}

// a namespace: its declared names (fn overloads and specializations share one), child namespaces
// and `use` imports
struct ns_info {
    path: std::vec<str> = {};
    parent: u32? = null;
    names: std::map<str, u32> = {}; // name -> decl list (checker.lists)
    children: std::map<str, u32> = {};
    uses: std::vec<path&> = {}; // `use a::b::c;` makes c's members (or c itself) reachable as a::name
}

// a generic argument's value: a type, an integer, a type pack (T...) or a string
enum gval {
    TY: u32,
    INT: i128,
    PACK: u32, // a type list (checker.lists)
    STR: str,
}

struct gbind {
    name: str;
    g: gval;
}

// what a template body sees: its namespace and the generic params bound so far (searched from the end)
struct env {
    ns: u32;
    generics: std::vec<gbind> = {};
}

// a resolved struct field; fallback is its initializer from the declaration, for literals that
// leave the field out
struct field_info {
    name: str;
    ty: u32;
    fallback: expr*;
}

// one struct instance (a struct decl with one set of generic args); its fields resolve on first use
// (struct_fields, which sets has_fields)
struct struct_info {
    decl: u32;
    family: u32; // the primary (unspecialized) decl
    args: std::vec<gval>;
    env: u32;
    name: str;
    c_name: str;
    fields: std::vec<field_info> = {};
    has_fields: bool = false;
    resolving: bool = false;
    owns_field: str? = null; // @owns("field"): an owning pointer to owns_ty through that field
    owns_ty: u32 = 0;
}

// one enum or error set instance; payload types resolve on first use (enum_payloads)
struct enum_info {
    decl: u32;
    family: u32;
    args: std::vec<gval>;
    env: u32;
    name: str;
    c_name: str;
    tag: int_ty;
    is_error: bool;
    has_payload: bool;
    names: std::vec<str>;
    values: std::vec<i128>;
    payloads: std::vec<u32?> = {};
    has_payloads: bool = false;
}

// a trait used as a type: a tagged union of the types attached to it (members)
struct union_info {
    trait_decl: u32;
    name: str;
    c_name: str;
    members: std::vec<u32> = {};
}

// a closure's lowered form: the struct of its captures and the fns that run it
struct closure_info {
    c_name: str;
    fn_ir: u32;     // R f(struct&, params...)
    erased_ir: u32; // R f(void*, params...), for fn(...) values
    caps: std::vec<cap_field>;
    params: std::vec<u32>;
    ret: u32;
}

struct cap_field {
    name: str;
    ty: u32;
}

struct param_info {
    name: str;
    ty: u32;
    mutable: bool;
    fallback: expr*;
    is_comptime: bool; // known at compile time: part of the instance, not a real parameter
}

// one fn instance: a decl with one set of generic args, its resolved signature and C name. Its body
// is checked later (gen_fn), once something uses it
struct fn_inst {
    decl: u32;
    name: str;
    pack: bool; // last param collects the rest of the args as a tuple
    env: u32;
    c_name: str;
    params: std::vec<param_info>;
    ret: u32;
    c_varargs: bool;
    // `@intrinsic("name")`: a compiler builtin, or a prelude C function when the name starts with volt_
    intrinsic: str?;
    ir: u32; // its ir_fn
    used_at: span; // where the instance was first asked for (errors in a template's body point back to it)
}

// a receiver temporary kept alive (see fn_cx.kept): its slot, type and live flag
struct kept_temp {
    c: u32;
    ty: u32;
    flag: u32;
}

// a local variable in scope: its place, type and ownership bookkeeping
struct local {
    c: u32; // its place (an ir node)
    ty: u32;
    mutable: bool;
    orig_c: u32? = null; // narrowed optional: the original variable
    orig_ty: u32 = 0;
    flag: u32? = null;   // owned local that needs delete: its "still live" flag (a place)
    loops: usize = 0;    // loops around the declaration
}

// a cleanup registered in a scope: a defer, or deleting an owned local if its flag says it's still live
enum exit {
    DEFER: (expr&, bool), // expr, errdefer only
    DROP: (u32, u32, u32), // place, drop fn (ir fn), flag place
}

// a comptime var/val in a scope: its current value
struct const_entry {
    value: cval;
    mutable: bool;
}

// one block's locals, comptime constants and the cleanups that run when it ends
struct scope {
    vars: std::map<str, local> = {};
    consts: std::map<str, const_entry> = {}; // comptime var/val
    exits: std::vec<exit> = {}; // run in reverse when the scope ends
    barrier: bool = false;      // locals above this aren't visible (default args)
}

// a loop or labeled block being checked: the labels break/continue jump to, and where break values go
struct loop_cx {
    label: str?;
    is_block: bool;
    brk: u32;             // label id
    cont: u32?;           // label id
    result: u32?;         // place for break values
    break_ty: u32?;
    has_break: bool = false;
    depth: usize;         // scope depth outside the loop
    moved_at_break: idset = {}; // moved when some break left the loop
    can_value: bool = false;    // a break may give a value (loop, labeled block)
    result_id: u32 = 0;         // the local holding it
}

// the state of the fn instance being checked; replaced for each instance (and swapped out while a
// global's initializer is checked)
struct fn_cx {
    ret: u32;
    env: u32;
    irf: u32; // the ir_fn being built (its locals)
    scopes: std::vec<scope> = {};
    loops: std::vec<loop_cx> = {};
    next_id: u32 = 0;
    moved: idset = {};         // locals (places) moved on some path so far
    move_sites: std::map<u32, span> = {}; // where each moved local was last moved (for messages)
    // the receiver temporaries a statement makes: they live to the end of the statement (a val's to
    // the end of its scope, a for loop's iterable's to the end of the loop), so a view into one
    // (`f().as_str()`, `f().items()`) stays valid. keeping is false where they're deleted at once
    keeping: bool = false;
    kept: std::vec<kept_temp> = {};
    keep_scope: usize = 0; // the scope whose exits delete them (early exits included)
    exiting: u32 = 0;          // inside a return/break value
    reassigning: u32? = null;  // `x = f(move x)`: x gets a new value right away
    frame: u32? = null;        // generating this async fn's step function
    frame_ptr: u32 = 0;        // its frame pointer (a place)
    suspends: std::vec<span> = {};
    suspend_labels: std::vec<u32> = {};
    no_suspend: u32 = 0;       // inside code where suspend can't go (defers)
    call_mode: bool = false;   // the call at call_span starts a frame (call_start) or is awaited
    call_span: span = {};
    call_start: bool = false;
    ret_local: local_ref? = null; // fn_exit's _ret
}

// a fresh fn context with its outermost scope, lowering into ir fn irf
fn new_cx(ret: u32, env: u32, irf: u32) -> fn_cx {
    var cx: fn_cx = { ret: ret, env: env, irf: irf };
    put(&cx.scopes, {});
    return move cx;
}

// A checked expression: its type and code. For void/never types the code is a statement.
struct tval {
    ty: u32;
    c: u32;
    lv: bool = false;      // a place
    mutable: bool = false; // may be assigned
    pure: bool = false;    // no side effects, safe to evaluate in any order
    lit: lit? = null;
    owner: str? = null;    // set when this is an owned local (so using it by value moves it)
}

// a literal's value, kept on a tval so the literal can still adapt to the type it ends up as
enum lit {
    INT: i128,
    FLOAT: f64,
    STR: str,
}

fn vnew(t: u32, c: u32) -> tval {
    return { ty: t, c: c };
}

fn vpure(t: u32, c: u32) -> tval {
    return { ty: t, c: c, pure: true };
}

// what a name resolves to: its decls (an overload set when there are several), or a namespace
enum found {
    DECLS: u32, // a decl list (checker.lists)
    NS: u32,
}

struct pkg_file {
    file: u32;
    pkg: str;
}

struct guard {
    pkg: str;
    sym: str;
}

// a --cfg setting: the package it's for (null: the program's own files) and KEY or KEY=VALUE
struct cfg_arg {
    pkg: str?;
    set: str;
}

// compiler options that change the generated code
struct opts {
    release: bool = false;
    leak_check: bool = false;
    runtime: bool = true;              // define the runtime in this unit
    pkg_files: std::vec<pkg_file> = {}; // file -> its package
    lib: str? = null;                   // building this package into a library, no main
    linked: std::vec<str> = {};         // packages whose non-generic code comes from a prebuilt library
    guards: std::vec<guard> = {};       // package -> guard symbol
    cfg: std::vec<cfg_arg> = {};        // --cfg, for @cfg
    pp_flags: std::vec<str> = {};       // the --cc flags the C preprocessor needs (-I, -D...)
    lsp: bool = false;                  // record names for the language server (lsp.volt)
}

// an error variant's code, its name and its qualified name (for volt_err_name)
struct error_name {
    code: u32;
    name: str;
    qual: str;
}

// a global as the checker sees it: its IR place, type, and whether it can be assigned
struct global_ref {
    c: u32; // the place
    ty: u32;
    mutable: bool;
}

// an extern or export fn's C symbol: the decl that claimed it, with its signature
struct c_symbol {
    decl: u32;
    params: std::vec<u32>;
    ret: u32;
}

struct frame_field {
    name: str;
    ty: u32;
}

// an async fn instance's frame: the params, locals and flags that live across suspends
struct fn_frame {
    fn_idx: u32;
    fields: std::vec<frame_field> = {};
}

// all compiler state: declarations, namespaces, instances, types, and the IR built so far
struct checker {
    files: std::vec<source_file>&;
    opts: opts;
    t: types;
    ir: ir_prog = {};
    names: interner = {};
    decls: std::vec<decl> = {};
    nss: std::vec<std::box<ns_info>> = {};
    lists: std::vec<std::box<std::vec<u32>>> = {}; // decl lists and type packs
    envs: std::vec<std::box<env>> = {};
    structs: std::vec<std::box<struct_info>> = {};
    struct_ids: std::map<str, u32> = {};
    enums: std::vec<std::box<enum_info>> = {};
    enum_ids: std::map<str, u32> = {};
    error_names: std::vec<error_name> = {}; // sorted by code
    attached: std::map<str, u32> = {}; // method name -> decl list
    attach_blocks: std::vec<u32> = {};
    unions: std::vec<std::box<union_info>> = {};
    union_ids: std::map<u32, u32> = {};
    fns: std::vec<std::box<fn_inst>> = {};
    fn_ids: std::map<str, u32> = {};
    family_count: std::map<u32, u32> = {};
    // per fn instance: used yet (use_fn)? queue: used ones whose bodies haven't been checked (gen_fn)
    used: std::vec<bool> = {};
    queue: std::vec<u32> = {};
    cx: fn_cx;
    global_c: std::map<u32, global_ref> = {};
    used_c_names: std::map<str, u32> = {};
    c_symbols: std::map<str, c_symbol> = {};
    // needs_drop's answer per type; hook_memo: hook's per (type, name); glue_names: per-type helper fns
    drop_memo: std::map<u32, bool> = {};
    hook_memo: std::map<str, i64> = {};
    glue_names: std::map<str, u32> = {};
    closures: std::vec<std::box<closure_info>> = {};
    // comptime interpreter call frames
    ct: std::vec<ct_frame> = {};
    ct_flow: flow? = null; // a return/break/continue leaving compile-time code (with a "<flow>" error)
    ct_steps: u64 = 0;
    // deprecated decls already warned about (once each)
    warned: idset = {};
    frames: std::vec<fn_frame> = {}; // async fn instance -> frame fields
    c_includes: std::vec<str> = {};
    c_imports: std::map<str, u32> = {}; // an imported C symbol shared by every import of it
    aliases: std::map<u32, u32> = {}; // an alias decl's type, once resolved
    importing_c: bool = false;          // collecting a C import's items
    owned_items: std::vec<std::box<item>> = {}; // items made by the checker (C imports)
    c_texts: std::vec<std::string> = {};  // preprocessed C headers the imported items' names point into
    // use cpp (cppimport.volt): the #include lines, the generated items, and the extern "C" wrappers
    // @cpp calls became (their C++ text, what each wraps, their ir fns)
    cpp_includes: std::vec<str> = {};
    cpp_items: std::vec<std::box<std::vec<item>>> = {};
    // use LANG (langimport.volt): what the program links for the imports (libraries, -l flags)
    link_flags: std::vec<std::string> = {};
    import_deps: std::vec<std::string> = {}; // the files they were made from (OUT.deps, for bolt)
    cpp_shims: std::vec<std::string> = {};
    cpp_shim_keys: std::map<str, u32> = {};
    cpp_shim_fns: std::vec<u32> = {};
    owned_exprs: std::vec<std::box<expr>> = {}; // expressions made by the checker
    warnings: std::vec<diag> = {}; // printed with the errors (or on their own when there are none)
    errors: std::vec<diag> = {};   // from functions already checked (the run goes on to the others)
    err_name: u32? = null; // volt_err_name's ir fn
    owned_tys: std::vec<std::box<ty>> = {};     // type expressions made by the checker
    owned_gargs: std::vec<std::box<garg>> = {};
    gparam_lists: std::vec<std::box<std::vec<gparam>>> = {};
    item_gparams: std::map<u32, u32> = {}; // decl -> its own generic params (gparam_lists)
    fn_gparams: std::map<u32, u32> = {};   // fn decl -> all its generic params
    recv_refs: std::map<u32, ty&> = {};    // method decl -> its synthesized receiver type T&
    async_irs: std::map<u32, async_ir> = {}; // async fn instance -> its step/await/run fns
    // the language server's index (lsp.volt), filled while checking when opts.lsp: every name used
    // (where, its declaration, what hover shows) and every local declared
    lsp_at: span = {}; // the statement declaring the next local (its name is written in it)
    lsp_refs: std::vec<lsp_ref> = {};
    lsp_locals: std::vec<lsp_local> = {};
    lsp_local_idx: std::map<u32, usize> = {}; // place -> its lsp_locals entry
}

fn new_checker(files: std::vec<source_file>&, o: opts) -> checker {
    var c: checker = { files: files, opts: move o, t: new_types(), cx: new_cx(VOID, 0, 0) };
    put(&c.nss, bx<ns_info>({}));
    put(&c.envs, bx<env>({ ns: 0 }));
    put(&c.error_names, { code: 1, name: "error", qual: "error" });
    // fn 0 of the IR is a placeholder for code checked outside any function (globals)
    put(&c.ir.fns, bx<ir_fn>({ name: "", params: {}, ret: VOID, link: linkage::STATIC }));
    return move c;
}

// ---------- small accessors ----------

attach fn ns(this: checker&, n: u32) -> ns_info& {
    return *this.nss.at(@cast<usize>(n));
}

attach fn env_at(this: checker&, e: u32) -> env& {
    return *this.envs.at(@cast<usize>(e));
}

attach fn si(this: checker&, s: u32) -> struct_info& {
    return *this.structs.at(@cast<usize>(s));
}

attach fn ei(this: checker&, e: u32) -> enum_info& {
    return *this.enums.at(@cast<usize>(e));
}

attach fn fi(this: checker&, f: u32) -> fn_inst& {
    return *this.fns.at(@cast<usize>(f));
}

attach fn ui(this: checker&, u: u32) -> union_info& {
    return *this.unions.at(@cast<usize>(u));
}

attach fn ci(this: checker&, c: u32) -> closure_info& {
    return *this.closures.at(@cast<usize>(c));
}

attach fn dl(this: checker&, d: u32) -> decl& {
    return this.decls.at(@cast<usize>(d));
}

attach fn item_of(this: checker&, d: u32) -> item& {
    return this.decls.at(@cast<usize>(d)).item;
}

attach fn list(this: checker&, l: u32) -> std::vec<u32>& {
    return *this.lists.at(@cast<usize>(l));
}

attach fn new_list(this: checker&, v: std::vec<u32>) -> u32 {
    put(&this.lists, bx(move v));
    return @cast<u32>(this.lists.len - 1);
}

// the decl list under name in a map of lists (empty if none)
attach fn named(this: checker&, m: std::map<str, u32>&, name: str) -> std::vec<u32> {
    val l = m.get(name);
    if (l) {
        return copy *this.list(*l);
    }
    return {};
}

attach fn new_env(this: checker&, e: env) -> u32 {
    put(&this.envs, bx(move e));
    return @cast<u32>(this.envs.len - 1);
}

attach fn intern(this: checker&, s: std::string) -> str {
    return this.names.intern(move s);
}

attach fn scope_top(this: checker&) -> scope& {
    return this.cx.scopes.at(this.cx.scopes.len - 1);
}

// a made-up expression that lives as long as the checker
attach fn keep_expr(this: checker&, e: expr) -> expr& {
    put(&this.owned_exprs, bx(move e));
    return *this.owned_exprs.at(this.owned_exprs.len - 1);
}

// the fn declaration of decl d, or null when d isn't a fn
attach fn fn_decl_of(this: checker&, d: u32) -> fn_decl* {
    match (this.item_of(d).kind) {
        .FN(f&) => { return f; },
        default => { return null; },
    }
}

// ---------- declarations ----------

// the child namespace `name` of parent, made on first use
attach fn ns_child(this: checker&, parent: u32, name: str) -> u32 {
    val c = this.ns(parent).children.get(name);
    if (c) {
        return *c;
    }
    var p = copy this.ns(parent).path;
    put(&p, name);
    put(&this.nss, bx<ns_info>({ path: move p, parent: parent }));
    val id = @cast<u32>(this.nss.len - 1);
    this.ns(parent).children.put(name, id);
    return id;
}

// declare a file's items in namespace ns. Nothing is resolved yet: types, instances and bodies
// are checked later, on demand from the program's roots
attach fn collect(this: checker&, items: std::vec<item>&, ns: u32) -> compile_error!void {
    for (it&) in items.items() {
        try this.collect_item(it, ns, null);
    }
}

// add d to the list under name in a map of lists
attach fn add_name(this: checker&, m: std::map<str, u32>&, name: str, d: u32) -> void {
    val l = m.get(name);
    if (l) {
        put(this.list(*l), d);
        return;
    }
    val id = this.new_list(nodes(d));
    m.put(name, id);
}

// declare one item (and a trait's or attach block's fns, with it as their parent); attached fns
// also go into `attached`, found by method name
attach fn collect_item(this: checker&, it: item&, ns: u32, parent: u32?) -> compile_error!void {
    val file = it.span.file;
    for (a&) in it.attrs.items() {
        try this.check_attr(a, file);
    }
    var name: str? = null;
    var inner: std::vec<item>* = null;
    var is_block = false;
    var is_attach_fn = false;
    match (it.kind) {
        .NAMESPACE(path, items) => {
            var n = ns;
            for (p&) in path.items() {
                n = this.ns_child(n, *p);
            }
            for (sub&) in items.items() {
                try this.collect_item(sub, n, null);
            }
            return;
        },
        .USE(p&) => {
            if (p.segs.len < 2) {
                return fails(p.span, "use needs a path like std::io");
            }
            put(&this.ns(ns).uses, p);
            return;
        },
        .USE_C(headers&, alias) => {
            return this.import_c(headers, alias, ns, it.span);
        },
        .USE_CPP(headers&, alias) => {
            return this.import_cpp(headers, alias, ns, it.span);
        },
        .USE_LANG(lang, args&, alias) => {
            return this.import_lang(lang, args, alias, ns, it.span);
        },
        .FN(f) => {
            name = f.name;
            is_attach_fn = f.is_attach;
        },
        .STRUCT(s) => { name = s.name; },
        .ENUM(e) => { name = e.name; },
        .ALIAS(n, t) => { name = n; },
        .TRAIT(n, fns&) => {
            name = n;
            inner = fns;
        },
        .ATTACH(tr, target, fns&) => {
            inner = fns;
            is_block = true;
        },
        .GLOBAL(l) => {
            match (l.pat.kind) {
                .BIND(n) => { name = n; },
                default => { return fails(l.span, "global variables can't destructure"); },
            }
        },
    }
    val id = @cast<u32>(this.decls.len);
    put(&this.decls, { item: it, ns: ns, file: file, parent: parent });
    if (is_block) {
        put(&this.attach_blocks, id);
    }
    if (name) {
        val n = name;
        if (parent) {
            // fns inside attach blocks are methods of the target; trait fns are only signatures
            match (this.item_of(parent).kind) {
                .ATTACH(a, b, c) => { this.add_name(&this.attached, n, id); },
                default => {},
            }
        } else {
            // one name, one thing: only fn overloads, attached fns (methods, whatever else has the
            // name) and a struct's specializations share a name (C headers do too, struct stat and
            // stat(): not checked while importing them)
            val prev = this.ns(ns).names.get(n);
            if (prev != null && !this.importing_c) {
                for (d&) in this.list(*prev).items() {
                    if (!may_share(&this.item_of(*d).kind, &it.kind)) {
                        val e = fail(this.name_span(it.span, n), fmt("'{}' is already declared in this namespace", S(n)));
                        return with_label(move e, this.name_span(this.item_of(*d).span, n), S("first declared here"));
                    }
                }
            }
            if (is_attach_fn) {
                this.add_name(&this.attached, n, id);
            }
            this.add_name(&this.ns(ns).names, n, id);
        }
    }
    if (inner) {
        val fns = inner;
        for (f&) in fns.items() {
            match (f.kind) {
                .FN(x) => {},
                default => { return fails(f.span, "only fns go inside trait and attach blocks"); },
            }
            try this.collect_item(f, ns, id);
        }
    }
}

// may these two items have the same name in one namespace? fn overloads, attached fns, and a
// struct with its specializations
fn may_share(a: item_kind&, b: item_kind&) -> bool {
    match (*a) {
        .FN(f) => {
            match (*b) {
                .FN(g) => { return true; },
                default => { return f.is_attach; },
            }
        },
        .STRUCT(x) => {
            match (*b) {
                .FN(g) => { return g.is_attach; },
                .STRUCT(y) => { return x.spec != null || y.spec != null; },
                default => { return false; },
            }
        },
        default => {
            match (*b) {
                .FN(g) => { return g.is_attach; },
                default => { return false; },
            }
        },
    }
}

// ---------- lookup ----------

// Find a name from namespace ns outward: decls, or a namespace.
attach fn lookup(this: checker&, ns: u32, name: str) -> found? {
    return this.lookup_in(ns, name, false);
}

// lookup; with prefix (the name is followed by `::`), a namespace wins over methods of the same name
attach fn lookup_in(this: checker&, ns: u32, name: str, prefix: bool) -> found? {
    var cur: u32? = ns;
    while (cur) {
        val n = cur;
        val f = this.ns_member(n, name, prefix);
        if (f) {
            return f;
        }
        cur = this.ns(n).parent;
    }
    return null;
}

// methods are called as x.name(), never reached by path, so a path through `name::` means a
// namespace even when methods share its name
attach fn only_methods(this: checker&, ds: u32) -> bool {
    for (d&) in this.list(ds).items() {
        match (this.recv_of(*d)) {
            .VAL(pat) => {},
            default => { return false; },
        }
    }
    return true;
}

// Resolve a whole path from namespace ns. The second segment may also come from a `use` of the
// first (via_uses).
attach fn lookup_path_ns(this: checker&, ns: u32, p: path&) -> found? {
    var f = this.lookup_in(ns, p.segs.at(0).name, p.segs.len > 1) ?? return null;
    for (i) in 1..p.segs.len {
        val seg = p.segs.at(i).name;
        var next: found? = null;
        match (f) {
            .NS(n) => {
                next = this.ns_member(n, seg, i + 1 < p.segs.len);
                if (next == null && i == 1) {
                    next = this.via_uses(ns, p.segs.at(0).name, seg);
                } else if (i == 1) {
                    next = this.with_uses(next, ns, p.segs.at(0).name, seg);
                }
            },
            default => {},
        }
        f = next ?? return null;
    }
    return f;
}

// methods are called as x.name(), never by path, so when a namespace's own `name` is only methods,
// the functions a use brings in take their place
attach fn with_uses(this: checker&, own: found?, ns: u32, first: str, name: str) -> found? {
    val f = own ?? return null;
    match (f) {
        .DECLS(ds) => {
            for (d&) in this.list(ds).items() {
                match (this.recv_of(*d)) {
                    .VAL(pat) => {},
                    default => { return f; },
                }
            }
            val fns = this.via_uses(ns, first, name) ?? return f;
            match (fns) {
                .DECLS(x) => { return fns; },
                default => { return f; },
            }
        },
        default => { return f; },
    }
}

// the part of a path that doesn't resolve, for error messages
attach fn missing_part(this: checker&, ns: u32, p: path&) -> str {
    if (p.segs.len > 1 && this.lookup(ns, p.segs.at(0).name) == null) {
        return p.segs.at(0).name;
    }
    return p.last();
}

// a name declared directly in namespace n (no outward search); prefix as in lookup_in
attach fn ns_member(this: checker&, n: u32, name: str, prefix: bool) -> found? {
    val s = this.ns(n);
    val ds = s.names.get(name);
    val c = s.children.get(name);
    if (ds) {
        if (prefix && c != null && this.only_methods(*ds)) {
            return found::NS(*c);
        }
        return found::DECLS(*ds);
    }
    if (c) {
        return found::NS(*c);
    }
    return null;
}

// `a::name` through `use a::...::x;` in scope: a member of x (x a namespace), or x itself.
// Functions from several imports merge into one overload set.
attach fn via_uses(this: checker&, ns: u32, first: str, name: str) -> found? {
    var decls: std::vec<u32> = {};
    var other: found? = null;
    var cur: u32? = ns;
    while (cur) {
        val n = cur;
        for (up&) in this.ns(n).uses.items() {
            val u = *up;
            if (u.segs.at(0).name != first) {
                continue;
            }
            // use paths are absolute and resolved without this fallback (no cycles)
            var target: found? = found::NS(0);
            for (seg&) in u.segs.items() {
                var next: found? = null;
                match (target ?? found::DECLS(0)) {
                    .NS(m) => {
                        if (target) {
                            next = this.ns_member(m, seg.name, true);
                        }
                    },
                    default => {},
                }
                target = next;
            }
            if (target) {
                match (target) {
                    .NS(m) => {
                        val f = this.ns_member(m, name, false);
                        if (f) {
                            match (f) {
                                .DECLS(ds) => {
                                    for (d&) in this.list(ds).items() {
                                        put(&decls, *d);
                                    }
                                },
                                .NS(x) => {
                                    if (other == null) {
                                        other = found::NS(x);
                                    }
                                },
                            }
                        }
                    },
                    .DECLS(ds) => {
                        if (u.last() == name) {
                            for (d&) in this.list(ds).items() {
                                put(&decls, *d);
                            }
                        }
                    },
                }
            }
        }
        cur = this.ns(n).parent;
    }
    sort_dedup(&decls);
    if (decls.len == 0) {
        return other;
    }
    return found::DECLS(this.new_list(move decls));
}

fn sort_dedup(v: std::vec<u32>&) -> void {
    // insertion sort: these lists are short
    for (i) in 1..v.len {
        var j = i;
        while (j > 0 && *v.at(j - 1) > *v.at(j)) {
            val t = *v.at(j);
            *v.at(j) = *v.at(j - 1);
            *v.at(j - 1) = t;
            j -= 1;
        }
    }
    var out: usize = 0;
    for (i) in 0..v.len {
        if (out == 0 || *v.at(out - 1) != *v.at(i)) {
            *v.at(out) = *v.at(i);
            out += 1;
        }
    }
    v.len = out;
}

// ---------- names ----------

// a type as it's written in Volt, for messages and instance names
attach fn ty_name(this: checker&, id: u32) -> std::string {
    var s: std::string = {};
    this.put_ty(&s, id);
    return move s;
}

attach fn put_ty(this: checker&, s: std::string&, id: u32) -> void {
    match (*this.t.get(id)) {
        .VOID => { s.append("void"); },
        .NEVER => { s.append("never"); },
        .BOOL => { s.append("bool"); },
        .TYPE => { s.append("type"); },
        .NULL => { s.append("null"); },
        .STR => { s.append("str"); },
        .CSTR => { s.append("cstr"); },
        .VOIDPTR => { s.append("void*"); },
        .FLOAT(b) => {
            s.push('f');
            s.append_uint(@cast<u64>(b));
        },
        .INT(k) => { s.append(k.name()); },
        .REF(t) => {
            this.put_ty(s, t);
            s.push('&');
        },
        .PTR(t) => {
            this.put_ty(s, t);
            s.push('*');
        },
        .OPT(t) => {
            this.put_ty(s, t);
            s.push('?');
        },
        .ARRAY(t, n) => {
            this.put_ty(s, t);
            s.push('[');
            s.append_uint(n);
            s.push(']');
        },
        .SLICE(t) => {
            this.put_ty(s, t);
            s.append("[..]");
        },
        .TUPLE(ts, names) => {
            s.push('(');
            for (i) in 0..ts.len {
                if (i > 0) {
                    s.append(", ");
                }
                val n = *names.at(i);
                if (n) {
                    s.append(n);
                    s.append(": ");
                }
                this.put_ty(s, *ts.at(i));
            }
            s.push(')');
        },
        .RANGE(t) => {
            s.append("range<");
            this.put_ty(s, t);
            s.push('>');
        },
        .STRUCT(x) => { s.append(this.si(x).name); },
        .ENUM(x) => { s.append(this.ei(x).name); },
        .ERR_UNION(e, t) => {
            if (e != ANYERR) {
                this.put_ty(s, e);
            }
            s.push('!');
            // E!T& is a reference to an error union, so a payload with a suffix is parenthesized
            var suffixed = false;
            match (*this.t.get(t)) {
                .REF(x) => { suffixed = true; },
                .PTR(x) => { suffixed = true; },
                .OPT(x) => { suffixed = true; },
                .ARRAY(x, n) => { suffixed = true; },
                .SLICE(x) => { suffixed = true; },
                default => {},
            }
            if (suffixed) {
                s.push('(');
            }
            this.put_ty(s, t);
            if (suffixed) {
                s.push(')');
            }
        },
        .TRAIT_UNION(u) => { s.append(this.ui(u).name); },
        .CLOSURE(c) => {
            s.append("closure(");
            val ci = this.ci(c);
            for (i) in 0..ci.params.len {
                if (i > 0) {
                    s.append(", ");
                }
                this.put_ty(s, *ci.params.at(i));
            }
            s.append(") -> ");
            this.put_ty(s, ci.ret);
        },
        .FRAME(i) => {
            s.append("frame of ");
            s.append(this.fi(i).name);
        },
        .ANYERR => { s.append("error"); },
        .FN_PTR(ps&, r, va) => {
            s.append("extern \"C\" fn(");
            this.put_tys(s, ps);
            s.append(") -> ");
            this.put_ty(s, r);
        },
        .FN_VAL(ps&, r) => {
            s.append("fn(");
            this.put_tys(s, ps);
            s.append(") -> ");
            this.put_ty(s, r);
        },
    }
}

attach fn put_tys(this: checker&, s: std::string&, ts: std::vec<u32>&) -> void {
    for (i) in 0..ts.len {
        if (i > 0) {
            s.append(", ");
        }
        this.put_ty(s, *ts.at(i));
    }
}

// append a generic argument as it's written
attach fn gval_name(this: checker&, s: std::string&, g: gval) -> void {
    match (g) {
        .TY(t) => { this.put_ty(s, t); },
        .INT(v) => {
            val n = num(v);
            s.append(n.as_str());
        },
        .PACK(p) => {
            val ts = this.list(p);
            for (i) in 0..ts.len {
                if (i > 0) {
                    s.append(", ");
                }
                this.put_ty(s, *ts.at(i));
            }
        },
        .STR(x) => {
            // like Rust's {:?} of a string
            s.push('"');
            for (b) in x {
                if (b == '"' || b == '\\') {
                    s.push('\\');
                }
                s.push(b);
            }
            s.push('"');
        },
    }
}

// name<args> for an instance
attach fn inst_name(this: checker&, base: str, args: std::vec<gval>&) -> str {
    var s = S(base);
    if (args.len > 0) {
        s.push('<');
        for (i) in 0..args.len {
            if (i > 0) {
                s.append(", ");
            }
            this.gval_name(&s, *args.at(i));
        }
        s.push('>');
    }
    return this.intern(move s);
}

// the map key of (decl, generic args)
attach fn inst_key(this: checker&, d: u32, args: std::vec<gval>&) -> std::string {
    var k = unum(@cast<u64>(d));
    for (g&) in args.items() {
        k.push('|');
        match (*g) {
            .TY(t) => {
                k.push('t');
                k.append_uint(@cast<u64>(t));
            },
            .INT(v) => {
                k.push('i');
                val n = num(v);
                k.append(n.as_str());
            },
            .PACK(p) => {
                k.push('p');
                for (t&) in this.list(p).items() {
                    k.append_uint(@cast<u64>(*t));
                    k.push(',');
                }
            },
            .STR(x) => {
                k.push('s');
                k.append_uint(@cast<u64>(x.len));
                k.push(':');
                k.append(x);
            },
        }
    }
    return move k;
}

attach fn gval_eq(this: checker&, a: gval, b: gval) -> bool {
    match (a) {
        .TY(x) => {
            match (b) {
                .TY(y) => { return x == y; },
                default => { return false; },
            }
        },
        .INT(x) => {
            match (b) {
                .INT(y) => { return x == y; },
                default => { return false; },
            }
        },
        .STR(x) => {
            match (b) {
                .STR(y) => { return x == y; },
                default => { return false; },
            }
        },
        .PACK(x) => {
            match (b) {
                .PACK(y) => {
                    val (p, q) = (this.list(x), this.list(y));
                    if (p.len != q.len) {
                        return false;
                    }
                    for (i) in 0..p.len {
                        if (*p.at(i) != *q.at(i)) {
                            return false;
                        }
                    }
                    return true;
                },
                default => { return false; },
            }
        },
    }
}

// a C name no one has taken yet: base, else base_2, base_3, ...
attach fn fresh_c_name(this: checker&, base: str) -> str {
    var n: u32 = 0;
    val got = this.used_c_names.get(base);
    if (got) {
        n = *got;
    }
    loop {
        n += 1;
        // base_2 may already be a name of its own (a fn called foo_2): skip it
        var cand = S(base);
        if (n > 1) {
            cand.push('_');
            cand.append_uint(@cast<u64>(n));
        }
        if (n == 1 || this.used_c_names.get(cand.as_str()) == null) {
            val k = this.intern_str(base);
            this.used_c_names.put(k, n);
            val c = this.intern(move cand);
            if (this.used_c_names.get(c) == null) {
                this.used_c_names.put(c, 1);
            }
            return c;
        }
    }
}

attach fn intern_str(this: checker&, s: str) -> str {
    return this.names.intern_str(s);
}

// the package a decl comes from (null for the program's own files)
attach fn pkg_of(this: checker&, d: u32) -> str? {
    return this.pkg_of_file(this.dl(d).file);
}

// both the program's files (null), or the same package
fn same_pkg(a: str?, b: str?) -> bool {
    if (a) {
        if (b) {
            return a == b;
        }
        return false;
    }
    return b == null;
}

// An internal item belongs to its package: only that package's files may use it (the program's own
// files, for the program's). A template's body is judged by the file it's written in.
attach fn visible(this: checker&, d: u32, span: span) -> compile_error!void {
    if (this.item_of(d).vis != vis::INTERNAL) {
        return;
    }
    val owner = this.pkg_of(d);
    if (same_pkg(owner, this.pkg_of_file(span.file))) {
        return;
    }
    var whose = S("the program");
    if (owner) {
        whose = fmt("package {}", S(owner));
    }
    return fail(span, fmt2("'{}' is internal to {}", S(this.decl_name(d)), move whose));
}

attach fn pkg_of_file(this: checker&, file: u32) -> str? {
    for (p&) in this.opts.pkg_files.items() {
        if (p.file == file) {
            return p.pkg;
        }
    }
    return null;
}

attach fn line_col(this: checker&, sp: span) -> (line: usize, col: usize) {
    return file_line_col(this.files, sp);
}

// the 1-based line and column where a span starts
fn file_line_col(files: std::vec<source_file>&, sp: span) -> (line: usize, col: usize) {
    val p = text_pos(files.at(@cast<usize>(sp.file)).text, @cast<usize>(sp.lo));
    return { line: p.line, col: p.col };
}

// "file:line:col" for runtime messages
attach fn loc(this: checker&, sp: span) -> str {
    val lc = this.line_col(sp);
    var s = S(this.files.at(@cast<usize>(sp.file)).name);
    s.push(':');
    s.append_uint(@cast<u64>(lc.line));
    s.push(':');
    s.append_uint(@cast<u64>(lc.col));
    return this.intern(move s);
}

