// Type checker + C code generator. Each function instance is checked and emitted in one pass;
// every expression lowers to a single C expression string (GNU statement expressions when it
// needs statements), so C evaluation order and short-circuiting stay intact.
mod asyncs;
mod calls;
mod closures;
mod comptime;
mod cty;
mod enums;
mod errors;
mod expr;
mod generics;
mod lends;
pub use lends::{Body, Via};
mod matching;
mod operators;
mod ownership;
mod places;
mod print;
mod stmt;
mod suggest;

use crate::ast::*;
use cty::c_field;
use crate::diag::{Diag, Res, SourceMap, Span, err};
use crate::types::*;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
pub use enums::EnumInfo;
pub use generics::UnionInfo;
pub use closures::ClosureInfo;

pub type DeclId = usize;
pub type NsId = usize;

/// a collected item: the namespace and file it was declared in, and its enclosing trait or attach block
pub struct Decl {
    pub item: Rc<Item>,
    pub ns: NsId,
    pub file: u32,
    pub parent: Option<DeclId>, // enclosing trait or attach block
}

/// a namespace: its declared names (fn overloads and specializations share one), child namespaces
/// and `use` imports
#[derive(Default)]
pub struct Ns {
    pub path: Vec<String>,
    pub parent: Option<NsId>,
    pub names: HashMap<String, Vec<DeclId>>,
    pub children: HashMap<String, NsId>,
    pub uses: Vec<Path>, // `use a::b::c;` makes c's members (or c itself) reachable as a::name
}

/// a generic argument's value: a type, an integer, a type pack (T...) or a string
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum GVal {
    Ty(TyId),
    Int(i128),
    Pack(Vec<TyId>),
    Str(Vec<u8>),
}

/// what a template body sees: its namespace and the generic params bound so far (searched from the end)
#[derive(Clone)]
pub struct Env {
    pub ns: NsId,
    pub generics: Vec<(String, GVal)>,
}

/// a resolved struct field; default is its initializer from the declaration, for literals that
/// leave the field out
#[derive(Clone)]
pub struct FieldInfo {
    pub name: String,
    pub ty: TyId,
    pub default: Option<Expr>,
}

/// one struct instance (a struct decl with one set of generic args); its fields resolve on first use
/// (struct_fields)
pub struct StructInfo {
    pub decl: DeclId,
    pub family: DeclId,    // the primary (unspecialized) decl
    pub args: Vec<GVal>,   // generic args as written for the primary
    pub env: Rc<Env>,
    pub name: String,
    pub c_name: String,
    pub fields: Option<Rc<Vec<FieldInfo>>>,
    pub resolving: bool,
    pub owns: Option<(String, TyId)>, // @owns("field"): an owning pointer to TyId through that field
}

#[derive(Clone)]
pub struct ParamInfo {
    pub name: String,
    pub ty: TyId,
    pub mutable: bool,
    pub default: Option<Expr>,
    pub comptime: bool, // known at compile time: part of the instance, not a C parameter
}

/// one fn instance: a decl with one set of generic args, its resolved signature and C name. Its body
/// is checked later (gen_fn), once something uses it
#[derive(Clone)]
pub struct FnInst {
    pub decl: DeclId,
    pub name: String,
    pub pack: bool, // last param collects the rest of the args as a tuple
    pub env: Rc<Env>,
    pub c_name: String,
    pub params: Vec<ParamInfo>,
    pub ret: TyId,
    pub c_varargs: bool,
    /// `@intrinsic("name")`: a compiler builtin, or a prelude C function when the name starts with volt_
    pub intrinsic: Option<String>,
    /// where the instance was first asked for (errors in a template's body point back to it)
    pub used_at: Span,
}

/// a local variable in scope: its C name, type and ownership bookkeeping
#[derive(Clone)]
pub struct Local {
    pub c: String,
    pub ty: TyId,
    pub mutable: bool,
    /// a reference (or pointer, or slice) local: what it points at (see Val's ro, via, root)
    pub ro: u32,
    pub via: Via,
    pub root: Option<String>,
    /// a parameter of the fn (for messages: "a parameter without var")
    pub param: bool,
    /// the local whose storage this is (its C name: itself, or the one an if narrowed)
    pub own: Option<String>,
    pub orig: Option<(String, TyId)>, // narrowed by if/while: the original variable (a pointer one re-checks on read: narrow_recheck)
    pub flag: Option<String>,          // owned local that needs delete: its C "still live" flag
    pub loops: usize,                  // loops around the declaration
}

/// one block's locals, comptime constants and the cleanups that run when it ends
#[derive(Default)]
pub struct Scope {
    pub vars: HashMap<String, Local>,
    pub consts: HashMap<String, (comptime::CVal, bool)>, // comptime var/val: value, mutable
    pub exits: Vec<Exit>, // run in reverse when the scope ends
    pub barrier: bool,    // locals above this aren't visible (default args)
}

/// a cleanup registered in a scope: a defer, or deleting an owned local (drop is its C delete fn)
/// if its flag says it's still live
#[derive(Clone)]
pub enum Exit {
    Defer(Expr, bool), // expr, errdefer only
    Drop { c: String, drop: String, flag: String },
}

/// a loop or labeled block being checked: the C labels break/continue jump to, and where break
/// values go
pub struct LoopCx {
    pub label: Option<String>,
    pub is_block: bool,
    pub brk: String,
    pub cont: Option<String>,
    pub result: Option<String>, // C variable for break values
    pub break_ty: Option<TyId>,
    pub has_break: bool,
    pub depth: usize,                                      // scope depth outside the loop
    pub moved_at_break: std::collections::HashSet<String>, // moved when some break left the loop
}

/// the state of the fn instance being checked; replaced for each instance (and swapped out while a
/// global's initializer is checked)
pub struct FnCx {
    pub ret: TyId,
    pub env: Rc<Env>,
    pub scopes: Vec<Scope>,
    pub loops: Vec<LoopCx>,
    pub next_id: u32,
    pub moved: std::collections::HashSet<String>, // locals (C names) moved on some path so far
    pub move_sites: HashMap<String, Span>,        // where each moved local was last moved (for messages)
    /// the receiver temporaries a statement makes (slot, type, live flag): they live to the end of the
    /// statement (a val's to the end of its scope, a for loop's iterable's to the end of the loop), so a
    /// view into one (`f().as_str()`, `f().items()`) stays valid. None where they're deleted at once
    pub keep_temps: Option<Vec<(String, TyId, String)>>,
    pub keep_scope: usize, // the scope whose exits delete them (early exits included)
    pub exiting: u32,                              // inside a return/break value
    pub reassigning: Option<String>,               // `x = f(move x)`: x gets a new value right away
    pub frame: Option<usize>,                      // generating this async fn's step function
    pub suspends: Vec<Span>,                       // suspend points so far (state n = index + 1)
    pub no_suspend: u32,                           // inside code where suspend can't go (defers)
    pub call_mode: Option<(Span, bool)>,           // the call at this span starts a frame (true) or is awaited
    pub body: Option<Body>,                        // the fn instance or closure being checked (lends.rs)
    pub var_params: Vec<(String, String, bool)>,   // its var parameters: C name, name, changed yet
}

impl FnCx {
    pub fn new(ret: TyId, env: Rc<Env>) -> FnCx {
        FnCx {
            ret,
            env,
            scopes: vec![Scope::default()],
            loops: Vec::new(),
            next_id: 0,
            moved: Default::default(),
            move_sites: Default::default(),
            keep_temps: None,
            keep_scope: 0,
            exiting: 0,
            reassigning: None,
            frame: None,
            suspends: Vec::new(),
            no_suspend: 0,
            call_mode: None,
            body: None,
            var_params: Vec::new(),
        }
    }
}

/// A checked expression: its type and C code. For void/never types `c` is a C statement.
#[derive(Clone, Debug)]
pub struct Val {
    pub ty: TyId,
    pub c: String,
    pub lv: bool,      // C lvalue
    pub mutable: bool, // may be assigned
    pub pure: bool,    // no side effects, safe to evaluate in any order
    pub lit: Option<Lit>,
    pub owner: Option<String>, // set when this is an owned local (so using it by value moves it)
    /// A reference, pointer or slice value: where it points at what can't change (ro, by depth: a
    /// val, a parameter without var, or through another such reference), and which of the fn's
    /// reference parameters' memory it points at (via). A place: it was reached through a read-only
    /// reference (rop), and which parameter memory it is (pvia). root: the variable it all belongs
    /// to, for messages. See lends.rs
    pub ro: u32,
    pub via: Via,
    pub rop: bool,
    pub pvia: Via,
    pub root: Option<String>,
    /// a place in a local's own storage (the local's C name): changing it needs the local's var
    pub own: Option<String>,
}

/// a call lending a read-only reference to a parameter, an error if the callee writes through it
#[derive(Clone)]
pub struct Lend {
    pub span: Span,
    pub callee: Body,
    pub param: usize,
    pub mask: u32, // the depths that can't change
    pub root: String,
    /// the root is a parameter (without var), not a val
    pub root_param: bool,
}

/// a literal's value, kept on a Val so the literal can still adapt to the type it ends up as
#[derive(Clone, Debug, PartialEq)]
pub enum Lit {
    Int(i128),
    Float(f64),
    Str(Vec<u8>),
}

impl Val {
    pub fn new(ty: TyId, c: impl Into<String>) -> Val {
        Val { ty, c: c.into(), lv: false, mutable: false, pure: false, lit: None, owner: None, ro: 0, via: None, rop: false, pvia: None, root: None, own: None }
    }
    pub fn pure(ty: TyId, c: impl Into<String>) -> Val {
        Val { pure: true, ..Val::new(ty, c) }
    }
    pub fn stmt(c: impl Into<String>) -> Val {
        Val::new(VOID, c)
    }
}

/// where a fn's C definition lives (see Checker::linkage)
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Linkage {
    Static,   // defined in this C unit, private to it
    Exported, // defined here, visible to other units (export fns, a library's own fns)
    External, // defined in a linked library: only declared here
}

/// compiler options that change the generated C
pub struct Opts {
    pub release: bool,
    pub leak_check: bool,
    pub runtime: bool,       // define the runtime (runtime/runtime.h) in this C unit
    pub pkg_files: HashMap<u32, String>, // file -> its package (std's files may use @intrinsic)
    pub lib: Option<String>,             // building this package into a library (voltc lib), no main
    pub linked: Vec<String>,             // packages whose non-generic code comes from a prebuilt library
    pub guards: Vec<(String, String)>,   // package -> guard symbol: the library defines it, programs need it
    pub cfg: Vec<(Option<String>, String)>, // --cfg: package (None: the program's files), KEY or KEY=VALUE
    pub pp_flags: Vec<String>,              // the --cc flags the C preprocessor needs (-I, -D...)
}

/// all compiler state: declarations, namespaces, instances, types, and the C text built so far
pub struct Checker {
    pub sm: SourceMap,
    pub opts: Opts,
    pub t: Types,
    pub decls: Vec<Decl>,
    pub nss: Vec<Ns>,
    pub structs: Vec<StructInfo>,
    pub struct_ids: HashMap<(DeclId, Vec<GVal>), u32>,
    pub enums: Vec<EnumInfo>,
    pub enum_ids: HashMap<(DeclId, Vec<GVal>), u32>,
    pub error_names: std::collections::BTreeMap<u32, (String, String)>, // code -> (variant, qualified name)
    pub attached: HashMap<String, Vec<DeclId>>,
    pub attach_blocks: Vec<DeclId>,
    pub unions: Vec<UnionInfo>,
    pub union_ids: HashMap<DeclId, u32>,
    pub fns: Vec<FnInst>,
    pub fn_ids: HashMap<(DeclId, Vec<GVal>), usize>,
    /// fn instances already used (prototype emitted, body queued): use_fn
    pub used: std::collections::HashSet<usize>,
    /// used fn instances whose bodies haven't been checked yet: program pops them into gen_fn
    pub queue: Vec<usize>,
    pub cx: FnCx,
    // output
    pub c_names: HashMap<TyId, String>,
    pub protos: String,
    pub bodies: String,
    pub globals: String,
    pub global_c: HashMap<DeclId, (String, TyId, bool)>,
    pub used_c_names: HashMap<String, u32>,
    pub c_symbols: HashMap<String, (DeclId, Vec<TyId>, TyId)>, // extern/export fns by C name
    /// needs_drop's answer per type
    pub drop_memo: HashMap<TyId, bool>,
    /// hook's answer per (type, name): the attached delete/copy/as_str instance, if any
    pub hook_memo: HashMap<(TyId, &'static str), Option<usize>>,
    /// generated per-type C helpers ("drop", "copy") by name; their code goes to glue
    pub glue_names: HashMap<(TyId, &'static str), String>,
    pub glue: String,
    pub glue_protos: String,
    pub closures: Vec<ClosureInfo>,
    /// comptime interpreter call frames, and the step count that stops runaway evaluation
    pub ct: Vec<comptime::CtFrame>,
    pub ct_steps: u64,
    /// deprecated decls already warned about (once each)
    pub warned: std::collections::HashSet<DeclId>,
    /// warnings so far, printed with the errors (or on their own when there are none)
    pub warnings: Vec<Diag>,
    /// errors from functions already checked (the run goes on to the others)
    pub errors: Vec<Diag>,
    /// what each body writes through its reference parameters (one flag a parameter), the
    /// parameters it passes on to others' (caller, its param, callee, its param), and the calls
    /// lending a read-only reference, checked once every body is (check_lends)
    pub writes: HashMap<Body, Vec<u64>>,
    pub edges: Vec<(Body, usize, i32, Body, usize)>,
    pub lends: Vec<Lend>,
    /// calls whose result is a reference, and where each body's returned references point (lends.rs)
    pub sites: Vec<lends::Site>,
    pub rets: Vec<(Body, u32, i32)>,
    /// copy and as_str hooks: called on vals (to copy or print them), so they only read this
    pub ro_hooks: Vec<usize>,
    /// var parameters per fn decl: name, where, and whether any instance changes it
    pub var_seen: Vec<(DeclId, String, Span, bool)>,
    pub frames: HashMap<usize, Vec<(String, TyId)>>, // async fn instance -> frame fields (params, locals, flags)
    pub c_includes: Vec<String>,                     // #include lines for imported C headers
    pub c_imports: HashMap<(u8, String), DeclId>,    // an imported C symbol shared by every import of it
    pub aliases: HashMap<DeclId, TyId>,               // an alias decl's type, once resolved
    pub alias_resolving: HashSet<DeclId>,             // aliases being resolved (one that reaches itself is an error)
    pub importing_c: bool,                           // collecting a C import's items
}

impl Checker {
    pub fn new(sm: SourceMap, opts: Opts) -> Checker {
        Checker {
            sm,
            opts,
            t: Types::new(),
            decls: Vec::new(),
            nss: vec![Ns::default()],
            structs: Vec::new(),
            struct_ids: HashMap::new(),
            enums: Vec::new(),
            enum_ids: HashMap::new(),
            error_names: [(1, ("error".to_string(), "error".to_string()))].into_iter().collect(),
            attached: HashMap::new(),
            attach_blocks: Vec::new(),
            unions: Vec::new(),
            union_ids: HashMap::new(),
            fns: Vec::new(),
            fn_ids: HashMap::new(),
            used: Default::default(),
            queue: Vec::new(),
            cx: FnCx::new(VOID, Rc::new(Env { ns: 0, generics: Vec::new() })),
            c_names: HashMap::new(),
            protos: String::new(),
            bodies: String::new(),
            globals: String::new(),
            global_c: HashMap::new(),
            used_c_names: HashMap::new(),
            c_symbols: HashMap::new(),
            drop_memo: HashMap::new(),
            hook_memo: HashMap::new(),
            glue_names: HashMap::new(),
            glue: String::new(),
            glue_protos: String::new(),
            closures: Vec::new(),
            ct: Vec::new(),
            ct_steps: 0,
            warned: Default::default(),
            warnings: Vec::new(),
            errors: Vec::new(),
            writes: HashMap::new(),
            edges: Vec::new(),
            lends: Vec::new(),
            sites: Vec::new(),
            rets: Vec::new(),
            ro_hooks: Vec::new(),
            var_seen: Vec::new(),
            frames: HashMap::new(),
            c_includes: Vec::new(),
            c_imports: HashMap::new(),
            aliases: HashMap::new(),
            alias_resolving: HashSet::new(),
            importing_c: false,
        }
    }

    // ---------- declarations ----------

    /// the child namespace `name` of parent, made on first use
    fn ns_child(&mut self, parent: NsId, name: &str) -> NsId {
        if let Some(c) = self.nss[parent].children.get(name) {
            return *c;
        }
        let mut path = self.nss[parent].path.clone();
        path.push(name.to_string());
        self.nss.push(Ns { path, parent: Some(parent), ..Default::default() });
        let id = self.nss.len() - 1;
        self.nss[parent].children.insert(name.to_string(), id);
        id
    }

    /// declare a file's items in namespace ns. Nothing is resolved yet: types, instances and bodies
    /// are checked later, on demand from the program's roots
    pub fn collect(&mut self, items: Vec<Item>, ns: NsId) -> Res<()> {
        for item in items {
            self.collect_item(item, ns, None)?;
        }
        Ok(())
    }

    /// declare one item (and a trait's or attach block's fns, with it as their parent); attached fns
    /// also go into `attached`, found by method name
    fn collect_item(&mut self, item: Item, ns: NsId, parent: Option<DeclId>) -> Res<()> {
        let file = item.span.file;
        for a in &item.attrs {
            self.check_attr(a, file)?;
            if matches!(&a.kind, ExprKind::Builtin(n, _, _) if n == "thread_local") && !matches!(&item.kind, ItemKind::Global(l) if l.mutable) {
                return err(a.span, "@thread_local goes on a global var (each thread gets its own)");
            }
        }
        match item.kind {
            ItemKind::Namespace(path, items) => {
                let mut n = ns;
                for p in &path {
                    n = self.ns_child(n, p);
                }
                for it in items {
                    self.collect_item(it, n, None)?;
                }
                return Ok(());
            }
            ItemKind::Use(p) => {
                if p.segs.len() < 2 {
                    return err(p.span, "use needs a path like std::io");
                }
                self.nss[ns].uses.push(p);
                return Ok(());
            }
            ItemKind::UseC { headers, alias } => return self.import_c(&headers, &alias, ns, item.span),
            ItemKind::UseCpp { .. } => return err(item.span, "C++ headers (use cpp) are read by the self-hosted voltc; voltc-bootstrap reads only C headers"),
            ItemKind::UseLang { lang, .. } => return err(item.span, format!("use {lang} {{ ... }}: code in other languages is imported by the self-hosted voltc; voltc-bootstrap reads only C headers")),
            _ => {}
        }
        let name = match &item.kind {
            ItemKind::Fn(f) => Some(f.name.clone()),
            ItemKind::Struct(s) => Some(s.name.clone()),
            ItemKind::Enum(e) => Some(e.name.clone()),
            ItemKind::Alias(n, _) => Some(n.clone()),
            ItemKind::Trait { name, .. } => Some(name.clone()),
            ItemKind::Global(l) => match &l.pat.kind {
                PatKind::Bind(n) => Some(n.clone()),
                _ => return err(l.span, "global variables can't destructure"),
            },
            _ => None,
        };
        let id = self.decls.len();
        let inner: Vec<Item> = match &item.kind {
            ItemKind::AttachBlock { fns, .. } | ItemKind::Trait { fns, .. } => fns.clone(),
            _ => Vec::new(),
        };
        let is_block = matches!(item.kind, ItemKind::AttachBlock { .. });
        let is_attach_fn = matches!(&item.kind, ItemKind::Fn(f) if f.is_attach);
        let item = Rc::new(item);
        self.decls.push(Decl { item: item.clone(), ns, file, parent });
        if is_block {
            self.attach_blocks.push(id);
        }
        match (name, parent) {
            (Some(n), Some(p)) => {
                // fns inside attach blocks are methods of the target; trait fns are only signatures
                if matches!(self.decls[p].item.kind, ItemKind::AttachBlock { .. }) {
                    self.attached.entry(n).or_default().push(id);
                }
            }
            (Some(n), None) => {
                // one name, one thing: only fn overloads, attached fns (methods, whatever else has the
                // name) and a struct's specializations share a name (C headers do too, struct stat and
                // stat(): not checked while importing them)
                let clash = !self.importing_c
                    && self.nss[ns].names.get(&n).is_some_and(|ids| ids.iter().any(|&d| !Self::may_share(&self.decls[d].item.kind, &item.kind)));
                if clash {
                    let first = self.nss[ns].names[&n].iter().copied().find(|&d| !Self::may_share(&self.decls[d].item.kind, &item.kind)).unwrap();
                    let at = self.name_span(item.span, &n);
                    let before = self.name_span(self.decls[first].item.span, &n);
                    return Err(Diag::new(at, format!("'{n}' is already declared in this namespace")).label(before, "first declared here"));
                }
                if is_attach_fn {
                    self.attached.entry(n.clone()).or_default().push(id);
                }
                self.nss[ns].names.entry(n).or_default().push(id);
            }
            _ => {}
        }
        for f in inner {
            if !matches!(f.kind, ItemKind::Fn(_)) {
                return err(f.span, "only fns go inside trait and attach blocks");
            }
            self.collect_item(f, ns, Some(id))?;
        }
        Ok(())
    }

    /// may these two items have the same name in one namespace? fn overloads, attached fns, and a
    /// struct with its specializations
    fn may_share(a: &ItemKind, b: &ItemKind) -> bool {
        match (a, b) {
            (ItemKind::Fn(_), ItemKind::Fn(_)) => true,
            (ItemKind::Fn(f), _) | (_, ItemKind::Fn(f)) if f.is_attach => true,
            (ItemKind::Struct(x), ItemKind::Struct(y)) => x.spec.is_some() || y.spec.is_some(),
            _ => false,
        }
    }

    /// `use { "a.h" } as c;`: the headers' declarations become namespace `c`
    fn import_c(&mut self, headers: &[String], alias: &str, ns: NsId, span: Span) -> Res<()> {
        let file = &self.sm.files[span.file as usize].0;
        // headers next to the source file first; std (no file) only sees system headers
        let dir = match std::path::Path::new(file).parent() {
            _ if file.starts_with('<') => std::path::PathBuf::new(),
            Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
            _ => std::path::PathBuf::from("."),
        };
        let imp = crate::cimport::import(headers, &dir, &self.opts.pp_flags, span)?;
        for inc in imp.includes {
            if !self.c_includes.contains(&inc) {
                self.c_includes.push(inc);
            }
        }
        let n = self.ns_child(ns, alias);
        self.importing_c = true;
        let r = self.import_c_items(imp.items, n);
        self.importing_c = false;
        r
    }

    /// declare a C import's items in namespace n; a symbol imported before keeps its first decl
    fn import_c_items(&mut self, items: Vec<Item>, n: NsId) -> Res<()> {
        for item in items {
            let (key, name) = match &item.kind {
                ItemKind::Fn(f) => ((0, f.name.clone()), f.name.clone()),
                ItemKind::Struct(s) => ((1, s.c_name.clone().unwrap_or_default()), s.name.clone()),
                ItemKind::Global(Let { pat: Pat { kind: PatKind::Bind(b), .. }, .. }) => ((2, b.clone()), b.clone()),
                ItemKind::Alias(a, _) => ((3, a.clone()), a.clone()),
                _ => continue,
            };
            // the same C symbol imported again (another namespace, or std and the user) is one decl
            match self.c_imports.get(&key) {
                Some(&d) => {
                    let names = self.nss[n].names.entry(name).or_default();
                    if !names.contains(&d) {
                        names.push(d);
                    }
                }
                None => {
                    self.c_imports.insert(key, self.decls.len());
                    self.collect_item(item, n, None)?;
                }
            }
        }
        Ok(())
    }

    // ---------- lookup ----------

    /// Find a name from namespace `ns` outward. Returns decls, or a namespace.
    pub fn lookup(&self, ns: NsId, name: &str) -> Option<Found> {
        self.lookup_in(ns, name, false)
    }

    /// lookup; with prefix (the name is followed by `::`), a namespace wins over methods of the same name
    fn lookup_in(&self, ns: NsId, name: &str, prefix: bool) -> Option<Found> {
        let mut cur = Some(ns);
        while let Some(n) = cur {
            if let Some(f) = self.ns_member(n, name, prefix) {
                return Some(f);
            }
            cur = self.nss[n].parent;
        }
        None
    }

    /// methods are called as x.name(), never reached by path, so a path through `name::` means a
    /// namespace even when methods share its name
    fn only_methods(&self, ds: &[DeclId]) -> bool {
        ds.iter().all(|&d| matches!(self.recv_of(d), generics::Recv::Val(_)))
    }

    /// Resolve a whole path from namespace `ns`. The second segment may also come from a `use` of the
    /// first (via_uses).
    pub fn lookup_path_ns(&self, ns: NsId, p: &Path) -> Option<Found> {
        let mut found = self.lookup_in(ns, &p.segs[0].name, p.segs.len() > 1)?;
        for (i, seg) in p.segs[1..].iter().enumerate() {
            found = match found {
                Found::Ns(n) => match self.ns_member(n, &seg.name, i + 2 < p.segs.len()) {
                    // methods are called as x.name(), never by path: functions a use brings in take their place
                    Some(Found::Decls(ds)) if i == 0 && ds.iter().all(|&d| matches!(self.recv_of(d), generics::Recv::Val(_))) => {
                        match self.via_uses(ns, &p.segs[0].name, &seg.name) {
                            Some(Found::Decls(fns)) => Found::Decls(fns),
                            _ => Found::Decls(ds),
                        }
                    }
                    Some(f) => f,
                    None if i == 0 => self.via_uses(ns, &p.segs[0].name, &seg.name)?,
                    None => return None,
                },
                _ => return None,
            };
        }
        Some(found)
    }

    /// the part of a path that doesn't resolve, for error messages
    pub fn missing_part(&self, ns: NsId, p: &Path) -> String {
        if p.segs.len() > 1 && self.lookup(ns, &p.segs[0].name).is_none() {
            return p.segs[0].name.clone();
        }
        p.last().to_string()
    }

    /// a name declared directly in namespace n (no outward search); prefix as in lookup_in
    fn ns_member(&self, n: NsId, name: &str, prefix: bool) -> Option<Found> {
        let s = &self.nss[n];
        let child = s.children.get(name).map(|c| Found::Ns(*c));
        match s.names.get(name) {
            Some(ds) if prefix && child.is_some() && self.only_methods(ds) => child,
            Some(ds) => Some(Found::Decls(ds.clone())),
            None => child,
        }
    }

    /// `a::name` through `use a::...::x;` in scope: a member of x (x a namespace), or x itself.
    /// Functions from several imports merge into one overload set.
    fn via_uses(&self, ns: NsId, first: &str, name: &str) -> Option<Found> {
        let mut decls: Vec<DeclId> = Vec::new();
        let mut other = None;
        let mut cur = Some(ns);
        while let Some(n) = cur {
            for u in self.nss[n].uses.iter().filter(|u| u.segs[0].name == first) {
                // use paths are absolute and resolved without this fallback (no cycles)
                let mut target = Some(Found::Ns(0));
                for seg in &u.segs {
                    target = match target {
                        Some(Found::Ns(m)) => self.ns_member(m, &seg.name, true),
                        _ => None,
                    };
                }
                match target {
                    Some(Found::Ns(m)) => match self.ns_member(m, name, false) {
                        Some(Found::Decls(ds)) => decls.extend(ds),
                        Some(f) => other = other.or(Some(f)),
                        None => {}
                    },
                    Some(Found::Decls(ds)) if u.last() == name => decls.extend(ds),
                    _ => {}
                }
            }
            cur = self.nss[n].parent;
        }
        decls.sort();
        decls.dedup();
        if decls.is_empty() { other } else { Some(Found::Decls(decls)) }
    }

    // ---------- types ----------

    /// a type as it's written in Volt, for messages and instance names
    pub fn ty_name(&self, id: TyId) -> String {
        match self.t.get(id) {
            Ty::Void => "void".into(),
            Ty::Never => "never".into(),
            Ty::Bool => "bool".into(),
            Ty::TypeTy => "type".into(),
            Ty::Null => "null".into(),
            Ty::Str => "str".into(),
            Ty::CStr => "cstr".into(),
            Ty::VoidPtr => "void*".into(),
            Ty::Float(b) => format!("f{b}"),
            Ty::Int(k) => k.name().into(),
            Ty::Ref(t) => format!("{}&", self.ty_name(*t)),
            Ty::Ptr(t) => format!("{}*", self.ty_name(*t)),
            Ty::Opt(t) => format!("{}?", self.ty_name(*t)),
            Ty::Array(t, n) => format!("{}[{n}]", self.ty_name(*t)),
            Ty::Slice(t) => format!("{}[..]", self.ty_name(*t)),
            Ty::Tuple(ts, names) => {
                let parts: Vec<String> = ts
                    .iter()
                    .zip(names)
                    .map(|(t, n)| match n {
                        Some(n) => format!("{n}: {}", self.ty_name(*t)),
                        None => self.ty_name(*t),
                    })
                    .collect();
                format!("({})", parts.join(", "))
            }
            Ty::Range(t) => format!("range<{}>", self.ty_name(*t)),
            Ty::Struct(s) => self.structs[*s as usize].name.clone(),
            Ty::Enum(e) => self.enums[*e as usize].name.clone(),
            Ty::ErrUnion(e, t) => {
                // E!T& is a reference to an error union, so a payload with a suffix is parenthesized
                let payload = self.ty_name(*t);
                let payload = if matches!(self.t.get(*t), Ty::Ref(_) | Ty::Ptr(_) | Ty::Opt(_) | Ty::Array(..) | Ty::Slice(_)) { format!("({payload})") } else { payload };
                format!("{}!{payload}", if *e == ANYERR { String::new() } else { self.ty_name(*e) })
            }
            Ty::TraitUnion(u) => self.unions[*u as usize].name.clone(),
            Ty::Closure(c) if self.closures[*c as usize].generic.is_some() => {
                let g = self.closures[*c as usize].generic.as_ref().unwrap();
                format!("closure<{}>", g.gps.iter().map(|g| g.name.clone()).collect::<Vec<_>>().join(", "))
            }
            Ty::Closure(c) => {
                let ci = &self.closures[*c as usize];
                let ps: Vec<String> = ci.params.iter().map(|p| self.ty_name(*p)).collect();
                format!("closure({}) -> {}", ps.join(", "), self.ty_name(ci.ret))
            }
            Ty::Frame(i) => format!("frame of {}", self.fns[*i as usize].name),
            Ty::AnyErr => "error".into(),
            Ty::FnPtr(ps, r, _) => {
                let ps: Vec<String> = ps.iter().map(|p| self.ty_name(*p)).collect();
                format!("extern \"C\" fn({}) -> {}", ps.join(", "), self.ty_name(*r))
            }
            Ty::FnVal(ps, r) => {
                let ps: Vec<String> = ps.iter().map(|p| self.ty_name(*p)).collect();
                format!("fn({}) -> {}", ps.join(", "), self.ty_name(*r))
            }
        }
    }

    /// the type a type expression denotes in env (its generic params bound)
    pub fn resolve_type(&mut self, t: &Type, env: &Rc<Env>) -> Res<TyId> {
        Ok(match &t.kind {
            TypeKind::Path(p) => self.resolve_type_path(p, env)?,
            TypeKind::Ref(inner) => {
                let i = self.resolve_type(inner, env)?;
                if i == VOID {
                    return err(t.span, "void& isn't a type; an untyped pointer is void*");
                }
                self.t.intern(Ty::Ref(i))
            }
            TypeKind::Ptr(inner) => {
                let i = self.resolve_type(inner, env)?;
                if i == VOID {
                    VOIDPTR
                } else {
                    self.t.intern(Ty::Ptr(i))
                }
            }
            TypeKind::Optional(inner) => {
                match &inner.kind {
                    TypeKind::Ref(_) => return err(t.span, "a reference (T&) is never null, so it can't be optional; a pointer that may be null is T*"),
                    TypeKind::Ptr(_) => return err(t.span, "a pointer (T*) can already be null; drop the ?"),
                    _ => {}
                }
                let i = self.resolve_type(inner, env)?;
                self.t.intern(Ty::Opt(i))
            }
            TypeKind::Array(inner, n) => {
                let i = self.resolve_type(inner, env)?;
                match n {
                    Some(n) => {
                        let len = self.const_int(n, env)?;
                        let len = array_len(len, n.span)?;
                        self.t.intern(Ty::Array(i, len))
                    }
                    None => return err(t.span, "T[] takes its length from an initializer, so it only works on a var/val with one"),
                }
            }
            TypeKind::Slice(inner) => {
                let i = self.resolve_type(inner, env)?;
                self.t.intern(Ty::Slice(i))
            }
            TypeKind::Tuple(elems) => {
                let mut ts = Vec::new();
                let mut names = Vec::new();
                for (n, ty) in elems {
                    ts.push(self.resolve_type(ty, env)?);
                    names.push(n.clone());
                }
                if ts.is_empty() {
                    VOID
                } else {
                    self.t.intern(Ty::Tuple(ts, names))
                }
            }
            TypeKind::Fn { params, c_varargs, ret, extern_c } => {
                let mut ps = Vec::new();
                for p in params {
                    ps.push(self.resolve_type(p, env)?);
                }
                let r = self.resolve_type(ret, env)?;
                if *extern_c {
                    self.t.intern(Ty::FnPtr(ps, r, *c_varargs))
                } else if *c_varargs {
                    return err(t.span, "only extern \"C\" fn types can take C varargs");
                } else {
                    self.t.intern(Ty::FnVal(ps, r))
                }
            }
            TypeKind::ErrorUnion(e, inner) => {
                let e = match e {
                    Some(e) => {
                        let e_ty = self.resolve_type(e, env)?;
                        if !self.is_error_ty(e_ty) {
                            return err(e.span, format!("{} isn't an error set", self.ty_name(e_ty)));
                        }
                        e_ty
                    }
                    None => ANYERR,
                };
                let i = self.resolve_type(inner, env)?;
                self.t.intern(Ty::ErrUnion(e, i))
            }
            TypeKind::Pack(_) => return err(t.span, "a pack type (T...) only works on the last parameter"),
            TypeKind::Expr(e) => match self.ct_eval_in(env.clone(), e, Some(TYPE))? {
                comptime::CVal::Type(t) => t,
                _ => return err(e.span, "this doesn't give a type"),
            },
        })
    }

    /// A named type: a generic param, a primitive, a comptime type constant, or a struct, enum or
    /// trait decl instantiated with its generic args (a trait used as a type is a trait union).
    pub fn resolve_type_path(&mut self, p: &Path, env: &Rc<Env>) -> Res<TyId> {
        // a single name: a generic param, a primitive or a comptime type constant
        if p.is_single() {
            let name = &p.segs[0].name;
            if let Some((_, g)) = env.generics.iter().rev().find(|(n, _)| n == name).cloned() {
                return match g {
                    GVal::Ty(t) => Ok(t),
                    GVal::Int(_) | GVal::Str(_) => err(p.span, format!("'{name}' is a value, not a type")),
                    GVal::Pack(ts) if ts.is_empty() => Ok(VOID),
                    GVal::Pack(ts) => {
                        let n = ts.len();
                        Ok(self.t.intern(Ty::Tuple(ts, vec![None; n])))
                    }
                };
            }
            if let Some(t) = Types::primitive(name) {
                return Ok(t);
            }
            match self.const_local(name).or_else(|| self.ct.last().and_then(|f| f.scopes.iter().rev().find_map(|s| s.get(name).map(|x| x.0.clone())))) {
                Some(comptime::CVal::Type(t)) => return Ok(t),
                Some(comptime::CVal::Void) => return err(p.span, format!("'{name}' has no type assigned yet")),
                Some(_) => return err(p.span, format!("'{name}' is a value, not a type")),
                None => {}
            }
        }
        // otherwise a declared type: the primary decl of a struct, enum or trait, with its generic args
        let found = if p.segs.len() == 1 {
            self.lookup(env.ns, &p.segs[0].name)
        } else {
            self.lookup_path_ns(env.ns, p)
        };
        match found {
            Some(Found::Decls(ds)) => {
                let given = p.segs.last().unwrap().args.clone();
                let primary = ds.iter().copied().find(|d| match &self.decls[*d].item.kind {
                    ItemKind::Struct(s) => s.spec.is_none(),
                    ItemKind::Enum(_) | ItemKind::Trait { .. } | ItemKind::Alias(..) => true,
                    _ => false,
                });
                let Some(d) = primary else { return err(p.span, format!("'{}' isn't a type", p.last())) };
                self.visible(d, p.span)?;
                let generic = !self.decls[d].item.generics.is_empty();
                if !generic && given.is_some() {
                    return err(p.span, format!("'{}' isn't generic", p.last()));
                }
                // another name: its type, resolved where it's declared (once, unless it's generic:
                // then with the arguments given here)
                if let ItemKind::Alias(_, t) = &self.decls[d].item.kind {
                    if let Some(&have) = self.aliases.get(&d) {
                        return Ok(have);
                    }
                    let t = t.clone();
                    let generics = if generic {
                        let args = self.gargs_for(d, given.as_deref().unwrap_or(&[]), env, p.span)?;
                        self.decls[d].item.generics.iter().map(|g| g.name.clone()).zip(args).collect()
                    } else {
                        Vec::new()
                    };
                    let ae = Rc::new(Env { ns: self.decls[d].ns, generics });
                    if !self.alias_resolving.insert(d) {
                        return err(p.span, format!("type '{}' is defined in terms of itself", p.last()));
                    }
                    let r = self.resolve_type(&t, &ae);
                    self.alias_resolving.remove(&d);
                    let r = r?;
                    if !generic {
                        self.aliases.insert(d, r);
                    }
                    return Ok(r);
                }
                let args = if generic { self.gargs_for(d, given.as_deref().unwrap_or(&[]), env, p.span)? } else { Vec::new() };
                match &self.decls[d].item.kind {
                    ItemKind::Struct(_) => self.struct_inst(d, args, p.span),
                    ItemKind::Enum(_) => self.enum_inst(d, args, p.span),
                    _ if generic => err(p.span, "generic traits can't be used as types yet"),
                    _ => self.trait_union(d, p.span),
                }
            }
            Some(Found::Ns(_)) => err(p.span, format!("'{}' is a namespace, not a type", p.last())),
            None => Err(self.unknown(p.span, "type", env.ns, p, false)),
        }
    }

    /// The struct type for `decl` with these generic args, made once per argument set. It uses the
    /// matching specialization if there is one, and records @owns. Fields resolve later.
    pub fn struct_inst(&mut self, decl: DeclId, args: Vec<GVal>, span: Span) -> Res<TyId> {
        if let Some(id) = self.struct_ids.get(&(decl, args.clone())) {
            return Ok(self.t.intern(Ty::Struct(*id)));
        }
        let (item, dns) = (self.decls[decl].item.clone(), self.decls[decl].ns);
        let ItemKind::Struct(s) = &item.kind else { return err(span, "not a struct") };
        let path = self.nss[dns].path.clone();
        let mut name = if path.is_empty() { s.name.clone() } else { format!("{}::{}", path.join("::"), s.name) };
        let c_name = match &s.c_name {
            Some(c) => c.clone(),
            None => self.fresh_c_name(&format!("v_{}", name.replace("::", "__"))),
        };
        if !args.is_empty() {
            let a: Vec<String> = args.iter().map(|g| self.gval_name(g)).collect();
            name = format!("{name}<{}>", a.join(", "));
        }
        let (use_decl, binds) = self.pick_specialization(decl, &args)?;
        let gps = self.decls[use_decl].item.generics.clone();
        let env = self.inst_env(dns, &gps, &binds);
        let id = self.structs.len() as u32;
        self.structs.push(StructInfo { decl: use_decl, family: decl, args: args.clone(), env: env.clone(), name, c_name, fields: None, resolving: false, owns: None });
        self.struct_ids.insert((decl, args), id);
        // @attributes([@owns("ptr")]): the struct owns what field `ptr: T*` points at (like std's box):
        // it's used like that T&, and deleting it deletes the T first. Nothing here knows std
        let owner = self.decls[use_decl].item.attrs.iter().find_map(|a| match &a.kind {
            ExprKind::Builtin(n, _, _) if n == "owns" => Some((a.span, comptime::attr_str(a))),
            _ => None,
        });
        if let Some((aspan, fname)) = owner {
            let ItemKind::Struct(sd) = &self.decls[use_decl].item.kind.clone() else { unreachable!() };
            let Some(f) = fname.as_ref().and_then(|n| sd.fields.iter().find(|f| &f.name == n)) else {
                return err(aspan, "@owns names a field of this struct: @owns(\"ptr\")");
            };
            let fty = self.resolve_type(&f.ty, &env)?;
            let (Ty::Ref(inner) | Ty::Ptr(inner)) = self.t.get(fty).clone() else { return err(f.span, "an @owns field has to be a pointer (T*)") };
            self.structs[id as usize].owns = Some((f.name.clone(), inner));
        }
        Ok(self.t.intern(Ty::Struct(id)))
    }

    /// a partial specialization (struct holder<T&>) whose pattern matches these args, if any
    fn pick_specialization(&mut self, primary: DeclId, args: &[GVal]) -> Res<(DeclId, Vec<GVal>)> {
        let name = self.decl_name(primary);
        let ns = self.decls[primary].ns;
        let cands = self.nss[ns].names.get(&name).cloned().unwrap_or_default();
        for d in cands {
            let item = self.decls[d].item.clone();
            let ItemKind::Struct(StructDecl { spec: Some(pats), .. }) = &item.kind else { continue };
            if pats.len() != args.len() {
                continue;
            }
            let gps = item.generics.clone();
            // bind the specialization's own generic params by matching its pattern against the args
            let mut binds = vec![None; gps.len()];
            for (pat, a) in pats.iter().zip(args) {
                match (pat, a) {
                    (GenericArg::Type(t), GVal::Ty(at)) => self.infer(t, *at, &gps, &mut binds, ns),
                    (GenericArg::Expr(Expr { kind: ExprKind::Path(p), .. }), GVal::Int(v)) if p.is_single() => {
                        if let Some(i) = gps.iter().position(|g| g.name == p.segs[0].name) {
                            binds[i] = Some(GVal::Int(*v));
                        }
                    }
                    _ => {}
                }
            }
            if binds.iter().any(|b| b.is_none()) {
                continue;
            }
            // then the pattern, with those bindings, has to give back exactly the args
            let env = self.partial_env(ns, &gps, &binds);
            let mut ok = true;
            for (pat, a) in pats.iter().zip(args) {
                let got = match (pat, a) {
                    (_, GVal::Ty(_)) => self.garg_type_env(pat, &env).ok().map(GVal::Ty),
                    (GenericArg::Expr(e), GVal::Int(_)) => self.const_int(e, &env).ok().map(GVal::Int),
                    _ => None,
                };
                ok &= got.as_ref() == Some(a);
            }
            if ok {
                return Ok((d, binds.into_iter().map(Option::unwrap).collect()));
            }
        }
        Ok((primary, args.to_vec()))
    }

    /// a struct instance's fields, resolved on first use; fails if the struct contains itself by value
    pub fn struct_fields(&mut self, sid: u32, span: Span) -> Res<Rc<Vec<FieldInfo>>> {
        if let Some(f) = &self.structs[sid as usize].fields {
            return Ok(f.clone());
        }
        if self.structs[sid as usize].resolving {
            return err(span, format!("struct '{}' contains itself (use a reference or box)", self.structs[sid as usize].name));
        }
        self.structs[sid as usize].resolving = true;
        let decl = self.structs[sid as usize].decl;
        let env = self.structs[sid as usize].env.clone();
        let item = self.decls[decl].item.clone();
        let ItemKind::Struct(s) = &item.kind else { unreachable!() };
        let mut out = Vec::new();
        for f in &s.fields {
            let ty = self.resolve_type(&f.ty, &env)?;
            out.push(FieldInfo { name: f.name.clone(), ty, default: f.default.clone() });
        }
        let rc = Rc::new(out);
        self.structs[sid as usize].fields = Some(rc.clone());
        self.structs[sid as usize].resolving = false;
        Ok(rc)
    }

    /// an env in ns with params bound to args, pairwise
    pub fn inst_env(&self, ns: NsId, params: &[GenericParam], args: &[GVal]) -> Rc<Env> {
        Rc::new(Env { ns, generics: params.iter().zip(args).map(|(p, a)| (p.name.clone(), a.clone())).collect() })
    }

    /// a generic argument as it's written, for instance names
    pub fn gval_name(&self, g: &GVal) -> String {
        match g {
            GVal::Ty(t) => self.ty_name(*t),
            GVal::Int(v) => v.to_string(),
            GVal::Pack(ts) => ts.iter().map(|t| self.ty_name(*t)).collect::<Vec<_>>().join(", "),
            GVal::Str(s) => format!("{:?}", String::from_utf8_lossy(s)),
        }
    }

    /// a C name no one has taken yet: base, else base_2, base_3, ...
    pub fn fresh_c_name(&mut self, base: &str) -> String {
        let mut n = self.used_c_names.get(base).copied().unwrap_or(0);
        loop {
            n += 1;
            // base_2 may already be a name of its own (a fn called foo_2): skip it
            let cand = if n == 1 { base.to_string() } else { format!("{base}_{n}") };
            if n == 1 || !self.used_c_names.contains_key(&cand) {
                self.used_c_names.insert(base.to_string(), n);
                self.used_c_names.entry(cand.clone()).or_insert(1);
                return cand;
            }
        }
    }

    /// Where a fn's C definition lives. Package fns that are the same in every program (not
    /// generic, not async, no trait union in the signature, whose member set is whole-program)
    /// can come from the package's prebuilt library.
    pub fn linkage(&mut self, idx: usize) -> Linkage {
        let d = self.fns[idx].decl;
        let ItemKind::Fn(f) = &self.decls[d].item.kind else { return Linkage::Static };
        if f.extern_abi.is_some() || f.is_export {
            return Linkage::Exported;
        }
        let Some(pkg) = self.pkg_of(d).map(String::from) else { return Linkage::Static };
        let (lib, linked) = (self.opts.lib.as_deref() == Some(pkg.as_str()), self.opts.linked.contains(&pkg));
        // a specialization (fn f<i64>) is built where it's used, like the template it specializes: a
        // library has nothing calling it
        if !(lib || linked) || f.body.is_none() || f.is_async || f.is_comptime || self.fns[idx].intrinsic.is_some() || !self.fn_generics(d).is_empty() || f.spec.is_some() {
            return Linkage::Static;
        }
        let sig: Vec<TyId> = self.fns[idx].params.iter().map(|p| p.ty).chain([self.fns[idx].ret]).collect();
        let mut seen = std::collections::HashSet::new();
        if sig.into_iter().any(|t| self.has_union(t, &mut seen)) {
            return Linkage::Static;
        }
        if lib { Linkage::Exported } else { Linkage::External }
    }

    /// does a value of this type hold a trait union somewhere?
    fn has_union(&mut self, t: TyId, seen: &mut std::collections::HashSet<TyId>) -> bool {
        if !seen.insert(t) {
            return false;
        }
        let inner: Vec<TyId> = match self.t.get(t).clone() {
            Ty::TraitUnion(_) => return true,
            Ty::Ref(x) | Ty::Ptr(x) | Ty::Opt(x) | Ty::Array(x, _) | Ty::Slice(x) | Ty::Range(x) => vec![x],
            Ty::Tuple(ts, _) => ts,
            Ty::ErrUnion(e, x) => vec![e, x],
            Ty::FnVal(ps, r) | Ty::FnPtr(ps, r, _) => ps.into_iter().chain([r]).collect(),
            // a struct that can't be resolved reports its own error where it's used; here it just
            // counts as union-free
            Ty::Struct(s) => self.struct_fields(s, Span::default()).map(|f| f.iter().map(|f| f.ty).collect()).unwrap_or_default(),
            Ty::Enum(e) => self.enum_payloads(e, Span::default()).map(|p| p.iter().flatten().copied().collect()).unwrap_or_default(),
            _ => Vec::new(),
        };
        inner.into_iter().any(|x| self.has_union(x, seen))
    }

    /// the package a decl comes from (None for the program's own files)
    pub fn pkg_of(&self, decl: DeclId) -> Option<&str> {
        self.opts.pkg_files.get(&self.decls[decl].file).map(|s| s.as_str())
    }

    /// An internal item belongs to its package: only that package's files may use it (the program's
    /// own files, for the program's). A template's body is judged by the file it's written in.
    pub fn visible(&self, decl: DeclId, span: Span) -> Res<()> {
        if self.decls[decl].item.vis != Vis::Internal {
            return Ok(());
        }
        let owner = self.pkg_of(decl);
        if owner == self.opts.pkg_files.get(&span.file).map(|s| s.as_str()) {
            return Ok(());
        }
        let whose = match owner {
            Some(p) => format!("package {p}"),
            None => "the program".to_string(),
        };
        err(span, format!("'{}' is internal to {whose}", self.decl_name(decl)))
    }

    // ---------- constants ----------

    /// Integer constant expressions: literals, arithmetic, generic consts.
    pub fn const_int(&mut self, e: &Expr, env: &Rc<Env>) -> Res<i128> {
        match self.const_int_simple(e, env) {
            Ok(v) => Ok(v),
            Err(first) => match self.ct_eval_in(env.clone(), e, None) {
                Ok(comptime::CVal::Int(v, _)) => Ok(v),
                Ok(_) => err(e.span, "expected an integer"),
                Err(d) if d.msg.contains("compile") || d.msg.contains("overflow") => Err(d),
                Err(_) => Err(first),
            },
        }
    }

    /// const_int without the comptime interpreter: literals, integer operators, generic ints and
    /// immutable globals
    fn const_int_simple(&mut self, e: &Expr, env: &Rc<Env>) -> Res<i128> {
        let bad = || err(e.span, "expected a constant integer expression");
        Ok(match &e.kind {
            ExprKind::Int(v) => *v as i128,
            ExprKind::Char(v) => *v as i128,
            ExprKind::Unary(UnOp::Neg, x) => -self.const_int_simple(x, env)?,
            ExprKind::Unary(UnOp::BitNot, x) => !self.const_int_simple(x, env)?,
            ExprKind::Binary(op, a, b) => {
                let (a, b) = (self.const_int_simple(a, env)?, self.const_int_simple(b, env)?);
                use BinOp::*;
                let r = match op {
                    Add | WAdd => a.checked_add(b),
                    Sub | WSub => a.checked_sub(b),
                    Mul | WMul => a.checked_mul(b),
                    Div => a.checked_div(b),
                    Rem => a.checked_rem(b),
                    BitAnd => Some(a & b),
                    BitOr => Some(a | b),
                    BitXor => Some(a ^ b),
                    Shl => u32::try_from(b).ok().and_then(|b| a.checked_shl(b)),
                    Shr => u32::try_from(b).ok().and_then(|b| a.checked_shr(b)),
                    _ => return bad(),
                };
                match r {
                    Some(r) => r,
                    None => return err(e.span, "constant overflow or division by zero"),
                }
            }
            ExprKind::Path(p) if p.is_single() => match env.generics.iter().rev().find(|(n, _)| *n == p.segs[0].name) {
                Some((_, GVal::Int(v))) => *v,
                _ => match self.lookup(env.ns, &p.segs[0].name) {
                    Some(Found::Decls(ds)) if ds.len() == 1 => match &self.decls[ds[0]].item.clone().kind {
                        ItemKind::Global(l) if !l.mutable && l.init.is_some() => self.const_int_simple(l.init.as_ref().unwrap(), env)?,
                        _ => return bad(),
                    },
                    _ => return bad(),
                },
            },
            _ => return bad(),
        })
    }

    /// "file:line:col" for runtime messages
    pub fn loc(&self, span: Span) -> String {
        let (l, c) = self.sm.line_col(span);
        let name = &self.sm.files[span.file as usize].0;
        format!("{name}:{l}:{c}")
    }

    // ---------- functions ----------

    /// The fn instance for `decl` with these generic args, made once per argument set: resolves the
    /// signature, picks the C name and claims extern/export C symbols. Doesn't check the body or emit
    /// anything; use_fn does that once the instance is called.
    pub fn fn_inst(&mut self, decl: DeclId, args: Vec<GVal>, span: Span) -> Res<usize> {
        if let Some(i) = self.fn_ids.get(&(decl, args.clone())) {
            return Ok(*i);
        }
        let (item, dns) = (self.decls[decl].item.clone(), self.decls[decl].ns);
        let ItemKind::Fn(f) = &item.kind else { return err(span, "not a function") };
        let gps = self.fn_generics(decl);
        if gps.len() != args.len() {
            return err(span, format!("'{}' needs its generic arguments: {}<...>", f.name, f.name));
        }
        // a template that recurses into ever new instances of itself would never stop
        let family_count = self.fn_ids.keys().filter(|(d, _)| *d == decl).count();
        if family_count > 500 {
            return err(span, format!("'{}' was instantiated over 500 times; is a generic recursing forever?", f.name));
        }
        let env = self.inst_env(dns, &gps, &args);
        let mut params = Vec::new();
        let mut pack = false;
        // the signature: `this` takes its type from the receiver pattern; a pack param (xs: T...) has the
        // tuple type its pack resolves to
        for p in &f.params {
            if p.name == "this" {
                if p.is_static {
                    continue;
                }
                let pat = match self.recv_of(decl) {
                    generics::Recv::Val(t) => t,
                    _ => return err(p.span, "this needs a type here: this: T or this: T&"),
                };
                let ty = self.resolve_type(&pat, &env)?;
                params.push(ParamInfo { name: "this".into(), ty, mutable: p.mutable, default: None, comptime: false });
                continue;
            }
            let Some(pt) = &p.ty else { return err(p.span, "parameter needs a type") };
            let ty = match &pt.kind {
                TypeKind::Pack(inner) => {
                    pack = true;
                    self.resolve_type(inner, &env)?
                }
                _ => self.resolve_type(pt, &env)?,
            };
            params.push(ParamInfo { name: p.name.clone(), ty, mutable: p.mutable, default: p.default.clone(), comptime: p.comptime });
        }
        let ret = match &f.ret {
            Some(r) => self.resolve_type(r, &env)?,
            None => VOID,
        };
        let intrinsic = item.attrs.iter().find_map(|a| match &a.kind {
            ExprKind::Builtin(n, _, Some(args)) if n == "intrinsic" => match args.first() {
                Some(GenericArg::Expr(Expr { kind: ExprKind::Str(s), .. })) => Some(String::from_utf8_lossy(s).into_owned()),
                _ => None,
            },
            _ => None,
        });
        let path = self.nss[dns].path.clone();
        let c_name = if let Some(c) = intrinsic.as_ref().filter(|i| i.starts_with("volt_")) {
            c.clone() // a prelude function
        } else if f.extern_abi.as_deref() == Some("C") && !f.is_export {
            // declared under our own name, bound to the real symbol (VOLT_SYM in fn_header), so
            // it never clashes with a C header's prototype of the same function
            format!("volt_ext_{}", f.name)
        } else if f.extern_abi.is_some() || f.is_export {
            f.name.clone()
        } else if f.name == "main" && path.is_empty() && args.is_empty() {
            "v_main".to_string()
        } else if self.pkg_of(decl).is_some() && args.is_empty() {
            // a package fn gets the same name in every C unit, so a precompiled package links
            let full = format!("{}__{}", path.join("__"), f.name);
            let sig: Vec<String> = params.iter().map(|p| self.ty_name(p.ty)).chain([self.ty_name(ret)]).collect();
            let n = format!("vp_{full}_{:08x}", fnv32(&sig.join(",")));
            self.used_c_names.insert(n.clone(), 1);
            n
        } else {
            let full = if path.is_empty() { f.name.clone() } else { format!("{}__{}", path.join("__"), f.name) };
            self.fresh_c_name(&format!("v_{full}"))
        };
        let mut name = f.name.clone();
        if !args.is_empty() {
            let a: Vec<String> = args.iter().map(|g| self.gval_name(g)).collect();
            name = format!("{name}<{}>", a.join(", "));
        }
        if intrinsic.is_none() && f.body.is_none() && f.extern_abi.is_none() {
            return err(item.span, format!("function '{}' needs a body (only extern fns can leave it off)", f.name));
        }
        if f.extern_abi.is_some() || f.is_export {
            // C has no overloading: one symbol, one signature
            let sig = (params.iter().map(|p| p.ty).collect::<Vec<_>>(), ret);
            if let Some((other, ps, r)) = self.c_symbols.get(&f.name) {
                let other_export = matches!(&self.decls[*other].item.kind, ItemKind::Fn(o) if o.is_export);
                // a header's own prototype wins in C, so its Volt view may differ from an extern's
                let header = |d: DeclId| matches!(&self.decls[d].item.kind, ItemKind::Fn(o) if o.extern_abi.as_deref() == Some(crate::cimport::C_HEADER));
                let differs = (ps, r) != (&sig.0, &sig.1) && !header(*other) && !header(decl);
                if *other != decl && (f.is_export || other_export || differs) {
                    return err(item.span, format!("C function '{c_name}' is declared twice; exported and extern names can't be overloaded"));
                }
            }
            self.c_symbols.insert(f.name.clone(), (decl, sig.0, sig.1));
        }
        let idx = self.fns.len();
        self.fns.push(FnInst { decl, name, pack, env, c_name, params, ret, c_varargs: f.c_varargs, intrinsic, used_at: span });
        self.fn_ids.insert((decl, args), idx);
        Ok(idx)
    }

    /// the C declarator of a fn instance; `named` gives the parameters their names (for the definition)
    fn fn_header(&mut self, idx: usize, named: bool) -> String {
        let inst = self.fns[idx].clone();
        let ret = if self.is_async_fn(idx) {
            self.frame_cty(idx)
        } else if inst.ret == NEVER {
            "_Noreturn void".to_string()
        } else {
            self.cty(inst.ret)
        };
        let mut ps: Vec<String> = Vec::new();
        // comptime params are baked in; an empty pack (void) has no value to pass
        for (i, p) in inst.params.iter().enumerate().filter(|(_, p)| !p.comptime && p.ty != VOID) {
            let t = self.cty(p.ty);
            ps.push(if named { format!("{t} {}_{i}", p.name) } else { t });
        }
        if inst.c_varargs {
            ps.push("...".into());
        }
        if ps.is_empty() {
            ps.push("void".into());
        }
        let storage = if self.linkage(idx) == Linkage::Static { "static " } else { "" };
        let attrs = self.c_attrs(&self.decls[inst.decl].item.attrs.clone());
        // the symbol goes on the prototype: C allows no asm label on a definition
        let symbol = match inst.c_name.strip_prefix("volt_ext_") {
            Some(real) if !named => format!(" VOLT_SYM(\"{real}\")"),
            _ => String::new(),
        };
        format!("{attrs}{storage}{ret} {}({}){symbol}", inst.c_name, ps.join(", "))
    }

    /// add a fn instance's C prototype (and an async fn's helper prototypes) to the output
    pub fn emit_proto(&mut self, idx: usize) {
        if matches!(&self.decls[self.fns[idx].decl].item.kind, ItemKind::Fn(f) if f.extern_abi.as_deref() == Some(crate::cimport::C_HEADER)) {
            return; // the #included header declares it
        }
        let h = self.fn_header(idx, false);
        self.protos.push_str(&h);
        self.protos.push_str(";\n");
        if self.is_async_fn(idx) {
            let p = self.async_protos(idx);
            self.protos.push_str(&p);
        }
    }

    /// Check a fn instance's body and emit its C definition. Parameters become locals of the outermost
    /// scope; an async fn's body becomes the step function of its frame (gen_async).
    fn gen_fn(&mut self, idx: usize) -> Res<()> {
        let inst = self.fns[idx].clone();
        let item = self.decls[inst.decl].item.clone();
        let ItemKind::Fn(f) = &item.kind else { unreachable!() };
        let body = f.body.as_ref().unwrap();
        self.cx = FnCx::new(inst.ret, inst.env.clone());
        self.cx.body = Some(Body::Fn(idx));
        if f.is_async {
            if f.extern_abi.is_some() || f.is_export || inst.c_name == "v_main" {
                return err(item.span, "main, extern and export fns can't be async");
            }
            if inst.ret == NEVER {
                return err(item.span, "an async fn can't return never");
            }
            self.cx.frame = Some(idx);
            self.frames.insert(idx, Vec::new());
        }
        let mut flags = String::new();
        let mut param_cs = Vec::new();
        for (i, p) in inst.params.iter().enumerate().filter(|(_, p)| !p.comptime) {
            // frame fields share one struct with the locals, so they take unique ids too
            let c = if f.is_async { self.slot(&p.name, p.ty) } else { format!("{}_{i}", p.name) };
            param_cs.push(c.clone());
            // a reference (pointer, slice) parameter: what it reaches is reached through parameter i
            let via = self.reaches(p.ty).then_some((i as u32, 0));
            let mut local = Local { c: c.clone(), ty: p.ty, mutable: p.mutable, orig: None, flag: None, loops: 0, ro: 0, via, root: Some(p.name.clone()), param: true, own: Some(c.clone()) };
            // var this takes the receiver by value (it consumes it): that's what its var is for
            if p.mutable && p.name != "this" {
                self.cx.var_params.push((c.clone(), p.name.clone(), false));
            }
            if self.needs_drop(p.ty)? {
                // by-value params are owned by the callee
                let flag = self.flag_for(&c);
                flags.push_str(&format!("{}; ", Self::decl("bool", &flag, "true")));
                let drop = self.drop_fn(p.ty)?;
                self.cx.scopes[0].exits.push(Exit::Drop { c: c.clone(), drop, flag: flag.clone() });
                local.flag = Some(flag);
            }
            self.cx.scopes[0].vars.insert(p.name.clone(), local);
        }
        let generic = !self.fn_generics(inst.decl).is_empty();
        let (mut code, mut diverges) = self.block_code(body).map_err(|d| {
            // an error in a template's body belongs to one instance: say which, and where it came from
            if generic { d.label(inst.used_at, format!("{} is instantiated here", inst.name)) } else { d }
        })?;
        self.note_var_params(inst.decl, f);
        if !self.cx.scopes[0].exits.is_empty() {
            // params: deleted when the body finishes without returning
            let at_end = if diverges { String::new() } else { self.scope_exit_code(0, 0, false)? };
            code = format!("{{ {flags}{code} {at_end}}}");
        }
        if !diverges && matches!(self.t.get(inst.ret), Ty::ErrUnion(_, VOID)) {
            let rc = self.cty(inst.ret);
            code = format!("{{ {code} {}; }}", self.fn_exit(Some(format!("(({rc}){{0}})")), ""));
            diverges = true;
        }
        if !diverges && inst.ret != VOID {
            return err(body.span, format!("'{}' can reach its end without returning a {}", f.name, self.ty_name(inst.ret)));
        }
        if f.is_async {
            if !diverges {
                code = format!("{{ {code} {}; }}", self.fn_exit(None, ""));
            }
            return self.gen_async(idx, code, &param_cs);
        }
        let header = self.fn_header(idx, true);
        self.bodies.push_str(&format!("{header} {code}\n\n"));
        Ok(())
    }

    // ---------- globals ----------

    /// A global's C name, type and mutability. The first use checks its initializer (which must be
    /// constant) and emits its C definition.
    pub fn global(&mut self, decl: DeclId, span: Span) -> Res<(String, TyId, bool)> {
        if let Some(g) = self.global_c.get(&decl) {
            return Ok(g.clone());
        }
        let item = self.decls[decl].item.clone();
        let ItemKind::Global(l) = &item.kind else { unreachable!() };
        let PatKind::Bind(name) = &l.pat.kind else { unreachable!() };
        if let (Some(c), Some(t)) = (&l.c_name, &l.ty) {
            // defined by an imported header
            let env = Rc::new(Env { ns: self.decls[decl].ns, generics: Vec::new() });
            let g = (c.clone(), self.resolve_type(t, &env)?, l.mutable);
            self.global_c.insert(decl, g.clone());
            return Ok(g);
        }
        let env = Rc::new(Env { ns: self.decls[decl].ns, generics: Vec::new() });
        let path = self.nss[self.decls[decl].ns].path.clone();
        let full = path.iter().chain([name]).cloned().collect::<Vec<_>>().join("__");
        let c = if self.pkg_of(decl).is_some() {
            // stable across C units, like package fns
            self.used_c_names.insert(format!("vpg_{full}"), 1);
            format!("vpg_{full}")
        } else {
            self.fresh_c_name(&format!("vg_{full}"))
        };
        // check the initializer in an empty function context: it must be a constant
        let saved = std::mem::replace(
            &mut self.cx,
            FnCx::new(VOID, env.clone()),
        );
        let res = (|| -> Res<(TyId, String)> {
            let want = match &l.ty {
                Some(t) => Some(self.decl_type(t, l.init.as_ref())?), // T[] takes its length from the initializer
                None => None,
            };
            let v = match &l.init {
                Some(init) => {
                    let v = self.expr(init, want)?;
                    match want {
                        Some(w) => self.coerce(v, w, init.span)?,
                        None => v,
                    }
                }
                None => match want {
                    Some(w) => Val::new(w, "{0}"),
                    None => return err(span, "global needs a type or an initializer"),
                },
            };
            if !v.pure && v.lit.is_none() && l.init.is_some() {
                return err(l.init.as_ref().unwrap().span, "global initializers must be constants");
            }
            Ok((v.ty, v.c))
        })();
        self.cx = saved;
        let (ty, init) = res?;
        let cty = self.cty(ty);
        let konst = if l.mutable { "" } else { "const " };
        let pkg = self.pkg_of(decl).map(String::from);
        let tls = if item.attrs.iter().any(|a| matches!(&a.kind, ExprKind::Builtin(n, _, _) if n == "thread_local")) { "_Thread_local " } else { "" };
        if pkg.is_some() && self.opts.linked.contains(pkg.as_ref().unwrap()) {
            self.globals.push_str(&format!("extern {tls}{konst}{cty} {c};\n")); // defined in the package's library
        } else {
            let storage = if pkg.is_some() && self.opts.lib == pkg { "" } else { "static " };
            self.globals.push_str(&format!("{storage}{tls}{konst}{cty} {c} = {init};\n"));
        }
        let g = (c, ty, l.mutable);
        self.global_c.insert(decl, g.clone());
        Ok(g)
    }

    // ---------- program ----------

    /// check the whole program from its roots (main, and every non-generic fn) and build the C file
    pub fn program(&mut self) -> Res<String> {
        let lib = self.opts.lib.clone();
        let main = match (&lib, self.nss[0].names.get("main")) {
            (Some(_), _) => None,
            (None, Some(ds)) => Some(ds[0]),
            (None, None) => return Err(Diag::new(Span::NONE, "no main function").help("a program starts at fn main() -> void { ... }")),
        };
        let mi = match main {
            Some(m) => {
                let i = self.fn_inst(m, Vec::new(), self.decls[m].item.span)?;
                self.use_fn(i);
                Some(i)
            }
            None => None,
        };
        // every non-generic fn is a root, used or not, so its body is always checked (templates
        // are checked per instance, like C++); exported fns have to exist for C anyway.
        // A library only roots its own package
        for d in 0..self.decls.len() {
            let ItemKind::Fn(f) = &self.decls[d].item.kind else { continue };
            let in_trait = matches!(self.decls[d].parent.map(|p| &self.decls[p].item.kind), Some(ItemKind::Trait { .. }));
            let mine = lib.is_none() || self.pkg_of(d) == lib.as_deref();
            if mine && (f.is_export || (f.body.is_some() && f.spec.is_none() && !f.is_comptime && !in_trait && self.fn_generics(d).is_empty())) {
                match self.fn_inst(d, Vec::new(), self.decls[d].item.span) {
                    Ok(i) => self.use_fn(i),
                    Err(e) => self.errors.push(e),
                }
            }
        }
        // a library defines every global of its package: a template that a program instantiates may
        // use one the library's own code never does
        if lib.is_some() {
            for d in 0..self.decls.len() {
                if matches!(self.decls[d].item.kind, ItemKind::Global(_)) && self.pkg_of(d) == lib.as_deref() {
                    if let Err(e) = self.global(d, self.decls[d].item.span) {
                        self.errors.push(e);
                    }
                }
            }
        }
        self.check_traits();
        // an error stops only its own function: the others are still checked, so one run finds
        // every independent error (--error-limit picks how many are shown)
        while let Some(i) = self.queue.pop() {
            let depth = self.ct.len();
            if let Err(e) = self.gen_fn(i) {
                self.ct.truncate(depth);
                self.errors.push(e);
            }
        }
        // what can't change, lent to fns that write through it (lends.rs)
        self.check_lends();
        self.warn_var_params();
        if !self.errors.is_empty() {
            return Ok(String::new()); // compile() reports self.errors
        }
        // the guard symbol ties a program to the exact library build it was checked against
        let mut guards = String::new();
        for (pkg, g) in self.opts.guards.clone() {
            if lib.as_deref() == Some(pkg.as_str()) {
                guards.push_str(&format!("const char {g} = 0;\n"));
            } else if self.opts.linked.contains(&pkg) {
                guards.push_str(&format!("extern const char {g};\n__attribute__((used)) static const void *{g}_ref = &{g};\n"));
            }
        }
        let Some(mi) = mi else {
            return self.c_unit(&guards, String::new());
        };
        let main = main.unwrap();
        let ret = self.fns[mi].ret;
        // main's result as an int expression
        let main_val = if ret == VOID {
            "({ v_main(); 0; })".to_string()
        } else if self.t.int_of(ret).is_some() {
            "((int)v_main())".to_string()
        } else if let Ty::ErrUnion(_, t) = self.t.get(ret).clone() {
            if t != VOID && self.t.int_of(t).is_none() {
                return err(self.decls[main].item.span, "main must return void or an integer");
            }
            let rc = self.cty(ret);
            let code = self.eu_code(ret, "_r");
            let ok = if t == VOID { "0".to_string() } else { "(int)_r.v".to_string() };
            format!("({{ {rc} _r = v_main(); int _code; if ({code}) {{ volt_dprintf(2, \"error: %s\\n\", volt_err_name({code})); _code = 1; }} else _code = {ok}; _code; }})")
        } else {
            return err(self.decls[main].item.span, "main must return void or an integer");
        };
        if !self.fns[mi].params.is_empty() {
            return err(self.decls[main].item.span, "main takes no parameters");
        }
        let main_call = if self.opts.leak_check && !self.opts.release {
            format!("int _rc = {main_val}; if (volt_live_allocs) {{ volt_dprintf(2, \"leak: %zu allocation(s) never freed\\n\", volt_live_allocs); return 102; }} return _rc;")
        } else {
            format!("return {main_val};")
        };
        let main_fn = format!("int main(int argc, char **argv) {{ volt_argc = argc; volt_argv = argv; {main_call} }}\n");
        self.c_unit(&guards, main_fn)
    }

    /// a trait's fns are signatures only; each attach block names a trait it may use and holds
    /// every fn the trait requires, taking as many arguments
    fn check_traits(&mut self) {
        for d in 0..self.decls.len() {
            let r = match &self.decls[d].item.kind {
                ItemKind::Trait { .. } => self.check_trait(d),
                ItemKind::AttachBlock { .. } => self.check_attach_block(d),
                _ => Ok(()),
            };
            if let Err(e) = r {
                self.errors.push(e);
            }
        }
    }

    fn check_trait(&self, d: DeclId) -> Res<()> {
        let ItemKind::Trait { fns, .. } = &self.decls[d].item.kind else { return Ok(()) };
        for f in fns {
            if let ItemKind::Fn(fd) = &f.kind {
                if fd.body.is_some() {
                    return err(self.name_span(f.span, &fd.name), "a trait fn is only a signature; its body goes in each attach block");
                }
            }
        }
        Ok(())
    }

    fn check_attach_block(&mut self, b: DeclId) -> Res<()> {
        let item = self.decls[b].item.clone();
        let ItemKind::AttachBlock { trait_, fns, .. } = &item.kind else { return Ok(()) };
        let ns = self.decls[b].ns;
        let TypeKind::Path(p) = &trait_.kind else { return err(trait_.span, "an attach block names a trait: attach t_name -> type { ... }") };
        let Some((tr, _)) = self.bound_trait(trait_, ns) else {
            let found = if p.segs.len() == 1 { self.lookup(ns, &p.segs[0].name) } else { self.lookup_path_ns(ns, p) };
            if matches!(found, Some(Found::Decls(_))) {
                return err(trait_.span, format!("'{}' isn't a trait", p.last()));
            }
            return Err(self.unknown(trait_.span, "trait", ns, p, false));
        };
        self.visible(tr, trait_.span)?;
        let ItemKind::Trait { name: tname, fns: required } = &self.decls[tr].item.kind else { return Ok(()) };
        let args = |f: &FnDecl| match f.params.iter().filter(|q| q.name != "this").count() {
            0 => "no arguments".to_string(),
            1 => "1 argument".to_string(),
            n => format!("{n} arguments"),
        };
        for r in required {
            let ItemKind::Fn(rf) = &r.kind else { continue };
            let wanted = self.name_span(r.span, &rf.name);
            // the block's fns of that name (overloads): one has to take the trait's arguments
            let same: Vec<(Span, &FnDecl)> = fns
                .iter()
                .filter_map(|f| match &f.kind {
                    ItemKind::Fn(g) if g.name == rf.name => Some((f.span, g)),
                    _ => None,
                })
                .collect();
            let Some(&(at, g)) = same.first() else {
                let msg = format!("this attach block is missing fn '{}', which trait '{tname}' requires", rf.name);
                return Err(Diag::new(trait_.span, msg).label(wanted, "required here"));
            };
            if !same.iter().any(|(_, g)| args(g) == args(rf)) {
                let msg = format!("'{}' takes {} here but {} in trait '{tname}'", g.name, args(g), args(rf));
                return Err(Diag::new(self.name_span(at, &g.name), msg).label(wanted, "declared here"));
            }
        }
        Ok(())
    }

    /// the whole C file around the generated code
    fn c_unit(&mut self, guards: &str, main_fn: String) -> Res<String> {
        self.check_frame_cycles()?;
        let types = self.type_defs()?;
        let errs = self.error_table();
        let mut defines = String::new();
        if !self.opts.release {
            defines.push_str("#define VOLT_DEBUG_ALLOC 1\n");
        }
        let includes: String = self.c_includes.iter().map(|i| format!("{i}\n")).collect();
        let runtime = if self.opts.runtime { include_str!("../../runtime/runtime.h") } else { "" };
        Ok(format!(
            "{defines}{}{runtime}\n{includes}/* types */\n{types}\n{errs}\n/* functions */\n{}{}\n/* globals */\n{}{guards}\n{}{}{main_fn}",
            include_str!("../../runtime/prelude.h"),
            self.protos,
            self.glue_protos,
            self.globals,
            self.bodies,
            self.glue
        ))
    }
}

/// what a name resolves to: its decls (an overload set when there are several), or a namespace
#[derive(Clone, Debug)]
pub enum Found {
    Decls(Vec<DeclId>),
    Ns(NsId),
}

/// Compile a whole program to one C file: collect every file's items into the root namespace, then
/// generate from the roots. An error comes back with the source map, to render it.
/// check the program and generate its C: the diagnostics (warnings, and errors if any) and the C
/// when there were no errors
pub fn compile(sm: SourceMap, files: Vec<Vec<Item>>, opts: Opts) -> (SourceMap, Vec<Diag>, Option<String>) {
    let mut c = Checker::new(sm, opts);
    let r = (|| {
        for f in files {
            c.collect(f, 0)?;
        }
        c.program()
    })();
    let mut errors = std::mem::take(&mut c.errors);
    let out = match r {
        Ok(code) if errors.is_empty() => Some(code),
        Ok(_) => None,
        Err(d) => {
            errors.push(d);
            None
        }
    };
    // in source order, each once (an error in a shared template instance can come up twice)
    let mut diags = std::mem::take(&mut c.warnings);
    for e in errors {
        if !diags.iter().any(|d| d.span == e.span && d.msg == e.msg) {
            diags.push(e);
        }
    }
    diags.sort_by_key(|d| (d.span.file, d.span.lo));
    (std::mem::take(&mut c.sm), diags, out)
}

/// how many errors a run reports before it stops checking

/// FNV-1a: small, stable across builds and platforms (symbol names, error codes, guards use it)
pub fn fnv32(s: &str) -> u32 {
    let mut h: u32 = 0x811c9dc5;
    for b in s.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    h
}

/// a checked array length: C objects can't be bigger than PTRDIFF_MAX
pub fn array_len(n: i128, span: Span) -> Res<u64> {
    if n < 0 {
        return err(span, "array length can't be negative");
    }
    if n > i64::MAX as i128 {
        return err(span, format!("array length {n} is too big"));
    }
    Ok(n as u64)
}
