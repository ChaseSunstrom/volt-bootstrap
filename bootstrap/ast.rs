// Syntax tree. Kept close to the source; the checker decides what names mean
// (type vs value vs trait), since the parser can't know that.
use crate::diag::Span;

/// a boxed child node
pub type P<T> = Box<T>;

/// a name, maybe qualified and with generic args on any segment: `std::vec<i32>::new`
#[derive(Clone, Debug)]
pub struct Path {
    pub segs: Vec<PathSeg>,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct PathSeg {
    pub name: String,
    pub args: Option<Vec<GenericArg>>,
}

impl Path {
    pub fn single(name: &str, span: Span) -> Path {
        Path { segs: vec![PathSeg { name: name.to_string(), args: None }], span }
    }
    pub fn last(&self) -> &str {
        &self.segs.last().unwrap().name
    }
    /// a bare name: one segment, no generic args
    pub fn is_single(&self) -> bool {
        self.segs.len() == 1 && self.segs[0].args.is_none()
    }
}

/// one argument in `<...>`. Whatever parses as a type becomes Type (so a plain name is always Type); the
/// checker decides whether it names a type or a value
#[derive(Clone, Debug)]
pub enum GenericArg {
    Type(Type),
    Expr(Expr),
}

#[derive(Clone, Debug)]
pub struct Type {
    pub kind: TypeKind,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum TypeKind {
    Path(Path),                            // i32, example, std::mem::box<T>, shape, type, void
    Ref(P<Type>),                          // T&: a reference, never null
    Ptr(P<Type>),                          // T*: a raw pointer, may be null
    Optional(P<Type>),                     // T?
    Array(P<Type>, Option<P<Expr>>),       // T[N], T[] (None = length from the initializer)
    Slice(P<Type>),                        // T[..]
    Tuple(Vec<(Option<String>, Type)>),    // (T, U), (x: T, y: U), ()
    ErrorUnion(Option<P<Type>>, P<Type>),  // E!T, !T (None = inferred)
    Fn { params: Vec<Type>, c_varargs: bool, ret: P<Type>, extern_c: bool },
    Pack(P<Type>),                         // Args... (param types) / type... (generic bounds)
    Expr(P<Expr>),                         // a comptime call that returns a type: pick(true)
}

#[derive(Clone, Debug)]
pub struct Expr {
    pub kind: ExprKind,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinOp {
    Add, Sub, Mul, Div, Rem,
    WAdd, WSub, WMul, // +% -% *%
    And, Or,          // && ||
    BitAnd, BitOr, BitXor, Shl, Shr,
    Eq, Ne, Lt, Gt, Le, Ge,
}

impl BinOp {
    /// the operator as it's written, for messages
    pub fn text(self) -> &'static str {
        use BinOp::*;
        match self {
            Add => "+",
            Sub => "-",
            Mul => "*",
            Div => "/",
            Rem => "%",
            WAdd => "+%",
            WSub => "-%",
            WMul => "*%",
            And => "&&",
            Or => "||",
            BitAnd => "&",
            BitOr => "|",
            BitXor => "^",
            Shl => "<<",
            Shr => ">>",
            Eq => "==",
            Ne => "!=",
            Lt => "<",
            Gt => ">",
            Le => "<=",
            Ge => ">=",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Not,    // !
    BitNot, // ~
    Addr,   // &
    Deref,  // *
}

#[derive(Clone, Debug)]
pub struct Capture {
    pub name: String,
    pub mode: CapMode,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapMode {
    Copy,
    Ref,
    Move,
}

/// the label of the block a struct update `{ ..base, a: x }` is parsed into, and its temporary (a
/// hidden local: source can't name either)
pub const UPDATE_LABEL: &str = "@update";
pub const UPDATE_TMP: &str = "@base";
/// `if (val v = e)` and `while (val x = e)` are parsed into labeled blocks too: these labels, and a
/// hidden local holding e (a nested one shadows it, as a nested scope may)
pub const IF_LABEL: &str = "@if";
pub const ELSE_LABEL: &str = "@else";
pub const IF_TMP: &str = "@if";

/// `Int` holds the literal's magnitude; a leading `-` is Unary(Neg, ..)
#[derive(Clone, Debug)]
pub enum ExprKind {
    Int(u128),
    Float(f64),
    Char(u32),
    Str(Vec<u8>),
    Bool(bool),
    Null,
    This,
    ErrorAny,                     // bare `error`
    Path(Path),                   // x, a::b, generic_enum<f32>::VALUE, i32 (types are values too)
    DotVariant(String),           // .VALUE, type comes from context
    Unary(UnOp, P<Expr>),
    Binary(BinOp, P<Expr>, P<Expr>),
    /// `a = b`, or `a op= b` with Some(op)
    Assign(Option<BinOp>, P<Expr>, P<Expr>),
    IncDec(P<Expr>, bool),        // x++ (true), x-- (false)
    Cast(P<Expr>, Type),          // x as T
    Range(Option<P<Expr>>, Option<P<Expr>>, bool), // a..b, a..=b (inclusive), open ends for slicing
    Call(P<Expr>, Vec<Expr>),
    Field(P<Expr>, String, Option<Vec<GenericArg>>), // a.b, a.0, a.malloc<T>
    Index(P<Expr>, P<Expr>),
    Builtin(String, Vec<GenericArg>, Option<Vec<GenericArg>>), // @name<generic>(args); args None = no parens
    Tuple(Vec<Expr>),
    Literal(Vec<(Option<String>, Expr)>), // { a, b: c } or { 1, 2 }, typed by context
    Repeat(P<Expr>, P<Expr>),     // { x; n }: an array of n copies of x, typed by context
    Closure { caps: Vec<Capture>, generics: Vec<GenericParam>, params: Vec<Param>, ret: Option<Type>, body: Block },
    Quote(Vec<QuotePart>), // quote { Volt source with $(splices) }: a comptime str
    Try(P<Expr>),
    Await(P<Expr>),
    Async(P<Expr>),               // async f(): start without waiting
    Move(P<Expr>),
    Copy(P<Expr>),
    Catch(P<Expr>, Option<(String, Span)>, P<Expr>), // e catch |err| handler
    OrElse(P<Expr>, P<Expr>),     // a ?? b
    Return(Option<P<Expr>>),
    Break(Option<String>, Option<P<Expr>>),
    Continue(Option<String>),
    Block(Option<String>, Block), // { } as a statement, or :label { } as an expression
    Loop(Option<String>, Block),
    While(Option<String>, P<Expr>, Block),
    For(P<ForLoop>),
    If { cond: P<Expr>, then: Block, els: Option<P<Expr>>, comptime: bool },
    Match { scrut: P<Expr>, arms: Vec<Arm>, comptime: bool },
}

/// `for (v, i) in iter => map [var acc: T = init] { body }`. `=> map` replaces the element with the mapped
/// value each iteration; the `[..]` accumulator is declared before the loop and is the loop's value
#[derive(Clone, Debug)]
pub struct ForLoop {
    pub label: Option<String>,
    pub bindings: Vec<(String, bool, Span)>, // name, by reference (s&)
    pub iter: Expr,
    pub map: Option<Expr>,                   // => expr
    pub acc: Option<Let>,                    // [ var result: i32 = 0 ]
    pub body: Block,
    pub comptime: bool,
}

/// one `pat if guard => body` arm of a match
#[derive(Clone, Debug)]
pub struct Arm {
    pub pat: Pat,
    pub guard: Option<Expr>,
    pub body: Expr,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct Pat {
    pub kind: PatKind,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum CtorPath {
    Dot(String), // .VALUE
    Path(Path),  // generic_enum::VALUE, circle
}

/// a match or let pattern
#[derive(Clone, Debug)]
pub enum PatKind {
    Wild,                                   // default, _
    Bind(String),                           // n (a copy of the payload)
    BindRef(String),                        // n& (the payload in place, a T&)
    Lit(Expr),                              // 0, 'a', "x", true, null, -1
    Range(Expr, Expr, bool),                // 1..=9
    Ctor(CtorPath, Option<Vec<Pat>>),       // .VALUE(v), some_error::BLAH, circle(c)
    Tuple(Vec<Pat>),                        // (a, b)
}

#[derive(Clone, Debug)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    pub span: Span,
}

/// a `val`/`var` binding; also a global (ItemKind::Global)
#[derive(Clone, Debug)]
pub struct Let {
    pub mutable: bool,
    pub comptime: bool,
    pub is_static: bool,
    pub pat: Pat, // Bind(name) or Tuple
    pub ty: Option<Type>,
    pub init: Option<Expr>,
    pub span: Span,
    pub c_name: Option<String>, // a global defined by an imported C header (extern FILE* stderr)
}

#[derive(Clone, Debug)]
pub struct Stmt {
    pub kind: StmtKind,
    pub span: Span,
}

/// Suspend/Resume are the `suspend;` and `resume frame;` statements of async fns
#[derive(Clone, Debug)]
pub enum StmtKind {
    Let(Let),
    Expr(Expr),
    Defer(Expr),
    ErrDefer(Expr),
    Suspend,
    Resume(Expr),
}

/// `public` or `internal` on an item or field, or neither (Default): an unmarked item is internal in a
/// package and public in the program's files; an unmarked field follows its struct
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Vis {
    #[default]
    Default,
    Public,
    Internal,
}

/// one `<name: bounds = default>` template parameter
#[derive(Clone, Debug)]
pub struct GenericParam {
    pub name: String,
    pub bounds: Vec<Type>,            // `type`, traits, or a value type (const param)
    pub pack: bool,                   // <Args: type...>
    pub default: Option<GenericArg>,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct Param {
    pub name: String, // "this" for the receiver
    pub ty: Option<Type>,
    pub default: Option<Expr>,
    pub mutable: bool,
    /// `static this`: the fn attaches to the type but takes no receiver value
    pub is_static: bool,
    pub comptime: bool,
    pub span: Span,
}

/// a fn declaration; body is None for a declaration without one (extern fns, trait requirements)
#[derive(Clone, Debug)]
pub struct FnDecl {
    pub name: String,
    /// set on an explicit specialization of a template
    pub spec: Option<Vec<GenericArg>>, // fn type_name<bool>(...)
    pub params: Vec<Param>,
    pub c_varargs: bool,
    pub ret: Option<Type>,
    pub body: Option<Block>,
    pub is_async: bool,
    pub is_comptime: bool,
    pub extern_abi: Option<String>,
    pub is_export: bool,
    pub is_attach: bool,
}

#[derive(Clone, Debug)]
pub struct Field {
    pub name: String,
    pub ty: Type,
    pub default: Option<Expr>,
    pub vis: Vis,
    pub span: Span,
    pub attrs: Vec<Expr>, // a library's attributes (@typeinfo's field_info.attributes)
}

#[derive(Clone, Debug)]
pub struct StructDecl {
    pub name: String,
    pub spec: Option<Vec<GenericArg>>, // struct holder<T*>
    pub fields: Vec<Field>,
    pub is_extern: bool,
    pub is_comptime: bool,
    pub c_name: Option<String>, // defined by an imported C header under this C type name
    pub c_union: bool,          // ...a C union: its fields share offset 0
}

/// an enum variant: `NAME: payload` or `NAME = value`
#[derive(Clone, Debug)]
pub struct Variant {
    pub name: String,
    pub payload: Option<Type>,
    pub value: Option<Expr>,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct EnumDecl {
    pub name: String,
    pub backing: Option<Type>,
    pub variants: Vec<Variant>,
    pub is_error: bool,
}

/// a top-level declaration with its `@attributes(...)` and the `<...>` generic params written before it
#[derive(Clone, Debug)]
pub struct Item {
    pub kind: ItemKind,
    pub span: Span,
    pub attrs: Vec<Expr>,
    pub vis: Vis,
    pub generics: Vec<GenericParam>,
}

/// AttachBlock is `attach Trait -> Target { fns }`; Namespace is `namespace a::b { items }`; UseC is
/// `use { "header.h" } as alias;`
#[derive(Clone, Debug)]
pub enum ItemKind {
    Fn(FnDecl),
    Struct(StructDecl),
    Enum(EnumDecl),
    Trait { name: String, fns: Vec<Item> },
    AttachBlock { trait_: Type, target: Type, fns: Vec<Item> },
    Namespace(Vec<String>, Vec<Item>),
    Use(Path),
    UseC { headers: Vec<String>, alias: String },
    /// `use cpp { "shapes.hpp" } as shapes;`: C++ headers (read by the self-hosted voltc)
    UseCpp { headers: Vec<String>, alias: String },
    /// `use rust { "geom" } as geom;`: code in another language (the self-hosted voltc's)
    UseLang { lang: String, args: Vec<String>, alias: String },
    Global(Let),
    /// another name for a type: `type name = T;`, or a C typedef (cimport.rs)
    Alias(String, Type),
    /// `@emit(code);`: the declarations a comptime str of Volt source holds (a quote, usually)
    Emit(Expr),
}

/// a quote's source text, and the values spliced into it
#[derive(Clone, Debug)]
pub enum QuotePart {
    Text(String),
    Splice(Expr),
}
