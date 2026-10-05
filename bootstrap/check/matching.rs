// match: an if-chain inside ({ }), each arm jumps to the end label. A binding copies its payload
// when the arm starts; a `x&` binding is a T& to the payload in place. Exhaustive = an unguarded
// catch-all, or every enum variant / bool value.
use super::*;
use std::collections::HashSet;

/// what the unguarded arms so far cover, for check_exhaustive
#[derive(Default)]
struct Coverage {
    all: bool,
    variants: HashSet<usize>,
    bools: [bool; 2],
    lens: HashSet<usize>,  // slice lengths covered exactly
    open: Option<usize>,   // every slice length from this one up (a [.., x] arm)
}

/// a pattern compiled against the scrutinee's place. `test` is C that's true on a match ("1" = always),
/// `binds` are the locals to declare (name, type, C initializer), and `variant`/`bool_val` say what an
/// unguarded arm with this pattern covers
pub struct PatOut {
    pub test: String,
    pub binds: Vec<(String, TyId, String, bool)>, // the last: an x& binding, pointing into the matched place
    /// matches every value
    pub irrefutable: bool,
    pub variant: Option<usize>,
    pub bool_val: Option<bool>,
    /// a slice pattern whose elements all match anything: the lengths it covers, n exactly or (with a
    /// `..`) n and more
    pub lens: Option<(usize, bool)>,
}

impl Checker {
    /// `match (scrut) { arms }`: an if-chain over the scrutinee's slot. Its type is want, else the first arm
    /// with a value; NEVER when every arm leaves
    pub fn match_expr(&mut self, scrut: &Expr, arms: &[Arm], want: Option<TyId>, span: Span) -> Res<Val> {
        let s = self.expr(scrut, None)?;
        if matches!(s.ty, VOID | NEVER | NULL) {
            return err(scrut.span, "can't match on this; it has no value");
        }
        // what x& bindings reach: the matched place, as &place would (lends.rs); a slice's elements are
        // what it points at, as s[i] reaches them
        let mprov = if matches!(self.t.get(s.ty), Ty::Slice(_)) { (s.ro, s.via, s.root.clone()) } else { Self::addr_prov(&s) };
        let s_own = Val { own: s.own.clone(), ..Val::new(VOID, "") };
        let st = s.ty;
        let sc = self.cty(st);
        // a place is matched where it is (x& bindings point into it; plain ones copy the payload when
        // the arm starts). A temporary gets a slot of its own, read again by the cleanup after the arms
        let slot_ty = if s.lv { self.t.intern(Ty::Ref(st)) } else { st };
        let m = self.slot(if s.lv { "_mp" } else { "_m" }, slot_ty);
        let (init, place) = if s.lv { (format!("&({})", s.c), format!("(*{m})")) } else { (s.c.clone(), m.clone()) };
        let mc = if s.lv { format!("{sc}*") } else { sc.clone() };
        let (end, r) = (self.tmp("mend"), self.tmp("mr"));
        let mut result_ty: Option<TyId> = want.filter(|w| *w != VOID);
        // the arms' values: read-only where any is (lends.rs)
        let mut out_prov: (u32, Via, Option<String>) = (0, None, None);
        let mut code = String::new();
        let mut cov = Coverage::default();
        let mut all_never = true;
        // a temporary scrutinee that owns something is deleted after the match, and by any return,
        // break or continue out of an arm (an exit of the scope around the arms)
        let tmp_drop = !s.lv && self.needs_drop(st)?;
        let mut live = String::new();
        let mut exits = Vec::new();
        if tmp_drop {
            let flag = self.flag_for(&m);
            live = format!(" {};", Self::decl("bool", &flag, "true"));
            exits.push(Exit::Drop { c: m.clone(), drop: self.drop_fn(st)?, flag });
        }
        self.cx.scopes.push(Scope { exits, ..Default::default() });
        // moves are tracked per arm, as per branch of an if: each arm starts from the moves before the
        // match (plus earlier guards': a guard runs even when its arm isn't taken), and the code after
        // sees the moves of the arms that reach it
        let mut base = self.cx.moved.clone();
        let mut after = base.clone();
        let arms_res = (|| -> Res<()> {
            for arm in arms {
                self.cx.moved = base.clone();
                self.cx.scopes.push(Scope::default());
                let res = (|| -> Res<String> {
                    let p = self.pat_code(&arm.pat, &place, st)?;
                    let mut binds = String::new();
                    for (name, ty, c, by_ref) in &p.binds {
                        let tc = self.cty(*ty);
                        let local = self.new_local(name, *ty, false);
                        if *by_ref {
                            self.note_mut(&s_own);
                            if let Some(x) = self.cx.scopes.last_mut().unwrap().vars.get_mut(name.as_str()) {
                                (x.ro, x.via, x.root) = mprov.clone();
                            }
                        }
                        binds.push_str(&format!("{}; ", Self::decl(&tc, &local, c)));
                    }
                    let guard = match &arm.guard {
                        Some(g) => Some(self.expr_as(g, BOOL)?.c),
                        None => None,
                    };
                    base.clone_from(&self.cx.moved);
                    let body = self.expr(&arm.body, result_ty)?;
                    let reaches = body.ty != NEVER;
                    let body_code = if body.ty == NEVER {
                        format!("{};", body.c)
                    } else {
                        all_never = false;
                        if body.ty == VOID {
                            if result_ty.is_some() {
                                return err(arm.body.span, "this arm has no value, but the others do");
                            }
                            format!("{}; goto {end};", body.c)
                        } else {
                            let t = *result_ty.get_or_insert(body.ty);
                            let b = self.coerce(body, t, arm.body.span)?;
                            Self::merge_prov(&mut out_prov, &b);
                            format!("{r} = {}; goto {end};", b.c)
                        }
                    };
                    if reaches {
                        after.extend(self.cx.moved.iter().cloned());
                    }
                    if arm.guard.is_none() {
                        if p.irrefutable {
                            cov.all = true;
                        }
                        if let Some(v) = p.variant {
                            cov.variants.insert(v);
                        }
                        if let Some(b) = p.bool_val {
                            cov.bools[b as usize] = true;
                        }
                        match p.lens {
                            Some((n, true)) => cov.open = Some(cov.open.map_or(n, |m| m.min(n))),
                            Some((n, false)) => {
                                cov.lens.insert(n);
                            }
                            None => {}
                        }
                    }
                    Ok(match guard {
                        Some(g) => {
                            format!("if ({}) {{ {binds}if ({g}) {{ {body_code} }} }}\n", p.test)
                        }
                        None => format!("if ({}) {{ {binds}{body_code} }}\n", p.test),
                    })
                })();
                self.cx.scopes.pop();
                code.push_str(&res?);
            }
            Ok(())
        })();
        self.cx.scopes.pop();
        arms_res?;
        after.extend(base);
        self.cx.moved = after;
        self.check_exhaustive(st, &cov, span)?;
        // the arms cover every value, so falling off the chain means a corrupt value (say, a bad tag from C)
        let fallthrough = if self.opts.release {
            "__builtin_unreachable();".to_string()
        } else {
            format!("volt_panic(\"no match arm matched\", \"{}\");", self.loc(span))
        };
        let cleanup = if tmp_drop { format!("{}(&{m});", self.drop_fn(st)?) } else { String::new() };
        match result_ty {
            Some(t) if !all_never => {
                let tc = self.cty(t);
                let (ro, via, root) = out_prov;
                Ok(Val { ro, via, root, ..Val::new(t, format!("({{ {};{live} {tc} {r};\n{code}{fallthrough} {end}:; {cleanup} {r}; }})", Self::decl(&mc, &m, &init))) })
            }
            _ => Ok(Val::new(
                if all_never && !arms.is_empty() { NEVER } else { VOID },
                format!("{{ {};{live}\n{code}{fallthrough} {end}:; {cleanup} }}", Self::decl(&mc, &m, &init)),
            )),
        }
    }

    /// an error unless an unguarded arm matches anything, or the unguarded arms cover every variant of an
    /// enum, every member of a trait union, or both bools
    fn check_exhaustive(&self, ty: TyId, cov: &Coverage, span: Span) -> Res<()> {
        if cov.all {
            return Ok(());
        }
        // slices and str: every length; an array: its one length
        let covers = |n: usize| cov.lens.contains(&n) || cov.open.is_some_and(|m| n >= m);
        match self.t.get(ty) {
            Ty::Slice(_) | Ty::Str => {
                let upto = cov.open.unwrap_or_else(|| cov.lens.iter().max().map_or(0, |m| m + 1));
                return match (0..=upto).find(|n| !covers(*n)) {
                    Some(n) => err(span, format!("match doesn't handle a slice of length {n} (add arms or a default)")),
                    None => Ok(()),
                };
            }
            Ty::Array(_, n) if covers(*n as usize) => return Ok(()),
            _ => {}
        }
        if let Some(eid) = self.enum_of(ty) {
            let names = &self.enums[eid as usize].names;
            let missing: Vec<&str> = (0..names.len()).filter(|i| !cov.variants.contains(i)).map(|i| names[i].as_str()).collect();
            if missing.is_empty() {
                return Ok(());
            }
            return err(span, format!("match doesn't handle {} (add arms or a default)", missing.join(", ")));
        }
        if let Ty::TraitUnion(u) = self.t.get(ty) {
            let members = self.unions[*u as usize].members.clone();
            let missing: Vec<String> = (0..members.len()).filter(|i| !cov.variants.contains(i)).map(|i| self.ty_name(members[i])).collect();
            if missing.is_empty() {
                return Ok(());
            }
            return err(span, format!("match doesn't handle {} (add arms or a default)", missing.join(", ")));
        }
        if ty == BOOL && cov.bools[0] && cov.bools[1] {
            return Ok(());
        }
        err(span, format!("match on {} needs a default arm", self.ty_name(ty)))
    }

    /// compiles pat against the place c of type ty (c is repeated in each test, so it must be a place)
    fn pat_code(&mut self, pat: &Pat, c: &str, ty: TyId) -> Res<PatOut> {
        let any = |binds| PatOut { test: "1".into(), binds, irrefutable: true, variant: None, bool_val: None, lens: None };
        let span = pat.span;
        match &pat.kind {
            PatKind::Wild => Ok(any(Vec::new())),
            PatKind::BindRef(n) => {
                let rt = self.t.intern(Ty::Ref(ty));
                Ok(any(vec![(n.clone(), rt, format!("(&{c})"), true)]))
            }
            PatKind::Bind(n) => {
                // a bare name that is one of the enum's variants matches that variant instead of binding
                if let Some(eid) = self.enum_of(ty) {
                    if self.variant_index(eid, n).is_some() {
                        let p = Pat { kind: PatKind::Ctor(CtorPath::Dot(n.clone()), None), span };
                        return self.pat_code(&p, c, ty);
                    }
                }
                Ok(any(vec![(n.clone(), ty, c.to_string(), false)]))
            }
            PatKind::Lit(e) => {
                // null stays null (compare tests any optional against it); other literals take the
                // matched value's type
                let v = if matches!(e.kind, ExprKind::Null) { self.expr(e, None)? } else { self.expr(e, Some(ty))? };
                let bool_val = if ty == BOOL {
                    matches!(e.kind, ExprKind::Bool(true)).then_some(true).or(matches!(e.kind, ExprKind::Bool(false)).then_some(false))
                } else {
                    None
                };
                let t = self.compare(BinOp::Eq, Val::pure(ty, c), v, span)?;
                Ok(PatOut { test: t.c, binds: Vec::new(), irrefutable: false, variant: None, bool_val, lens: None })
            }
            PatKind::Range(lo, hi, incl) => {
                if self.t.int_of(ty).is_none() {
                    return err(span, format!("range patterns need an integer, found {}", self.ty_name(ty)));
                }
                let (l, h) = (self.expr_as(lo, ty)?, self.expr_as(hi, ty)?);
                let op = if *incl { "<=" } else { "<" };
                Ok(PatOut { test: format!("(({c}) >= {} && ({c}) {op} {})", l.c, h.c), binds: Vec::new(), irrefutable: false, variant: None, bool_val: None, lens: None })
            }
            PatKind::Tuple(pats) => {
                let Ty::Tuple(ts, _) = self.t.get(ty).clone() else {
                    return err(span, format!("tuple pattern, but the value is a {}", self.ty_name(ty)));
                };
                if ts.len() != pats.len() {
                    return err(span, format!("expected {} elements, found {}", ts.len(), pats.len()));
                }
                self.sub_pats(pats, &ts, |i| format!("({c}).f{i}"), None)
            }
            PatKind::Slice(pats, rest) => {
                // a slice's or str's elements through its pointer, an array's in place
                let (elem, len, base) = match self.t.get(ty).clone() {
                    Ty::Slice(t) => (t, format!("({c}).len"), format!("({c}).ptr")),
                    Ty::Str => (U8, format!("({c}).len"), format!("({c}).ptr")),
                    Ty::Array(t, n) => (t, format!("((size_t){n})"), format!("({c}).a")),
                    _ => return err(span, format!("slice pattern, but the value is a {}", self.ty_name(ty))),
                };
                let n = pats.len();
                let split = rest.as_ref().map_or(n, |(at, _)| *at);
                // elements before the .. count from the front, the ones after it from the back
                let tys = vec![elem; n];
                let mut out = self.sub_pats(pats, &tys, |i| if i < split { format!("{base}[{i}]") } else { format!("{base}[{len} - {}]", n - i) }, None)?;
                let op = if rest.is_some() { ">=" } else { "==" };
                out.test = if out.test == "1" { format!("({len} {op} {n})") } else { format!("({len} {op} {n} && {})", out.test) };
                if let Some((at, Some((name, _)))) = rest {
                    let st = if ty == STR { STR } else { self.t.intern(Ty::Slice(elem)) };
                    let sc = self.cty(st);
                    out.binds.push((name.clone(), st, format!("(({sc}){{ {base} + {at}, {len} - {n} }})"), false));
                }
                if out.irrefutable {
                    out.lens = Some((n, rest.is_some()));
                }
                out.irrefutable = false;
                Ok(out)
            }
            PatKind::Ctor(CtorPath::Path(p), args) if matches!(self.t.get(ty), Ty::TraitUnion(_)) => {
                // member-type pattern on a trait union: circle(c)
                let env = self.cx.env.clone();
                let mty = self.resolve_type_path(p, &env)?;
                let Some(i) = self.union_member(ty, mty) else {
                    return err(span, format!("{} isn't one of the types in {}", self.ty_name(mty), self.ty_name(ty)));
                };
                let test = format!("(({c}).tag == {i})");
                let mc = format!("({c}).u.m{i}");
                match args.as_deref() {
                    None | Some([]) => Ok(PatOut { test, binds: Vec::new(), irrefutable: false, variant: Some(i), bool_val: None, lens: None }),
                    Some([sub]) => {
                        let o = self.pat_code(sub, &mc, mty)?;
                        let full = o.irrefutable;
                        Ok(PatOut { test: format!("({test} && {})", o.test), binds: o.binds, irrefutable: false, variant: full.then_some(i), bool_val: None, lens: None })
                    }
                    _ => err(span, "a type pattern takes one name: circle(c)"),
                }
            }
            PatKind::Ctor(path, args) => {
                // which enum + variant
                let (ety, name) = match path {
                    CtorPath::Dot(n) => (ty, n.clone()),
                    CtorPath::Path(p) if p.segs.len() == 1 => (ty, p.segs[0].name.clone()),
                    CtorPath::Path(p) => match self.member_path(p)? {
                        Some(generics::Member::Of(t, m)) => (t, m),
                        Some(generics::Member::GenericEnum(d, m)) => (self.infer_enum(d, &m, None, Some(ty), span)?, m),
                        None => return err(span, format!("unknown variant '{}'", p.last())),
                    },
                };
                let Some(eid) = self.enum_of(ety) else {
                    return err(span, format!("{} has no variants to match", self.ty_name(ty)));
                };
                if ety != ty && !(ty == ANYERR && self.enums[eid as usize].is_error) {
                    return err(span, format!("this is a {} variant, but the value is a {}", self.ty_name(ety), self.ty_name(ty)));
                }
                let Some(idx) = self.variant_index(eid, &name) else {
                    return err(span, format!("{} has no variant {name}", self.ty_name(ety)));
                };
                let (value, tag) = (self.enums[eid as usize].values[idx], self.enums[eid as usize].tag);
                let v = self.c_int(value, int(tag));
                // an `error` value is its code already, so any error set's variant can be tested against
                // it (but never counts toward coverage)
                let tag_expr = if ty == ANYERR { format!("({c})") } else { self.tag_c(eid, c) };
                let test = format!("({tag_expr} == {v})");
                let payload = self.enum_payloads(eid, span)?[idx];
                let variant = (ety == ty).then_some(idx);
                let Some(pats) = args else {
                    return Ok(PatOut { test, binds: Vec::new(), irrefutable: false, variant, bool_val: None, lens: None });
                };
                let Some(pt) = payload else {
                    if pats.is_empty() {
                        return Ok(PatOut { test, binds: Vec::new(), irrefutable: false, variant, bool_val: None, lens: None });
                    }
                    return err(span, format!("{name} has no payload"));
                };
                let pc = format!("({c}).u.v{idx}");
                let mut out = match self.t.get(pt).clone() {
                    Ty::Tuple(ts, _) if pats.len() == ts.len() && pats.len() != 1 => self.sub_pats(pats, &ts, |i| format!("{pc}.f{i}"), None)?,
                    _ if pats.len() == 1 => self.pat_code(&pats[0], &pc, pt)?,
                    _ => return err(span, format!("{name} has one payload value")),
                };
                let sub_irrefutable = out.irrefutable;
                out.test = format!("({test} && {})", out.test);
                out.irrefutable = false;
                out.variant = if sub_irrefutable { variant } else { None };
                out.bool_val = None;
                Ok(out)
            }
        }
    }

    /// element patterns that must all match; access(i) is the C place of element i
    fn sub_pats(&mut self, pats: &[Pat], tys: &[TyId], access: impl Fn(usize) -> String, variant: Option<usize>) -> Res<PatOut> {
        let mut tests = Vec::new();
        let mut binds = Vec::new();
        let mut irrefutable = true;
        for (i, (p, t)) in pats.iter().zip(tys).enumerate() {
            let o = self.pat_code(p, &access(i), *t)?;
            if o.test != "1" {
                tests.push(o.test);
            }
            binds.extend(o.binds);
            irrefutable &= o.irrefutable;
        }
        let test = if tests.is_empty() { "1".into() } else { format!("({})", tests.join(" && ")) };
        Ok(PatOut { test, binds, irrefutable, variant, bool_val: None, lens: None })
    }
}
