// What can't change stays unchanged through references. A val (or a parameter without var) can be
// read through a reference (&x, or a method's this), never written through one:
//   - a reference made from a place that can't change is read-only: writing through it is an error
//     right away;
//   - a body (a fn instance, a closure) records what it writes through its reference parameters:
//     assigning through one, or passing it on to a parameter another body writes through (an
//     edge). A closure's captures count as parameters after its own;
//   - a fn or closure made into a fn value links the value's type to its body, so a call through a
//     value of that type writes through what any of them does;
//   - a call lending a read-only reference records a Lend; once every body is checked, the writes
//     are solved (edges to a fixpoint, so recursion works) and a Lend to a parameter that's written
//     through is an error. std::write lends its writer to write_str; copy and as_str hooks, which
//     copying and printing call on vals, can't write through this at all.
// Everything is by depth: a reference's ro has bit e set when the memory e references past what it
// points at can't change (a T& & made from a var T& pointing at a val: bit 1), its via says which
// parameter it reaches and at what depth, and a body's writes are a mask a parameter. So a slice of
// a val passed by reference (this: T[..]&) can be reseated, and its elements can't change.
// A val is shallow: memory its pointer fields point at isn't part of it. Calls to extern fns aren't
// checked (C is unchecked), nor are fn values made elsewhere (C callbacks, @cast), and @cast drops
// where a pointer points.
// A value holding references (a struct, tuple or array of them, an optional or error union: see
// holds) carries where they point, merged: ro has the bits of any, via and root come from the first
// (the first read-only one, for root), and a part of it (a field, an element) points where the whole
// does. Storing a reference into a local, or into part of one, merges where it points into the
// local's (flow-insensitively: once a local has held a reference to a val, writing through it is an
// error). Not followed: a reference stored through another reference (into memory a parameter
// reaches), an enum's payload, and a struct that also owns memory through a pointer.
// A reference a fn returns points where its argument did: each body records where what it returns
// points (`rets`: a parameter at some depth, or another call's result), solved into a summary a
// body. A call whose result is a reference is a node of its own (Body::Site, its one parameter the
// result): writes through the result, or passing it on, mark the site like a parameter, and the
// site passes them, through the callee's summary, to the arguments of that call: an error where one
// is read-only (and to the caller's parameter where one reaches it).
use super::*;

/// what a call runs: a fn instance, a closure's body, or whatever a fn value of this type holds;
/// or a call's result (a site), written through like a parameter
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Body {
    Fn(usize),
    Closure(u32),
    Value(TyId),
    Site(u32),
}

/// a via's parameter at or above this is call site k - SITE's result, not a parameter of the body
pub const SITE: u32 = 1 << 24;

/// a call whose result is a reference: what it calls, from where, and what it lends each reference
/// parameter (param, ro, via, root, root_param, where)
pub struct Site {
    pub callee: Body,
    pub caller: Option<Body>,
    pub args: Vec<(usize, u32, Via, String, bool, Span)>,
}

/// where a reference points, as a parameter's memory: depth e past what it points at is depth e + off
/// past what parameter k points at
pub type Via = Option<(u32, i32)>;

pub fn deeper(v: Via, n: i32) -> Via {
    v.map(|(k, o)| (k, o + n))
}

/// a write mask moved by `by` depths (memory above a parameter's isn't the caller's)
fn shift(w: u64, by: i32) -> u64 {
    match by {
        0 => w,
        1..=63 => w << by,
        -63..=-1 => w >> -by,
        _ => 0,
    }
}

impl Checker {
    /// whether a value of this type reaches other memory a fn could write through: a reference, a
    /// pointer or a slice
    pub fn reaches(&self, t: TyId) -> bool {
        matches!(self.t.get(t), Ty::Ref(_) | Ty::Ptr(_) | Ty::Slice(_))
    }

    /// whether where a value of this type points travels with it: a reference, pointer or slice, or
    /// a struct, tuple, array, optional or error union whose parts hold references or slices and
    /// nothing else that points (a part that owns memory through a pointer, like a vec's buffer,
    /// would share depths with what the references reach, so such a value isn't followed)
    pub fn holds(&mut self, t: TyId) -> bool {
        self.reaches(t) || self.ref_parts(t) == Some(true)
    }

    /// Some(true) when t's parts hold references or slices and nothing else that points, Some(false)
    /// when nothing in it points, None when something else does (a pointer, a fn value, an enum's
    /// payload)
    fn ref_parts(&mut self, t: TyId) -> Option<bool> {
        let parts: Vec<TyId> = match self.t.get(t).clone() {
            Ty::Ref(_) | Ty::Slice(_) => return Some(true),
            Ty::Ptr(_) | Ty::VoidPtr | Ty::FnVal(..) | Ty::Closure(_) | Ty::TraitUnion(_) | Ty::Frame(_) => return None,
            Ty::Opt(x) | Ty::ErrUnion(_, x) | Ty::Array(x, _) => vec![x],
            Ty::Tuple(ts, _) => ts,
            Ty::Struct(sid) => self.struct_fields(sid, Span::default()).ok()?.iter().map(|f| f.ty).collect(),
            Ty::Enum(e) => return self.enum_payloads(e, Span::default()).ok()?.iter().all(|p| p.is_none()).then_some(false),
            _ => return Some(false),
        };
        let mut any = false;
        for p in parts {
            any |= self.ref_parts(p)?;
        }
        Some(any)
    }

    /// where the references in these parts of a `ty` point, merged (parts holding none are skipped;
    /// nothing when ty isn't followed)
    pub fn merged_prov(&mut self, ty: TyId, vals: &[Val]) -> (u32, Via, Option<String>) {
        let mut prov = (0, None, None);
        if !self.holds(ty) {
            return prov;
        }
        for v in vals {
            if self.holds(v.ty) {
                Self::merge_prov(&mut prov, v);
            }
        }
        prov
    }

    /// the local just declared as `name` holds v: it points where v does (a reference local is
    /// named after what it points into; a struct or array of them only when that can't change)
    pub fn local_prov(&mut self, name: &str, ty: TyId, v: &Val) {
        let plain = self.reaches(ty);
        if let Some(x) = self.cx.scopes.last_mut().unwrap().vars.get_mut(name) {
            (x.ro, x.via) = (v.ro, v.via);
            if plain || v.ro != 0 {
                x.root = v.root.clone();
            }
        }
    }

    /// storing v into place l: when l is a local or part of one, the local now also points where v
    /// does (a reference stored through another reference isn't followed)
    pub fn note_store(&mut self, l: &Val, v: &Val) {
        let Some(own) = &l.own else { return };
        if !self.holds(v.ty) {
            return;
        }
        let found = self.cx.scopes.iter().rev().find_map(|s| s.vars.values().find(|x| x.own.as_ref() == Some(own)).map(|x| x.ty));
        if !found.is_some_and(|t| self.holds(t)) {
            return; // a local whose type isn't followed (one that owns memory too) keeps none
        }
        for s in self.cx.scopes.iter_mut().rev() {
            if let Some(x) = s.vars.values_mut().find(|x| x.own.as_ref() == Some(own)) {
                let mut prov = (x.ro, x.via, x.root.clone());
                Self::merge_prov(&mut prov, v);
                (x.ro, x.via, x.root) = prov;
                return;
            }
        }
    }

    /// &place's provenance: read-only where the place can't change (depth 0) and where what it holds
    /// points at what can't (deeper); the parameter memory it is
    pub fn addr_prov(place: &Val) -> (u32, Via, Option<String>) {
        let ro = (place.lv && !place.mutable) as u32 | (place.ro << 1);
        // a local holding what a parameter reaches one depth or more down: its address would map the
        // local itself onto the parameter's memory, so it isn't followed
        // ponytail: a via has no floor (depths above it that are local); add one to follow these
        let via = place.pvia.or(deeper(place.via, -1).filter(|&(_, o)| o < 0));
        (ro, via, place.root.clone())
    }

    /// the place a reference (pointer, slice) value `r` reaches: mutable unless r's pointee is
    /// read-only, the parameter memory r points at, and what it holds one depth further
    pub fn through(place: Val, r: &Val) -> Val {
        Val { mutable: place.mutable && r.ro & 1 == 0, rop: r.ro & 1 != 0, pvia: r.via, ro: r.ro >> 1, via: deeper(r.via, 1), root: r.root.clone(), ..place }
    }

    /// a value from either of two (a ?? b, match arms): read-only where either is, named after the
    /// first read-only one
    pub fn merge_prov(into: &mut (u32, Via, Option<String>), v: &Val) {
        if into.2.is_none() || (into.0 == 0 && v.ro != 0) {
            into.2 = v.root.clone();
        }
        into.0 |= v.ro;
        into.1 = into.1.or(v.via);
    }

    fn mark(&mut self, b: Body, k: usize, w: u64) -> bool {
        let ws = self.writes.entry(b).or_default();
        if ws.len() <= k {
            ws.resize(k + 1, 0);
        }
        let new = w & !ws[k] != 0;
        ws[k] |= w;
        new
    }

    fn written(&self, b: Body, k: usize) -> u64 {
        self.writes.get(&b).and_then(|w| w.get(k).copied()).unwrap_or(0)
    }

    /// the parameter via's k names: a parameter of the body being checked, or a call's result
    fn node(&self, k: u32) -> Option<(Body, usize)> {
        if k >= SITE {
            return Some((Body::Site(k - SITE), 0));
        }
        self.cx.body.map(|b| (b, k as usize))
    }

    /// assigning to `place`: a write through the parameter it's reached through
    pub fn note_write(&mut self, place: &Val) {
        if let Some((k, d)) = place.pvia {
            if let (Some((b, k)), true) = (self.node(k), (0..64).contains(&d)) {
                self.mark(b, k, 1 << d);
            }
        }
    }

    /// returning v from the body being checked: where it points, when it's a reference
    pub fn note_return(&mut self, v: &Val) {
        if let (Some((k, off)), Some(b)) = (v.via, self.cx.body) {
            if !self.holds(v.ty) {
                return;
            }
            self.rets.push((b, k, off));
        }
    }

    /// a call to `callee` returning `ret`: a site when that's a reference (its arguments are noted
    /// into it, and its result points at it)
    pub fn open_site(&mut self, callee: Body, ret: TyId) -> Option<u32> {
        if !self.holds(ret) {
            return None;
        }
        self.sites.push(Site { callee, caller: self.cx.body, args: Vec::new() });
        Some((self.sites.len() - 1) as u32)
    }

    /// a call's result, pointing at its site
    pub fn site_result(v: Val, site: Option<u32>) -> Val {
        match site {
            Some(s) => Val { via: Some((SITE + s, 0)), ..v },
            None => v,
        }
    }

    /// passing a reference (pointer, slice) with this provenance to parameter `param` of `callee`
    /// (at call `site`, when its result is a reference)
    #[allow(clippy::too_many_arguments)]
    pub fn note_arg(&mut self, callee: Body, param: usize, ro: u32, via: Via, root: Option<&str>, span: Span, site: Option<u32>) {
        if let Body::Fn(i) = callee {
            if !self.holds(self.fns[i].params.get(param).map_or(VOID, |p| p.ty)) || self.fns[i].intrinsic.is_some() {
                return;
            }
            if matches!(&self.decls[self.fns[i].decl].item.kind, ItemKind::Fn(f) if f.extern_abi.is_some() && f.body.is_none()) {
                return; // C: unchecked
            }
        }
        let root = root.unwrap_or("this").to_string();
        let root_param = self.lookup_local(&root).is_some_and(|l| l.param);
        if let Some(s) = site {
            self.sites[s as usize].args.push((param, ro, via, root.clone(), root_param, span));
        }
        if ro != 0 {
            self.lends.push(Lend { span, callee, param, mask: ro, root, root_param });
        }
        if let Some((k, off)) = via {
            if let Some((b, k)) = self.node(k) {
                self.edges.push((b, k, off, callee, param));
            }
        }
    }

    /// body `b` made into a fn value of type `fv` (fn(...) or a C fn pointer): a call through one
    /// writes through what b does
    pub fn escape(&mut self, b: Body, fv: TyId) {
        let key = self.value_key(fv);
        let n = match self.t.get(fv) {
            Ty::FnPtr(ps, ..) | Ty::FnVal(ps, _) => ps.len(),
            _ => 0,
        };
        for j in 0..n {
            self.edges.push((Body::Value(key), j, 0, b, j));
        }
    }

    /// fn values of the same signature share a key, whichever kind they are
    pub fn value_key(&mut self, fv: TyId) -> TyId {
        match self.t.get(fv).clone() {
            Ty::FnPtr(ps, r, _) => self.t.intern(Ty::FnVal(ps, r)),
            _ => fv,
        }
    }

    fn body_name(&self, b: Body, k: usize, mask: u64) -> (String, String) {
        match b {
            Body::Fn(i) => {
                let f = &self.fns[i];
                let fname = match &self.decls[f.decl].item.kind {
                    ItemKind::Fn(d) => d.name.clone(),
                    _ => f.name.clone(),
                };
                (fname, f.params.get(k).map_or_else(String::new, |p| p.name.clone()))
            }
            Body::Closure(c) => ("a closure".into(), self.closures[c as usize].names.get(k).cloned().unwrap_or_default()),
            Body::Site(_) => ("a call".into(), String::new()),
            Body::Value(key) => {
                // the first body behind the value that writes where it's read-only
                let culprit = self.edges.iter().find(|e| e.0 == b && e.1 == k && self.written(e.3, e.4) & mask != 0).map(|e| e.3);
                match culprit {
                    Some(c) => {
                        let (f, p) = self.body_name(c, k, mask);
                        (format!("{f} (called as a {} value)", self.ty_name(key)), p)
                    }
                    None => ("a fn value".into(), String::new()),
                }
            }
        }
    }

    /// where what each body returns points: (parameter, depth) pairs, through the calls it returns
    /// the results of (a fixpoint, so recursion works; depths past 63 are dropped)
    fn return_summaries(&self) -> HashMap<Body, HashSet<(usize, i32)>> {
        let mut sums: HashMap<Body, HashSet<(usize, i32)>> = HashMap::new();
        loop {
            let mut changed = false;
            for &(b, k, off) in &self.rets {
                for e in self.expand(&sums, k, off) {
                    changed |= sums.entry(b).or_default().insert(e);
                }
            }
            // a fn value's results point where any fn made into one does
            for &(f, _, _, g, _) in &self.edges {
                if let (Body::Value(_), Some(gs)) = (f, sums.get(&g).cloned()) {
                    for e in gs {
                        changed |= sums.entry(f).or_default().insert(e);
                    }
                }
            }
            if !changed {
                return sums;
            }
        }
    }

    /// (via k, off) as parameter memory: itself, or for a call's result, where the callee's result
    /// points as that call's arguments (a call's arguments are calls made before it, so this ends)
    fn expand(&self, sums: &HashMap<Body, HashSet<(usize, i32)>>, k: u32, off: i32) -> Vec<(usize, i32)> {
        if off.abs() >= 64 {
            return Vec::new();
        }
        if k < SITE {
            return vec![(k as usize, off)];
        }
        let site = &self.sites[(k - SITE) as usize];
        let mut out = Vec::new();
        for &(p, poff) in sums.get(&site.callee).into_iter().flatten() {
            for (param, _, via, ..) in &site.args {
                if let (true, Some((k2, o2))) = (*param == p, via) {
                    out.extend(self.expand(sums, *k2, o2 + poff + off));
                }
            }
        }
        out
    }

    /// Solve the writes (a parameter is written through when its body writes through it, or passes
    /// it on to one that's written through) and report each lend to one.
    pub fn check_lends(&mut self) {
        let sums = self.return_summaries();
        let none = HashSet::new();
        loop {
            let mut changed = false;
            for i in 0..self.edges.len() {
                let (f, k, off, g, j) = self.edges[i];
                let w = shift(self.written(g, j), off);
                if w != 0 {
                    changed |= self.mark(f, k, w);
                }
            }
            // a site's writes reach the arguments its result may point into
            for s in 0..self.sites.len() {
                let w = self.written(Body::Site(s as u32), 0);
                if w == 0 {
                    continue;
                }
                for &(p, poff) in sums.get(&self.sites[s].callee).unwrap_or(&none) {
                    for a in 0..self.sites[s].args.len() {
                        let (param, _, via, ..) = self.sites[s].args[a].clone();
                        let Some((k, o)) = via.filter(|_| param == p) else { continue };
                        let to = if k >= SITE { Some((Body::Site(k - SITE), 0)) } else { self.sites[s].caller.map(|b| (b, k as usize)) };
                        if let Some((b, k)) = to {
                            changed |= self.mark(b, k, shift(w, poff + o));
                        }
                    }
                }
            }
            if !changed {
                break;
            }
        }
        // a write through a call's result into an argument that can't change
        for (i, s) in std::mem::take(&mut self.sites).into_iter().enumerate() {
            let w = self.written(Body::Site(i as u32), 0);
            if w == 0 {
                continue;
            }
            let ps = sums.get(&s.callee).unwrap_or(&none);
            for (param, ro, _, root, root_param, span) in s.args {
                if !ps.iter().any(|&(p, poff)| p == param && ro as u64 & shift(w, poff) != 0) {
                    continue;
                }
                let (fname, _) = self.body_name(s.callee, param, 0);
                let what = if root_param { "a parameter without var" } else { "a val" };
                self.errors.push(Diag::new(span, format!("'{root}' is {what}, and it's changed through what {fname} returns: declare it with var")));
            }
        }
        self.rets.clear();
        for l in std::mem::take(&mut self.lends) {
            if self.written(l.callee, l.param) & l.mask as u64 == 0 {
                continue;
            }
            let (fname, pname) = self.body_name(l.callee, l.param, l.mask as u64);
            let what = if l.root_param { "a parameter without var" } else { "a val" };
            let through = if pname.is_empty() { String::new() } else { format!(" (through {pname})") };
            self.errors.push(Diag::new(l.span, format!("'{}' is {what}, and {fname} changes it{through}: declare it with var", l.root)));
        }
        for h in std::mem::take(&mut self.ro_hooks) {
            if self.written(Body::Fn(h), 0) & 1 != 0 {
                let (fname, _) = self.body_name(Body::Fn(h), 0, 1);
                let span = self.decls[self.fns[h].decl].item.span;
                self.errors.push(Diag::new(span, format!("{fname} changes this, but copying or printing a val calls it too: it can only read this")));
            }
        }
    }
}
