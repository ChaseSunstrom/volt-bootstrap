// Enums and error sets. Payload-less enums are plain C integers (backing type); enums with
// payloads are { tag; union { v0; v1; ... } u; }. Error variants get program-wide codes, so any
// error set converts to `error` (any) by taking the code.
use super::*;

/// one enum or error set instance (one per set of generic args)
pub struct EnumInfo {
    pub decl: DeclId,
    /// the primary (unspecialized) decl, for matching `Enum<T>` patterns against instances
    pub family: DeclId,
    pub args: Vec<GVal>,
    pub env: Rc<Env>,
    pub name: String,
    pub c_name: String,
    /// the C integer type of the tag: the backing type, u32 for error sets, else the smallest that fits
    pub tag: IntTy,
    pub is_error: bool,
    pub has_payload: bool,
    pub names: Vec<String>,
    /// each variant's tag value; for an error set, its program-wide code
    pub values: Vec<i128>,
    /// each variant's payload type, resolved on first use by enum_payloads (None = no payload)
    pub payloads: Option<Rc<Vec<Option<TyId>>>>,
}

impl Checker {
    /// the enum type for decl with these generic args, creating the instance (names, values, tag type) on
    /// first use; payload types wait for enum_payloads
    pub fn enum_inst(&mut self, decl: DeclId, args: Vec<GVal>, span: Span) -> Res<TyId> {
        if let Some(id) = self.enum_ids.get(&(decl, args.clone())) {
            return Ok(self.t.intern(Ty::Enum(*id)));
        }
        let (item, dns) = (self.decls[decl].item.clone(), self.decls[decl].ns);
        let ItemKind::Enum(e) = &item.kind else { return err(span, "not an enum") };
        let env = self.inst_env(dns, &item.generics, &args);
        let path = self.nss[dns].path.clone();
        let mut name = if path.is_empty() { e.name.clone() } else { format!("{}::{}", path.join("::"), e.name) };
        if !args.is_empty() {
            let a: Vec<String> = args.iter().map(|g| self.gval_name(g)).collect();
            name = format!("{name}<{}>", a.join(", "));
        }
        let c_name = self.fresh_c_name(&format!("v_{}", e.name));
        let names: Vec<String> = e.variants.iter().map(|v| v.name.clone()).collect();
        let mut values = Vec::new();
        if e.is_error {
            for v in &e.variants {
                if v.value.is_some() {
                    return err(v.span, "error variants can't set values");
                }
                // a hash of the qualified name: the same code in every C unit, whatever the order
                // (0 means ok and 1 is the plain `error`)
                let qual = format!("{name}::{}", v.name);
                let mut code = fnv32(&qual);
                while code < 2 {
                    code = fnv32(&format!("{qual}{code}"));
                }
                match self.error_names.get(&code) {
                    Some((_, other)) if *other != qual => return err(v.span, format!("error {qual} has the same code as {other}; rename one")),
                    _ => {}
                }
                self.error_names.insert(code, (v.name.clone(), qual));
                values.push(code as i128);
            }
        } else {
            let mut next = 0i128;
            for v in &e.variants {
                let val = match &v.value {
                    Some(x) => self.const_int(x, &env)?,
                    None => next,
                };
                if values.contains(&val) {
                    return err(v.span, format!("two variants have the value {val}"));
                }
                values.push(val);
                next = val + 1;
            }
        }
        // the tag type: an explicit backing type must hold every value; without one, the smallest int
        // that does
        let tag = if e.is_error {
            IntTy::U32
        } else if let Some(b) = &e.backing {
            let t = self.resolve_type(b, &env)?;
            match self.t.int_of(t) {
                Some(k) => k,
                None => return err(b.span, "an enum's backing type must be an integer"),
            }
        } else {
            let (lo, hi) = (values.iter().min().copied().unwrap_or(0), values.iter().max().copied().unwrap_or(0));
            [IntTy::U8, IntTy::I8, IntTy::U16, IntTy::I16, IntTy::U32, IntTy::I32, IntTy::U64, IntTy::I64]
                .into_iter()
                .find(|k| k.fits(lo) && k.fits(hi))
                .unwrap_or(IntTy::I128)
        };
        if let Some((v, x)) = e.variants.iter().zip(&values).find(|(_, x)| !tag.fits(**x)) {
            return err(v.span, format!("{x} doesn't fit in the backing type {}", tag.name()));
        }
        let has_payload = e.variants.iter().any(|v| v.payload.is_some());
        let id = self.enums.len() as u32;
        self.enums.push(EnumInfo { decl, family: decl, args: args.clone(), env, name, c_name, tag, is_error: e.is_error, has_payload, names, values, payloads: None });
        self.enum_ids.insert((decl, args), id);
        Ok(self.t.intern(Ty::Enum(id)))
    }

    /// each variant's payload type (None = no payload, including a void one), resolved once and cached
    pub fn enum_payloads(&mut self, eid: u32, span: Span) -> Res<Rc<Vec<Option<TyId>>>> {
        if let Some(p) = &self.enums[eid as usize].payloads {
            return Ok(p.clone());
        }
        let (decl, env) = (self.enums[eid as usize].decl, self.enums[eid as usize].env.clone());
        let item = self.decls[decl].item.clone();
        let ItemKind::Enum(e) = &item.kind else { unreachable!() };
        // placeholder so a payload behind a reference to this enum doesn't loop
        self.enums[eid as usize].payloads = Some(Rc::new(vec![None; e.variants.len()]));
        let mut out = Vec::new();
        for v in &e.variants {
            out.push(match &v.payload {
                Some(t) => {
                    let ty = self.resolve_type(t, &env)?;
                    if ty == VOID { None } else { Some(ty) }
                }
                None => None,
            });
        }
        let _ = span;
        let rc = Rc::new(out);
        self.enums[eid as usize].payloads = Some(rc.clone());
        Ok(rc)
    }

    pub fn enum_of(&self, ty: TyId) -> Option<u32> {
        match self.t.get(ty) {
            Ty::Enum(e) => Some(*e),
            _ => None,
        }
    }

    pub fn variant_index(&self, eid: u32, name: &str) -> Option<usize> {
        self.enums[eid as usize].names.iter().position(|n| n == name)
    }

    /// C expression for the tag (or error code) of an enum value
    pub fn tag_c(&self, eid: u32, c: &str) -> String {
        if self.enums[eid as usize].has_payload { format!("({c}).tag") } else { format!("({c})") }
    }

    /// build variant `idx` of enum `ty` from optional payload args
    pub fn make_variant(&mut self, ty: TyId, idx: usize, args: Option<&[Expr]>, span: Span) -> Res<Val> {
        let eid = self.enum_of(ty).unwrap();
        let payloads = self.enum_payloads(eid, span)?;
        let info = &self.enums[eid as usize];
        let (vname, value, tag, has_payload) = (info.names[idx].clone(), info.values[idx], info.tag, info.has_payload);
        let tag_c = self.c_int(value, int(tag));
        let payload = match (payloads[idx], args) {
            (None, None) => None,
            (None, Some(a)) if a.is_empty() => None,
            (None, Some(_)) => return err(span, format!("{vname} has no payload")),
            (Some(_), None) => return err(span, format!("{vname} needs a payload: {vname}(...)")),
            (Some(pt), Some(a)) => {
                let v = match self.t.get(pt).clone() {
                    Ty::Tuple(ts, _) if a.len() == ts.len() && a.len() > 1 => {
                        let tuple = Expr { kind: ExprKind::Tuple(a.to_vec()), span };
                        self.expr_as(&tuple, pt)?
                    }
                    _ if a.len() == 1 => {
                        let v = self.expr(&a[0], Some(pt))?;
                        self.take_into(v, pt, a[0].span)?
                    }
                    _ => return err(span, format!("{vname} takes one payload value")),
                };
                Some(v)
            }
        };
        if !has_payload {
            return Ok(Val::pure(ty, tag_c));
        }
        let c = self.cty(ty);
        Ok(match payload {
            Some(v) => Val { pure: v.pure, ..Val::new(ty, format!("(({c}){{ .tag = {tag_c}, .u.v{idx} = {} }})", v.c)) },
            None => Val::pure(ty, format!("(({c}){{ .tag = {tag_c} }})")),
        })
    }

    pub fn print_enum(&mut self, c: &str, eid: u32, span: Span) -> Res<String> {
        let payloads = self.enum_payloads(eid, span)?;
        let info = &self.enums[eid as usize];
        let (names, values, tag) = (info.names.clone(), info.values.clone(), info.tag);
        let tag_expr = self.tag_c(eid, c);
        let mut code = format!("switch ({tag_expr}) {{ ");
        for (i, n) in names.iter().enumerate() {
            let v = self.c_int(values[i], int(tag));
            code.push_str(&format!("case {v}: volt_out(VOLT_E, \"{n}\"); "));
            if let Some(pt) = payloads[i] {
                let inner = self.print_code(&format!("({c}).u.v{i}"), pt, span)?;
                if matches!(self.t.get(pt), Ty::Tuple(..)) {
                    code.push_str(&inner);
                } else {
                    code.push_str(&format!("volt_out(VOLT_E, \"(\"); {inner}volt_out(VOLT_E, \")\"); "));
                }
            }
            code.push_str("break; ");
        }
        code.push_str("default: volt_out(VOLT_E, \"<invalid>\"); } ");
        Ok(code)
    }

    /// C expression for the error code inside an error union value
    pub fn eu_code(&self, eu_ty: TyId, c: &str) -> String {
        let Ty::ErrUnion(e, _) = self.t.get(eu_ty) else { unreachable!() };
        match self.enum_of(*e) {
            Some(eid) => self.tag_c(eid, &format!("({c}).err")),
            None => format!("({c}).err"),
        }
    }

    /// code of an error value (error-set enum or `error`)
    pub fn err_code(&self, ty: TyId, c: &str) -> String {
        match self.enum_of(ty) {
            Some(eid) => self.tag_c(eid, c),
            None => format!("({c})"),
        }
    }

    /// an error value's type: `error` or an error set
    pub fn is_error_ty(&self, ty: TyId) -> bool {
        ty == ANYERR || self.enum_of(ty).is_some_and(|e| self.enums[e as usize].is_error)
    }

    /// C for volt_err_name(code): the variant name of an error code, for printing
    pub fn error_table(&self) -> String {
        let cases: String = self.error_names.iter().map(|(c, (n, _))| format!("case {c}u: return \"{n}\"; ")).collect();
        format!("static const char *volt_err_name(uint32_t c) {{ switch (c) {{ {cases}default: return \"<error>\"; }} }}\n")
    }
}
