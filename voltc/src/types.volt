// Interned types: a port of bootstrap/types.rs. Equal types have equal ids. Types sit in boxes, so a
// tyk& stays valid while the table grows.
use std::mem;

enum int_ty {
    I8, I16, I32, I64, I128, ISIZE,
    U8, U16, U32, U64, U128, USIZE,
}

// every int type; an int's type id is INT_BASE + its index here, so the order is fixed
val INTS: int_ty[] = {
    int_ty::I8, int_ty::I16, int_ty::I32, int_ty::I64, int_ty::I128, int_ty::ISIZE,
    int_ty::U8, int_ty::U16, int_ty::U32, int_ty::U64, int_ty::U128, int_ty::USIZE,
};

attach fn signed(this: int_ty&) -> bool {
    match (*this) {
        .I8 => { return true; },
        .I16 => { return true; },
        .I32 => { return true; },
        .I64 => { return true; },
        .I128 => { return true; },
        .ISIZE => { return true; },
        default => { return false; },
    }
}

attach fn bits(this: int_ty&) -> u32 {
    match (*this) {
        .I8 => { return 8; },
        .U8 => { return 8; },
        .I16 => { return 16; },
        .U16 => { return 16; },
        .I32 => { return 32; },
        .U32 => { return 32; },
        .I128 => { return 128; },
        .U128 => { return 128; },
        default => { return 64; },
    }
}

attach fn name(this: int_ty&) -> str {
    match (*this) {
        .I8 => { return "i8"; },
        .I16 => { return "i16"; },
        .I32 => { return "i32"; },
        .I64 => { return "i64"; },
        .I128 => { return "i128"; },
        .ISIZE => { return "isize"; },
        .U8 => { return "u8"; },
        .U16 => { return "u16"; },
        .U32 => { return "u32"; },
        .U64 => { return "u64"; },
        .U128 => { return "u128"; },
        .USIZE => { return "usize"; },
    }
}

// whether the constant v is representable in this type
attach fn fits(this: int_ty&, v: i128) -> bool {
    val b = this.bits();
    if (this.signed()) {
        if (b == 128) {
            return true;
        }
        val lim = @cast<i128>(1) << (b - 1);
        return v >= -lim && v < lim;
    }
    if (v < 0) {
        return false;
    }
    if (b >= 127) {
        return true;
    }
    return v < (@cast<i128>(1) << b);
}

// does a float of `bits` hold every value of this integer type exactly (its mantissa is wide enough)?
attach fn exact_in_float(this: int_ty&, bits: u16) -> bool {
    var mag = this.bits();
    if (this.signed()) {
        mag -= 1;
    }
    var mant: u32 = 53;
    if (bits <= 32) {
        mant = 24;
    }
    if (bits <= 16) {
        mant = 11;
    }
    return mag <= mant;
}

// lossless conversion from this to other: to a wider type of the same signedness (usize and u64,
// isize and i64, are the same width), or from unsigned to a wider signed type
attach fn widens_to(this: int_ty&, other: int_ty) -> bool {
    if (*this == other) {
        return true;
    }
    val (sa, sb) = (this.signed(), other.signed());
    val (ba, bb) = (this.bits(), other.bits());
    if (sa == sb) {
        // usize and u64 (isize and i64) are the same 64 bits on every target, so each is the other
        return ba <= bb;
    }
    if (!sa && sb) {
        return ba < bb;
    }
    return false;
}

// a type's structure; the u32 in STRUCT, ENUM, CLOSURE and TRAIT_UNION indexes the checker's structs, enums,
// closures and unions, and in FRAME its fns
enum tyk {
    VOID,
    NEVER,
    BOOL,
    TYPE,
    NULL,
    STR,
    CSTR,
    VOIDPTR,
    FLOAT: u16,
    INT: int_ty,
    REF: u32, // T&: never null
    PTR: u32, // T*: raw, may be null
    OPT: u32,
    ARRAY: (u32, u64),
    // a SIMD vector: its element (a number) and how many lanes (a power of two)
    VECTOR: (u32, u64),
    SLICE: u32,
    // element types, and a name per element (null when unnamed)
    TUPLE: (std::vec<u32>, std::vec<str?>),
    // element type
    RANGE: u32,
    STRUCT: u32,
    ENUM: u32,
    ERR_UNION: (u32, u32), // error set (an enum with is_error, or ANYERR), payload
    ANYERR,
    FN_PTR: (std::vec<u32>, u32, bool), // extern "C" fn: a thin C function pointer
    FN_VAL: (std::vec<u32>, u32),       // fn(A) -> R: {fn, env}, can hold a closure
    CLOSURE: u32,
    FRAME: u32,       // an async fn instance's frame
    TRAIT_UNION: u32, // trait used as a type
}

// ids of the types new_types interns first, in this order
val VOID: u32 = 0;
val NEVER: u32 = 1;
val BOOL: u32 = 2;
val TYPE: u32 = 3;
val NULL_TY: u32 = 4;
val STR: u32 = 5;
val CSTR: u32 = 6;
val VOIDPTR: u32 = 7;
val F16: u32 = 8;
val F32: u32 = 9;
val F64: u32 = 10;
val F128: u32 = 11;
val ANYERR: u32 = 12;
val INT_BASE: u32 = 13;
val I32: u32 = 15;
val I64: u32 = 16;
val U8: u32 = 19;
val U32: u32 = 21;
val USIZE: u32 = 24;

// the fixed type id of an int type
fn int_id(k: int_ty) -> u32 {
    for (x, i) in INTS {
        if (x == k) {
            return INT_BASE + @cast<u32>(i);
        }
    }
    return INT_BASE;
}

// the type interner: `list` holds each distinct type once (boxed, so a tyk& survives growth), `map` goes
// from a type's ty_key to its id, and `keys` owns the key strings
struct types {
    list: std::vec<std::box<tyk>> = {};
    map: std::map<str, u32> = {};
    keys: interner = {};
}

// the text that identifies a type (equal types, equal keys)
fn ty_key(t: tyk&) -> std::string {
    var k: std::string = {};
    match (*t) {
        .VOID => { k.append("v"); },
        .NEVER => { k.append("!"); },
        .BOOL => { k.append("b"); },
        .TYPE => { k.append("T"); },
        .NULL => { k.append("n"); },
        .STR => { k.append("s"); },
        .CSTR => { k.append("c"); },
        .VOIDPTR => { k.append("p"); },
        .ANYERR => { k.append("e"); },
        .FLOAT(b) => {
            k.append("f");
            k.append_uint(@cast<u64>(b));
        },
        .INT(i) => {
            k.append("i");
            k.append(i.name());
        },
        .REF(x) => { key_one(&k, "R", x); },
        .PTR(x) => { key_one(&k, "Q", x); },
        .OPT(x) => { key_one(&k, "O", x); },
        .ARRAY(x, n) => {
            key_one(&k, "A", x);
            k.push(':');
            k.append_uint(n);
        },
        .VECTOR(x, n) => {
            key_one(&k, "V", x);
            k.push(':');
            k.append_uint(n);
        },
        .SLICE(x) => { key_one(&k, "S", x); },
        .TUPLE(ts&, names) => {
            k.append("(");
            key_list(&k, ts);
            for (n&) in names.items() {
                k.push(',');
                if (*n) {
                    k.append(*n ?? "");
                } else {
                    k.push('_');
                }
            }
            k.append(")");
        },
        .RANGE(x) => { key_one(&k, "G", x); },
        .STRUCT(x) => { key_one(&k, "st", x); },
        .ENUM(x) => { key_one(&k, "en", x); },
        .ERR_UNION(e, x) => {
            key_one(&k, "E", e);
            key_one(&k, ",", x);
        },
        .FN_PTR(ps&, r, va) => {
            k.append("P(");
            key_list(&k, ps);
            key_one(&k, ")", r);
            if (va) {
                k.append("...");
            }
        },
        .FN_VAL(ps&, r) => {
            k.append("F(");
            key_list(&k, ps);
            key_one(&k, ")", r);
        },
        .CLOSURE(x) => { key_one(&k, "cl", x); },
        .FRAME(x) => { key_one(&k, "fr", x); },
        .TRAIT_UNION(x) => { key_one(&k, "tu", x); },
    }
    return k;
}

// appends tag then the id
fn key_one(k: std::string&, tag: str, x: u32) -> void {
    k.append(tag);
    k.append_uint(@cast<u64>(x));
}

fn key_list(k: std::string&, xs: std::vec<u32>&) -> void {
    for (x&) in xs.items() {
        k.append_uint(@cast<u64>(*x));
        k.push(' ');
    }
}

// interns the builtins in the order the constants above assume
fn new_types() -> types {
    var t: types = {};
    t.intern(tyk::VOID);
    t.intern(tyk::NEVER);
    t.intern(tyk::BOOL);
    t.intern(tyk::TYPE);
    t.intern(tyk::NULL);
    t.intern(tyk::STR);
    t.intern(tyk::CSTR);
    t.intern(tyk::VOIDPTR);
    t.intern(tyk::FLOAT(16));
    t.intern(tyk::FLOAT(32));
    t.intern(tyk::FLOAT(64));
    t.intern(tyk::FLOAT(128));
    t.intern(tyk::ANYERR);
    for (k) in INTS {
        t.intern(tyk::INT(k));
    }
    return t;
}

// the id of t, adding it if it's new
attach fn intern(this: types&, t: tyk) -> u32 {
    var key = ty_key(&t);
    val found = this.map.get(key.as_str());
    if (found) {
        return *found;
    }
    val id = @cast<u32>(this.list.len);
    val k = this.keys.intern(move key);
    put(&this.list, bx(move t));
    this.map.put(k, id);
    return id;
}

attach fn get(this: types&, id: u32) -> tyk& {
    return *this.list.at(@cast<usize>(id));
}

attach fn int_of(this: types&, id: u32) -> int_ty? {
    match (*this.get(id)) {
        .INT(k) => { return k; },
        default => { return null; },
    }
}

attach fn is_float(this: types&, id: u32) -> bool {
    match (*this.get(id)) {
        .FLOAT(b) => { return true; },
        default => { return false; },
    }
}

// types whose optional uses a null pointer as "none" (a raw pointer can be null itself, so its
// optional can't)
attach fn is_niche(this: types&, id: u32) -> bool {
    match (*this.get(id)) {
        .REF(x) => { return true; },
        .CSTR => { return true; },
        .FN_PTR(ps, r, va) => { return true; },
        default => { return false; },
    }
}

// a raw pointer (T* or void*): may be null
attach fn is_ptr(this: types&, id: u32) -> bool {
    match (*this.get(id)) {
        .PTR(x) => { return true; },
        .VOIDPTR => { return true; },
        default => { return false; },
    }
}

attach fn ref_to(this: types&, t: u32) -> u32 {
    return this.intern(tyk::REF(t));
}

attach fn opt_of(this: types&, t: u32) -> u32 {
    return this.intern(tyk::OPT(t));
}

// the referenced type of T& (or null)
attach fn ref_inner(this: types&, id: u32) -> u32? {
    match (*this.get(id)) {
        .REF(x) => { return x; },
        default => { return null; },
    }
}

// the payload type of T? (or null)
attach fn opt_inner(this: types&, id: u32) -> u32? {
    match (*this.get(id)) {
        .OPT(x) => { return x; },
        default => { return null; },
    }
}

// the builtin type a name stands for (`error` is the any-error set)
fn primitive(name: str) -> u32? {
    if (name == "void") { return VOID; }
    if (name == "never") { return NEVER; }
    if (name == "bool") { return BOOL; }
    if (name == "type") { return TYPE; }
    if (name == "str") { return STR; }
    if (name == "cstr") { return CSTR; }
    if (name == "f16") { return F16; }
    if (name == "f32") { return F32; }
    if (name == "f64") { return F64; }
    if (name == "f128") { return F128; }
    if (name == "error") { return ANYERR; }
    for (k, i) in INTS {
        if (k.name() == name) {
            return INT_BASE + @cast<u32>(i);
        }
    }
    return null;
}

// Strings that live as long as the compiler: map keys and made-up names point into them.
struct interner {
    strs: std::vec<std::string> = {};
}

// takes ownership of s and returns a view of it that stays valid for the interner's life
attach fn intern(this: interner&, s: std::string) -> str {
    put(&this.strs, move s);
    return this.strs.at(this.strs.len - 1).as_str(); // the bytes stay put when the vec grows
}

attach fn intern_str(this: interner&, s: str) -> str {
    return this.intern(std::string::from(s));
}

// no type: compares unequal to every real type id
val NO_TY: u32 = 4294967295;
