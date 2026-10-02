// The checker's output: typed code in an arena, read by the backends (cgen.volt for C, lgen.volt for LLVM). A node is
// a u32; subtrees may be shared (a pure value used twice). Types are the checker's type ids.
//
// Aggregate fields (FIELD/AGG) are numbered per type:
//   struct: field i, tuple: element i, closure: capture i,
//   optional (not a pointer): 0 value, 1 has; slice and str: 0 ptr, 1 len; range: 0 lo, 1 hi;
//   error union: 0 err, 1 value; enum with payloads: 0 tag, 1 + i payload of variant i;
//   trait union: 0 tag, 1 + i member i; fn value: 0 fn, 1 env;
//   frame: 0 state, 1 cancel, 2 result, 3 + i slot i.
use std::mem;

enum unop_ir {
    NEG,    // float negate, or wrapping int negate
    NOT,    // bool
    BITNOT,
}

enum binop_ir {
    ADD, SUB, MUL, DIV, REM, // ints wrap (two's complement); DIV/REM truncate; floats IEEE, REM is fmod
    BITAND, BITOR, BITXOR,
    SHL, SHR,                // amount already checked < bits; SHR is arithmetic for signed
    EQ, NE, LT, GT, LE, GE,  // result bool; ints compare by signedness
    AND, OR,                 // bool, short-circuit
}

// one SWITCH case: the value it matches and the statement it runs
struct case_arm {
    value: i128;
    body: u32;
}

// one AGG field: its number (see the numbering above) and the value node
struct field_init {
    field: u32;
    value: u32;
}

enum ir_kind {
    // ---- values ----
    INT: i128,       // an integer or float type holding exactly this value
    FLOAT: f64,
    BOOL: bool,
    STR: str,        // a str value over these bytes
    CSTR: str,       // pointer to a NUL-terminated copy of these bytes
    NULLPTR,         // null pointer (a pointer type or a pointer-like optional)
    ZERO,            // all bits zero
    LOCAL: u32,      // place: a local of the enclosing fn (ir_fn.locals index)
    GLOBAL: u32,     // place: a global (ir_prog.globals index)
    FN: u32,         // a function (ir_prog.fns index) as a pointer
    RT: str,         // a runtime function by name (volt_panic, volt_out, ...), as a pointer
    FIELD: (u32, u32),      // field n of an aggregate place (a place) or value
    DEREF: u32,             // place: *p
    ADDR: u32,              // &place
    INDEX: (u32, u32),      // place: element i of an array place, or p[i] for a pointer p
    UNARY: (unop_ir, u32),
    BINARY: (binop_ir, u32, u32),
    CHECKED: (binop_ir, u32, u32, str), // ADD/SUB/MUL that panic with "integer overflow" at loc
    CONV: u32,       // convert to the node type: int/float/bool/pointer/enum-tag conversions
    BITCAST: u32,    // the same bits as the node type (sizes match)
    CALL: (u32, std::vec<u32>), // callee (a fn pointer value), args
    AGG: std::vec<field_init>,  // an aggregate of the node type; fields not given are zero
    ARRAY_LIT: std::vec<u32>,   // an array of the node type, element by element
    SEQ: (std::vec<u32>, u32?), // statements, then a value (none: the SEQ is a statement)
    COND: (u32, u32, u32),      // c ? a : b
    SIZEOF: u32,                // size of a type (usize); the backend knows C headers' layouts
    ALIGNOF: u32,
    OFFSETOF: (u32, u32),       // type, field index
    // ---- statements (type void or never) ----
    DECL: (u32, u32?),   // local, initial value
    ASSIGN: (u32, u32),  // place = value
    IF: (u32, u32, u32?),
    LOOP: u32,           // forever (leave by goto or return)
    LABEL: u32,
    GOTO: u32,
    SWITCH: (u32, std::vec<case_arm>, u32?), // value, cases (no fallthrough), default
    RETURN: u32?,
    BLOCK: std::vec<u32>,
    UNREACHABLE,
    AT: (u32, u32), // the next statement's place in the source (file, line): #line, for --profiler
}

struct ir_node {
    kind: ir_kind;
    ty: u32;
}

struct ir_local {
    name: str; // for readable output
    ty: u32;
}

enum linkage {
    STATIC,   // defined here, private
    EXPORTED, // defined here, visible to other units
    EXTERNAL, // defined elsewhere: only declared
}

struct fn_attrs {
    is_inline: bool = false;
    noinline: bool = false;
    opt: str? = null;     // optimization level
    section: str? = null;
    align: str? = null;
    deprecated: bool = false;
}

struct ir_fn {
    name: str;           // the symbol
    params: std::vec<u32>;  // locals
    ret: u32;
    locals: std::vec<ir_local> = {};
    body: u32? = null;   // none: declared only
    link: linkage;
    c_varargs: bool = false;
    real_name: str? = null; // bound to this symbol instead (extern "C" aliases)
    from_header: bool = false; // an imported C header declares it
    attrs: fn_attrs = {}; // from @inline, @section(...), ...
    noreturn: bool = false;
    prelude: bool = false;   // provided by the runtime prelude (a volt_ intrinsic)
    used: bool = false;      // declared in this unit
    async_of: u32? = null;   // an async fn: its step/await/run helpers follow (C backend)
    // the Volt it comes from (a fn, closure or async fn; none for generated helpers) and, for a fn
    // instance, its name as Volt writes it (std::vec<u8>::push): the C backend files and labels it
    origin: span? = null;
    about: str = "";
}

struct ir_global {
    name: str;
    ty: u32;
    init: u32?;
    mutable: bool;
    link: linkage;
    header: bool = false; // defined by an imported C header
    keep: bool = false;   // must stay in the object even if unused (guard references)
    origin: span? = null; // the Volt declaring it (none for generated ones)
    tls: bool = false;    // @thread_local: each thread has its own
}

// the IR for a whole unit; nodes, fns and globals refer to each other by index
struct ir_prog {
    nodes: std::vec<ir_node> = {};
    fns: std::vec<std::box<ir_fn>> = {};
    globals: std::vec<ir_global> = {};
    labels: u32 = 0;
    order: std::vec<u32> = {}; // fns in the order they were first used (prototypes)
    bodies: std::vec<u32> = {}; // fns in the order their bodies were made
}

attach fn node(this: ir_prog&, kind: ir_kind, t: u32) -> u32 {
    put(&this.nodes, { kind: move kind, ty: t });
    return @cast<u32>(this.nodes.len - 1);
}

attach fn at(this: ir_prog&, n: u32) -> ir_node& {
    return this.nodes.at(@cast<usize>(n));
}

attach fn ty_of(this: ir_prog&, n: u32) -> u32 {
    return this.nodes.at(@cast<usize>(n)).ty;
}

attach fn fn_at(this: ir_prog&, i: u32) -> ir_fn& {
    return *this.fns.at(@cast<usize>(i));
}

// a fresh label id for LABEL/GOTO (ids start at 1)
attach fn label(this: ir_prog&) -> u32 {
    this.labels += 1;
    return this.labels;
}

// ---------- field numbering ----------

// how many fields an aggregate type has, by the numbering above
attach fn field_count(this: checker&, t: u32) -> usize {
    match (*this.t.get(t)) {
        .STRUCT(s) => {
            val fs = this.struct_fields(s, {}) catch |e| { return 0; };
            return fs.len;
        },
        .TUPLE(ts, names) => { return ts.len; },
        .CLOSURE(c) => { return this.ci(c).caps.len; },
        .ENUM(e) => {
            val ps = this.enum_payloads(e, {}) catch |x| { return 1; };
            return ps.len + 1;
        },
        .TRAIT_UNION(u) => { return this.ui(u).members.len + 1; },
        .FRAME(f) => { return this.frame_of(f).fields.len + 3; },
        .OPT(x) => {
            if (this.niche_field(x) != null) {
                return this.field_count(x); // the owning struct itself
            }
            return 2;
        },
        .SLICE(x) => { return 2; },
        .STR => { return 2; },
        .RANGE(x) => { return 2; },
        .ERR_UNION(e, x) => { return 2; },
        .FN_VAL(ps, r) => { return 2; },
        default => { return 0; },
    }
}

// field i's type (an enum's or trait union's field 1 + i is payload/member i)
attach fn field_ty(this: checker&, agg: u32, i: u32) -> u32 {
    match (*this.t.get(agg)) {
        .STRUCT(s) => {
            val fs = this.struct_fields(s, {}) catch |e| { return VOID; };
            return fs.at(@cast<usize>(i)).ty;
        },
        .TUPLE(ts, names) => { return *ts.at(@cast<usize>(i)); },
        .CLOSURE(c) => { return this.ci(c).caps.at(@cast<usize>(i)).ty; },
        .OPT(x) => {
            if (this.niche_field(x) != null) {
                return this.field_ty(x, i);
            }
            if (i == 0) {
                return x;
            }
            return BOOL;
        },
        .SLICE(x) => {
            if (i == 0) {
                return this.t.intern(tyk::PTR(x));
            }
            return USIZE;
        },
        .STR => {
            if (i == 0) {
                return this.t.intern(tyk::PTR(U8));
            }
            return USIZE;
        },
        .RANGE(x) => { return x; },
        .ERR_UNION(e, x) => {
            if (i == 0) {
                return e;
            }
            return x;
        },
        .ENUM(e) => {
            if (i == 0) {
                return int_id(this.ei(e).tag);
            }
            val ps = this.enum_payloads(e, {}) catch |x| { return VOID; };
            return *ps.at(@cast<usize>(i - 1)) ?? VOID;
        },
        .TRAIT_UNION(u) => {
            if (i == 0) {
                return int_id(int_ty::U16);
            }
            return *this.ui(u).members.at(@cast<usize>(i - 1));
        },
        .FN_VAL(ps, r) => { return VOIDPTR; },
        .FRAME(f) => {
            if (i == 0) {
                return U32;
            }
            if (i == 1) {
                return BOOL;
            }
            if (i == 2) {
                return this.fi(f).ret;
            }
            return this.frame_of(f).fields.at(@cast<usize>(i - 3)).ty;
        },
        default => { return VOID; },
    }
}

// ---------- builders ----------

attach fn int(this: ir_prog&, v: i128, t: u32) -> u32 {
    return this.node(ir_kind::INT(v), t);
}

attach fn boolean(this: ir_prog&, b: bool) -> u32 {
    return this.node(ir_kind::BOOL(b), BOOL);
}

attach fn zero(this: ir_prog&, t: u32) -> u32 {
    return this.node(ir_kind::ZERO, t);
}

attach fn field(this: ir_prog&, base: u32, n: u32, t: u32) -> u32 {
    return this.node(ir_kind::FIELD(base, n), t);
}

attach fn deref(this: ir_prog&, p: u32, t: u32) -> u32 {
    return this.node(ir_kind::DEREF(p), t);
}

attach fn addr(this: ir_prog&, place: u32, t: u32) -> u32 {
    return this.node(ir_kind::ADDR(place), t);
}

attach fn index(this: ir_prog&, base: u32, i: u32, t: u32) -> u32 {
    return this.node(ir_kind::INDEX(base, i), t);
}

attach fn unary(this: ir_prog&, op: unop_ir, x: u32, t: u32) -> u32 {
    return this.node(ir_kind::UNARY(op, x), t);
}

attach fn binary(this: ir_prog&, op: binop_ir, a: u32, b: u32, t: u32) -> u32 {
    return this.node(ir_kind::BINARY(op, a, b), t);
}

attach fn conv(this: ir_prog&, x: u32, t: u32) -> u32 {
    return this.node(ir_kind::CONV(x), t);
}

attach fn bitcast(this: ir_prog&, x: u32, t: u32) -> u32 {
    return this.node(ir_kind::BITCAST(x), t);
}

attach fn call(this: ir_prog&, f: u32, args: std::vec<u32>, t: u32) -> u32 {
    return this.node(ir_kind::CALL(f, move args), t);
}

attach fn rt(this: ir_prog&, name: str) -> u32 {
    return this.node(ir_kind::RT(name), VOIDPTR);
}

// a call to a runtime function
attach fn rt_call(this: ir_prog&, name: str, args: std::vec<u32>, t: u32) -> u32 {
    val f = this.rt(name);
    return this.call(f, move args, t);
}

attach fn seq(this: ir_prog&, stmts: std::vec<u32>, value: u32?, t: u32) -> u32 {
    return this.node(ir_kind::SEQ(move stmts, value), t);
}

attach fn block(this: ir_prog&, stmts: std::vec<u32>) -> u32 {
    return this.node(ir_kind::BLOCK(move stmts), VOID);
}

attach fn decl(this: ir_prog&, local: u32, init: u32?) -> u32 {
    return this.node(ir_kind::DECL(local, init), VOID);
}

attach fn assign(this: ir_prog&, place: u32, value: u32) -> u32 {
    return this.node(ir_kind::ASSIGN(place, value), VOID);
}

attach fn if_(this: ir_prog&, c: u32, then: u32, els: u32?) -> u32 {
    return this.node(ir_kind::IF(c, then, els), VOID);
}

attach fn goto_(this: ir_prog&, l: u32) -> u32 {
    return this.node(ir_kind::GOTO(l), NEVER);
}

attach fn label_at(this: ir_prog&, l: u32) -> u32 {
    return this.node(ir_kind::LABEL(l), VOID);
}

attach fn ret(this: ir_prog&, v: u32?) -> u32 {
    return this.node(ir_kind::RETURN(v), NEVER);
}

// panic with a message at a source location
attach fn panic(this: ir_prog&, msg: str, loc: str) -> u32 {
    var args: std::vec<u32> = {};
    put(&args, this.node(ir_kind::CSTR(msg), CSTR));
    put(&args, this.node(ir_kind::CSTR(loc), CSTR));
    return this.rt_call("volt_panic", move args, NEVER);
}

// a list of nodes, built from up to three
fn nodes(a: u32) -> std::vec<u32> {
    var v: std::vec<u32> = {};
    put(&v, a);
    return move v;
}

fn nodes2(a: u32, b: u32) -> std::vec<u32> {
    var v: std::vec<u32> = {};
    put(&v, a);
    put(&v, b);
    return move v;
}

fn nodes3(a: u32, b: u32, c: u32) -> std::vec<u32> {
    var v: std::vec<u32> = {};
    put(&v, a);
    put(&v, b);
    put(&v, c);
    return move v;
}

// the nodes directly under n, in evaluation order
attach fn kids(this: ir_prog&, n: u32, out: std::vec<u32>&) -> void {
    match (this.at(n).kind) {
        .FIELD(b, i) => { put(out, b); },
        .DEREF(p) => { put(out, p); },
        .ADDR(p) => { put(out, p); },
        .INDEX(b, i) => {
            put(out, b);
            put(out, i);
        },
        .UNARY(op, x) => { put(out, x); },
        .BINARY(op, a, b) => {
            put(out, a);
            put(out, b);
        },
        .CHECKED(op, a, b, loc) => {
            put(out, a);
            put(out, b);
        },
        .CONV(x) => { put(out, x); },
        .BITCAST(x) => { put(out, x); },
        .CALL(f, args) => {
            put(out, f);
            for (a&) in args.items() {
                put(out, *a);
            }
        },
        .AGG(inits) => {
            for (f&) in inits.items() {
                put(out, f.value);
            }
        },
        .ARRAY_LIT(xs) => {
            for (x&) in xs.items() {
                put(out, *x);
            }
        },
        .SEQ(stmts, v) => {
            for (s&) in stmts.items() {
                put(out, *s);
            }
            if (v) {
                put(out, v);
            }
        },
        .COND(c, a, b) => {
            put(out, c);
            put(out, a);
            put(out, b);
        },
        .DECL(l, init) => {
            if (init) {
                put(out, init);
            }
        },
        .ASSIGN(p, v) => {
            put(out, p);
            put(out, v);
        },
        .IF(c, a, b) => {
            put(out, c);
            put(out, a);
            if (b) {
                put(out, b);
            }
        },
        .LOOP(b) => { put(out, b); },
        .SWITCH(v, cases, d) => {
            put(out, v);
            for (c&) in cases.items() {
                put(out, c.body);
            }
            if (d) {
                put(out, d);
            }
        },
        .RETURN(v) => {
            if (v) {
                put(out, v);
            }
        },
        .BLOCK(stmts) => {
            for (s&) in stmts.items() {
                put(out, *s);
            }
        },
        default => {},
    }
}
