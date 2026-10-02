// C names and definitions for Volt types.
use super::*;
use std::collections::HashSet;

impl Checker {
    /// A type's C name, made once and kept in c_names. Naming a type is what makes type_defs define
    /// it later (if it needs a definition).
    pub fn cty(&mut self, id: TyId) -> String {
        if let Some(n) = self.c_names.get(&id) {
            return n.clone();
        }
        let name = match self.t.get(id).clone() {
            Ty::Void | Ty::Never | Ty::TypeTy => "void".into(),
            Ty::Bool => "bool".into(),
            Ty::Null | Ty::VoidPtr => "void*".into(),
            Ty::Str => "volt_str".into(),
            Ty::CStr => "const char*".into(),
            Ty::Float(16) => "_Float16".into(),
            Ty::Float(32) => "float".into(),
            Ty::Float(64) => "double".into(),
            Ty::Float(_) => "__float128".into(),
            Ty::Int(k) => k.c().into(),
            Ty::Ref(t) | Ty::Ptr(t) => format!("{}*", self.cty(t)),
            Ty::Opt(t) if self.niche(t) => self.cty(t),
            Ty::Struct(s) => self.structs[s as usize].c_name.clone(),
            Ty::Enum(e) if !self.enums[e as usize].has_payload => self.enums[e as usize].tag.c().into(),
            Ty::Enum(e) => self.enums[e as usize].c_name.clone(),
            Ty::AnyErr => "uint32_t".into(),
            Ty::TraitUnion(u) => self.unions[u as usize].c_name.clone(),
            Ty::Closure(c) => self.closures[c as usize].c_name.clone(),
            _ => format!("volt_t{id}"),
        };
        self.c_names.insert(id, name.clone());
        name
    }

    /// does this type need a C definition of its own (a struct, or a fn pointer typedef)?
    fn needs_def(&self, id: TyId) -> bool {
        let own = match self.t.get(id) {
            Ty::Opt(t) => !self.niche(*t),
            Ty::Array(..) | Ty::Slice(_) | Ty::Tuple(..) | Ty::Range(_) | Ty::Struct(_) | Ty::FnPtr(..) | Ty::ErrUnion(..) | Ty::TraitUnion(_) | Ty::Closure(_) | Ty::FnVal(..) | Ty::Frame(_) => true,
            Ty::Enum(e) => self.enums[*e as usize].has_payload,
            _ => false,
        };
        own && !self.from_header(id)
    }

    /// a struct type defined by an imported C header (its #include defines it)
    fn from_header(&self, id: TyId) -> bool {
        matches!(self.t.get(id), Ty::Struct(s) if self.header_struct(*s))
    }

    /// was this struct imported from a C header (it keeps its C name, and the header defines it)?
    pub fn header_struct(&self, sid: u32) -> bool {
        matches!(&self.decls[self.structs[sid as usize].decl].item.kind, ItemKind::Struct(d) if d.c_name.is_some())
    }

    /// a C union: its fields share offset 0
    pub fn union_struct(&self, sid: u32) -> bool {
        matches!(&self.decls[self.structs[sid as usize].decl].item.kind, ItemKind::Struct(d) if d.c_union)
    }

    /// types that must be complete before this one can be defined
    fn value_deps(&mut self, id: TyId) -> Res<Vec<TyId>> {
        Ok(match self.t.get(id).clone() {
            Ty::Opt(t) | Ty::Array(t, _) | Ty::Range(t) => vec![t],
            Ty::Tuple(ts, _) => ts,
            // a function pointer typedef names its parameter and result types, which may be
            // typedefs too (other function pointers)
            Ty::FnPtr(ps, r, _) | Ty::FnVal(ps, r) => ps.into_iter().chain([r]).collect(),
            Ty::Struct(s) => self.struct_fields(s, Span::default())?.iter().map(|f| f.ty).collect(),
            Ty::Enum(e) => self.enum_payloads(e, Span::default())?.iter().flatten().copied().collect(),
            Ty::ErrUnion(e, t) => vec![e, t],
            Ty::TraitUnion(u) => self.unions[u as usize].members.clone(),
            Ty::Closure(c) => self.closures[c as usize].caps.iter().map(|x| x.1).collect(),
            Ty::Frame(i) => {
                let mut deps = vec![self.fns[i as usize].ret];
                deps.extend(self.frames.get(&(i as usize)).into_iter().flatten().map(|x| x.1));
                deps
            }
            _ => Vec::new(),
        })
    }

    /// The C definitions of every type named so far: forward typedefs, then struct bodies in
    /// dependency order. Defining a type can name new ones, so it loops until nothing is left.
    pub fn type_defs(&mut self) -> Res<String> {
        let mut fwd = String::new();
        let mut defs = String::new();
        let mut done = HashSet::new();
        loop {
            let mut pending: Vec<TyId> = self.c_names.keys().copied().filter(|t| self.needs_def(*t) && !done.contains(t)).collect();
            if pending.is_empty() {
                break;
            }
            pending.sort();
            for t in pending {
                self.define(t, &mut done, &mut fwd, &mut defs)?;
            }
        }
        Ok(fwd + "\n" + &defs)
    }

    /// define one type (once), after the types it holds by value
    fn define(&mut self, id: TyId, done: &mut HashSet<TyId>, fwd: &mut String, defs: &mut String) -> Res<()> {
        if !done.insert(id) {
            return Ok(());
        }
        for dep in self.value_deps(id)? {
            self.cty(dep);
            // a niche optional is its payload's C type (a function pointer's typedef, say)
            let dep = match self.t.get(dep) {
                Ty::Opt(x) if self.niche(*x) => *x,
                _ => dep,
            };
            if self.needs_def(dep) {
                self.define(dep, done, fwd, defs)?;
            }
        }
        let name = self.cty(id);
        let field = |c: &mut Self, t: TyId, n: &str| if t == VOID { String::new() } else { format!(" {} {n};", c.cty(t)) };
        let body = match self.t.get(id).clone() {
            Ty::FnPtr(ps, r, va) => {
                let mut args: Vec<String> = ps.iter().map(|p| self.cty(*p)).collect();
                if va {
                    args.push("...".into());
                }
                if args.is_empty() {
                    args.push("void".into());
                }
                let r = self.cty(r);
                defs.push_str(&format!("typedef {r} (*{name})({});\n", args.join(", ")));
                return Ok(());
            }
            Ty::FnVal(ps, r) => {
                let mut args: Vec<String> = vec!["void*".into()];
                args.extend(ps.iter().map(|p| self.cty(*p)));
                let r = if r == NEVER { "void".to_string() } else { self.cty(r) };
                format!(" {r} (*fn)({}); void* env;", args.join(", "))
            }
            Ty::Closure(c) => {
                let caps = self.closures[c as usize].caps.clone();
                if caps.is_empty() { " char unused;".to_string() } else { caps.iter().map(|(n, t)| field(self, *t, &c_field(n))).collect() }
            }
            Ty::Opt(t) => format!("{} bool has;", field(self, t, "v")),
            Ty::Array(t, n) => format!(" {} a[{n}];", self.cty(t)),
            Ty::Slice(t) => format!(" {}* ptr; size_t len;", self.cty(t)),
            Ty::Range(t) => format!("{}{}", field(self, t, "lo"), field(self, t, "hi")),
            Ty::Tuple(ts, _) => ts.iter().enumerate().map(|(i, t)| field(self, *t, &format!("f{i}"))).collect(),
            Ty::Struct(s) => {
                let fields = self.struct_fields(s, Span::default())?;
                fields.iter().map(|f| field(self, f.ty, &c_field(&f.name))).collect()
            }
            Ty::Enum(e) => {
                let payloads = self.enum_payloads(e, Span::default())?;
                let tag = self.enums[e as usize].tag.c();
                let arms: String = payloads.iter().enumerate().filter_map(|(i, p)| p.map(|p| field(self, p, &format!("v{i}")))).collect();
                format!(" {tag} tag; union {{{arms} }} u;")
            }
            Ty::ErrUnion(e, t) => format!("{}{}", field(self, e, "err"), field(self, t, "v")),
            Ty::Frame(i) => {
                let mut body = format!(" uint32_t state; bool cancel;{}", field(self, self.fns[i as usize].ret, "ret"));
                for (n, t) in self.frames.get(&(i as usize)).cloned().unwrap_or_default() {
                    body.push_str(&field(self, t, &n));
                }
                body
            }
            Ty::TraitUnion(u) => {
                let members = self.unions[u as usize].members.clone();
                let arms: String = members.iter().enumerate().map(|(i, m)| field(self, *m, &format!("m{i}"))).collect();
                format!(" uint16_t tag; union {{{arms} }} u;")
            }
            _ => unreachable!(),
        };
        fwd.push_str(&format!("typedef struct {name} {name};\n"));
        defs.push_str(&format!("struct {name} {{{body} }};\n"));
        Ok(())
    }
}

/// a Volt field (or capture) name as a C member name: C keywords (and stdbool's macros) can't be
/// member names, so those get a prefix. A C header's own fields never need one
pub fn c_field(n: &str) -> String {
    const KW: [&str; 49] = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
        "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
        "volatile", "while", "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn", "_Static_assert",
        "_Thread_local", "asm", "typeof", "bool", "true", "false",
    ];
    if KW.contains(&n) { format!("volt_kw_{n}") } else { n.to_string() }
}

/// C string literal using octal escapes (hex escapes in C swallow following hex digits).
pub fn c_str_lit(bytes: &[u8]) -> String {
    let mut s = String::from("\"");
    for &b in bytes {
        match b {
            b'"' => s.push_str("\\\""),
            b'\\' => s.push_str("\\\\"),
            b'?' => s.push_str("\\?"), // no trigraphs
            0x20..=0x7e => s.push(b as char),
            _ => s.push_str(&format!("\\{b:03o}")),
        }
    }
    s.push('"');
    s
}
