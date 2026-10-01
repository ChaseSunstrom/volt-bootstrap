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
// where a pointer points. A reference that's returned, or stored in a struct or array, doesn't carry
// where it points (T-0156).
use super::*;

/// what a call runs: a fn instance, a closure's body, or whatever a fn value of this type holds
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Body {
    Fn(usize),
    Closure(u32),
    Value(TyId),
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

    /// &place's provenance: read-only where the place can't change (depth 0) and where what it holds
    /// points at what can't (deeper); the parameter memory it is
    pub fn addr_prov(place: &Val) -> (u32, Via, Option<String>) {
        let ro = (place.lv && !place.mutable) as u32 | (place.ro << 1);
        (ro, place.pvia.or(deeper(place.via, -1)), place.root.clone())
    }

    /// the place a reference (pointer, slice) value `r` reaches: mutable unless r's pointee is
    /// read-only, the parameter memory r points at, and what it holds one depth further
    pub fn through(place: Val, r: &Val) -> Val {
        Val { mutable: place.mutable && r.ro & 1 == 0, rop: r.ro & 1 != 0, pvia: r.via, ro: r.ro >> 1, via: deeper(r.via, 1), root: r.root.clone(), ..place }
    }

    /// a value from either of two (a ?? b, match arms): read-only where either is
    pub fn merge_prov(into: &mut (u32, Via, Option<String>), v: &Val) {
        into.0 |= v.ro;
        into.1 = into.1.or(v.via);
        if into.2.is_none() {
            into.2 = v.root.clone();
        }
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

    /// assigning to `place`: a write through the parameter it's reached through
    pub fn note_write(&mut self, place: &Val) {
        if let (Some((k, d)), Some(b)) = (place.pvia, self.cx.body) {
            if (0..64).contains(&d) {
                self.mark(b, k as usize, 1 << d);
            }
        }
    }

    /// passing a reference (pointer, slice) with this provenance to parameter `param` of `callee`
    pub fn note_arg(&mut self, callee: Body, param: usize, ro: u32, via: Via, root: Option<&str>, span: Span) {
        if let Body::Fn(i) = callee {
            if !self.reaches(self.fns[i].params.get(param).map_or(VOID, |p| p.ty)) || self.fns[i].intrinsic.is_some() {
                return;
            }
            if matches!(&self.decls[self.fns[i].decl].item.kind, ItemKind::Fn(f) if f.extern_abi.is_some() && f.body.is_none()) {
                return; // C: unchecked
            }
        }
        if ro != 0 {
            let root = root.unwrap_or("this").to_string();
            let root_param = self.lookup_local(&root).is_some_and(|l| l.param);
            self.lends.push(Lend { span, callee, param, mask: ro, root, root_param });
        }
        if let (Some((k, off)), Some(b)) = (via, self.cx.body) {
            self.edges.push((b, k as usize, off, callee, param));
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

    /// Solve the writes (a parameter is written through when its body writes through it, or passes
    /// it on to one that's written through) and report each lend to one.
    pub fn check_lends(&mut self) {
        loop {
            let mut changed = false;
            for i in 0..self.edges.len() {
                let (f, k, off, g, j) = self.edges[i];
                let w = shift(self.written(g, j), off);
                if w != 0 {
                    changed |= self.mark(f, k, w);
                }
            }
            if !changed {
                break;
            }
        }
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
