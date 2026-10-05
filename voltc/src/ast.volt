// The syntax tree: a port of bootstrap/ast.rs. Names are slices of the source
// text (the source outlives the tree); string literal contents are owned.
use std::mem;

// a heap copy of a node, for recursive types
<T: type>
fn bx(value: T) -> std::box<T> {
    return T::new(move value) catch @panic("out of memory");
}

struct path_seg {
    name: str;
    args: std::vec<garg>?;
}

// a name, maybe qualified and with generic args on any segment: `std::vec<i32>::new`
struct path {
    segs: std::vec<path_seg>;
    span: span;
}

attach fn last(this: path&) -> str {
    return this.segs.at(this.segs.len - 1).name;
}

// a bare name: one segment, no generic args
attach fn is_single(this: path&) -> bool {
    return this.segs.len == 1 && this.segs.at(0).args == null;
}

// one argument in `<...>`. Whatever parses as a type becomes TYPE (so a plain name is always TYPE); the
// checker decides whether it names a type or a value
enum garg {
    TYPE: ty,
    EXPR: expr,
}

struct ty {
    kind: type_kind;
    span: span;
}

struct tuple_elem {
    name: str?;
    ty: ty;
}

struct fn_type {
    params: std::vec<ty>;
    c_varargs: bool;
    ret: std::box<ty>;
    extern_c: bool;
}

// ARRAY's length is null in `T[]` (taken from the initializer); ERROR_UNION's set is null in `!T`
// (inferred); EXPR is a comptime call that returns a type
enum type_kind {
    PATH: path,
    REF: std::box<ty>, // T&: a reference, never null
    PTR: std::box<ty>, // T*: a raw pointer, may be null
    OPTIONAL: std::box<ty>,
    ARRAY: (std::box<ty>, std::box<expr>?),
    SLICE: std::box<ty>,
    TUPLE: std::vec<tuple_elem>,
    ERROR_UNION: (std::box<ty>?, std::box<ty>),
    FN: fn_type,
    PACK: std::box<ty>,
    EXPR: std::box<expr>,
}

enum binop {
    ADD, SUB, MUL, DIV, REM,
    WADD, WSUB, WMUL,
    AND, OR,
    BITAND, BITOR, BITXOR, SHL, SHR,
    EQ, NE, LT, GT, LE, GE,
}

enum unop {
    NEG, NOT, BITNOT, ADDR, DEREF,
}

enum cap_mode {
    COPY, REF, MOVE,
}

struct capture {
    name: str;
    mode: cap_mode;
    span: span;
}

// a piece of a quote's source text, and the value spliced in after it (none after the last)
struct quote_part {
    text: str;
    splice: expr?;
}

struct lit_entry {
    name: str?;
    value: expr;
}

struct closure {
    caps: std::vec<capture>;
    generics: std::vec<generic_param> = {}; // a generic closure's: |c| <T: type>(x: T) { }
    params: std::vec<param>;
    ret: ty?;
    body: block;
}

struct catch_cap {
    name: str;
    span: span;
}

struct binding {
    name: str;
    by_ref: bool;
    span: span;
}

// `for (v, i) in iter => map [var acc: T = init] { body }`. `=> map` replaces the element with the mapped
// value each iteration; the `[..]` accumulator is declared before the loop and is the loop's value
struct for_loop {
    label: str?;
    bindings: std::vec<binding>;
    iter: expr;
    map: expr?;
    acc: let_stmt?;
    body: block;
    is_comptime: bool;
}

struct if_node {
    cond: std::box<expr>;
    then: block;
    els: std::box<expr>?;
    is_comptime: bool;
}

// one `pat if guard => body` arm of a match
struct arm {
    pat: pat;
    guard: expr?;
    body: expr;
    span: span;
}

struct match_node {
    scrut: std::box<expr>;
    arms: std::vec<arm>;
    is_comptime: bool;
}

// INT holds the literal's magnitude; a leading `-` is UNARY(NEG, ..). ASSIGN's op is set for `a op= b`,
// CAST is `x as T`, and BUILTIN's second list is null when `@name` has no parentheses
enum expr_kind {
    INT: u128,
    FLOAT: f64,
    CHAR: u32,
    STR: std::string,
    BOOL: bool,
    NULL,
    THIS,
    ERROR_ANY,
    PATH: path,
    DOT_VARIANT: str,
    UNARY: (unop, std::box<expr>),
    BINARY: (binop, std::box<expr>, std::box<expr>),
    ASSIGN: (binop?, std::box<expr>, std::box<expr>),
    INC_DEC: (std::box<expr>, bool),
    CAST: (std::box<expr>, ty),
    RANGE: (std::box<expr>?, std::box<expr>?, bool),
    CALL: (std::box<expr>, std::vec<expr>),
    FIELD: (std::box<expr>, str, std::vec<garg>?),
    INDEX: (std::box<expr>, std::box<expr>),
    BUILTIN: (str, std::vec<garg>, std::vec<garg>?),
    TUPLE: std::vec<expr>,
    LITERAL: std::vec<lit_entry>,
    REPEAT: (std::box<expr>, std::box<expr>), // { x; n }: an array of n copies of x, typed by context
    CLOSURE: closure,
    QUOTE: std::vec<quote_part>, // quote { Volt source with $(splices) }: a comptime str
    TRY: std::box<expr>,
    AWAIT: std::box<expr>,
    ASYNC: std::box<expr>,
    MOVE: std::box<expr>,
    COPY: std::box<expr>,
    CATCH: (std::box<expr>, catch_cap?, std::box<expr>),
    OR_ELSE: (std::box<expr>, std::box<expr>),
    RETURN: std::box<expr>?,
    BREAK: (str?, std::box<expr>?),
    CONTINUE: str?,
    BLOCK: (str?, block),
    LOOP: (str?, block),
    WHILE: (str?, std::box<expr>, block),
    FOR: std::box<for_loop>,
    IF: if_node,
    MATCH: match_node,
}

// the label of the block a struct update `{ ..base, a: x }` is parsed into, and its temporary (a
// hidden local: source can't name either)
val UPDATE_LABEL: str = "@update";
val UPDATE_TMP: str = "@base";
// `if (val v = e)` and `while (val x = e)` are parsed into labeled blocks too: these labels, and a
// hidden local holding e (a nested one shadows it, as a nested scope may)
val IF_LABEL: str = "@if";
val ELSE_LABEL: str = "@else";
val IF_TMP: str = "@if";

struct expr {
    kind: expr_kind;
    span: span;
}

enum ctor_path {
    DOT: str,
    PATH: path,
}

enum pat_kind {
    WILD,
    BIND: str,     // n (a copy of the payload)
    BIND_REF: str, // n& (the payload in place, a T&)
    LIT: expr,
    RANGE: (expr, expr, bool),
    CTOR: (ctor_path, std::vec<pat>?),
    TUPLE: std::vec<pat>,
}

struct pat {
    kind: pat_kind;
    span: span;
}

struct block {
    stmts: std::vec<stmt>;
    span: span;
}

// a `val`/`var` binding; also a global (item_kind::GLOBAL)
struct let_stmt {
    mutable: bool;
    is_comptime: bool;
    is_static: bool;
    pat: pat;
    ty: ty?;
    init: expr?;
    span: span;
    c_name: str?; // a global defined by an imported C header (extern FILE* stderr)
}

// SUSPEND/RESUME are the `suspend;` and `resume frame;` statements of async fns
enum stmt_kind {
    LET: let_stmt,
    EXPR: expr,
    DEFER: expr,
    ERR_DEFER: expr,
    SUSPEND,
    RESUME: expr,
}

struct stmt {
    kind: stmt_kind;
    span: span;
}

// `internal` on an item or field; parsed and printed, not yet enforced by the checker
// public or internal on an item or field, or neither (DEFAULT): an unmarked item is internal in a
// package and public in the program's files; an unmarked field follows its struct
enum vis {
    DEFAULT,
    PUBLIC,
    INTERNAL,
}

// one `<name: bounds = default>` template parameter
struct generic_param {
    name: str;
    bounds: std::vec<ty>;
    pack: bool;
    fallback: garg?; // the default
    span: span;
}

struct param {
    name: str; // "this" for the receiver
    ty: ty?;
    fallback: expr?; // the default
    mutable: bool;
    // `static this`: the fn attaches to the type but takes no receiver value
    is_static: bool;
    is_comptime: bool;
    span: span;
}

// a fn declaration; body is null for a declaration without one (extern fns, trait requirements), spec is
// set on an explicit specialization of a template
struct fn_decl {
    name: str;
    spec: std::vec<garg>?;
    params: std::vec<param>;
    c_varargs: bool;
    ret: ty?;
    body: block?;
    is_async: bool;
    is_comptime: bool;
    extern_abi: str?;
    is_export: bool;
    is_attach: bool;
}

struct field {
    name: str;
    ty: ty;
    fallback: expr?;
    vis: vis;
    span: span;
    attrs: std::vec<expr> = {}; // a library's attributes (@typeinfo's field_info.attributes)
}

struct struct_decl {
    name: str;
    spec: std::vec<garg>?;
    fields: std::vec<field>;
    is_extern: bool;
    is_comptime: bool;
    c_name: str?; // defined by an imported C header under this C type name
    c_partial: bool = false; // ...with members Volt can't read (bitfields, unions): layout only C knows
    c_union: bool = false; // ...a C union: its fields share offset 0
    // ...whose fields share bytes (an anonymous union member): each field's byte offset, and C's size
    // and alignment, for the LLVM backend to place them
    c_offsets: std::vec<u64>? = null;
    c_size: u64 = 0;
    c_align: u64 = 0;
    is_export: bool = false; // export struct: other languages hold it by a handle (voltc bindings)
}

// an enum variant: `NAME: payload` or `NAME = value`
struct variant {
    name: str;
    payload: ty?;
    value: expr?;
    span: span;
}

struct enum_decl {
    name: str;
    backing: ty?;
    variants: std::vec<variant>;
    is_error: bool;
}

// ATTACH is `attach Trait -> Target { fns }`; USE_C is `use { "header.h" } as alias;`
enum item_kind {
    FN: fn_decl,
    STRUCT: struct_decl,
    ENUM: enum_decl,
    TRAIT: (str, std::vec<item>),
    ATTACH: (ty, ty, std::vec<item>),
    NAMESPACE: (std::vec<str>, std::vec<item>),
    USE: path,
    USE_C: (std::vec<std::string>, str),
    USE_CPP: (std::vec<std::string>, str), // `use cpp { "shapes.hpp" } as shapes;` (cppimport.volt)
    USE_LANG: (str, std::vec<std::string>, str), // `use rust { "geom" } as geom;`: language, arguments, alias (langimport.volt)
    GLOBAL: let_stmt,
    ALIAS: (str, ty), // another name for a type: `type name = T;`, or a C typedef (cimport.volt)
    EMIT: expr, // `@emit(code);`: the declarations a comptime str of Volt source holds (a quote, usually)
}

// a top-level declaration with its `@attributes(...)` and the `<...>` generic params written before it
struct item {
    kind: item_kind;
    span: span;
    attrs: std::vec<expr>;
    vis: vis;
    generics: std::vec<generic_param>;
}
