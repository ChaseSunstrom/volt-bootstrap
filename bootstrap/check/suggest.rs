// "Did you mean" help for misspelled names: the candidates a name could have meant (locals, generic
// params, names in the enclosing namespaces, a namespace's members, a struct's fields) and the
// closest one by edit distance. voltc/src/suggest.volt picks the same one.

use super::*;

/// edits (insert, delete, replace, swap two neighbours) to turn a into b
pub fn distance(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut d = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for j in 0..=b.len() {
        d[0][j] = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = (a[i - 1] != b[j - 1]) as usize;
            let mut v = (d[i - 1][j] + 1).min(d[i][j - 1] + 1).min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                v = v.min(d[i - 2][j - 2] + 1);
            }
            d[i][j] = v;
        }
    }
    d[a.len()][b.len()]
}

/// the candidate closest to `name`, if it's close enough to be a likely typo (a third of the name's
/// length, at least 1); ties go to the alphabetically first, so hash order never decides
pub fn closest(name: &str, cands: &[String]) -> Option<String> {
    let limit = name.chars().count().max(3) / 3;
    let mut best: Option<(usize, &String)> = None;
    for c in cands {
        if c == name || c.starts_with('@') {
            continue;
        }
        let d = distance(name, c);
        if d <= limit && best.is_none_or(|(bd, bc)| d < bd || (d == bd && c < bc)) {
            best = Some((d, c));
        }
    }
    best.map(|(_, c)| c.clone())
}

impl Checker {
    /// every name declared in namespace n: its items and child namespaces
    fn ns_names(&self, n: NsId, out: &mut Vec<String>) {
        out.extend(self.nss[n].names.keys().cloned());
        out.extend(self.nss[n].children.keys().cloned());
    }

    /// what the unresolved part of path p could have meant, seen from namespace ns: for a lone name,
    /// the locals and generic params in scope and every name in the enclosing namespaces; for a::b,
    /// the members of a (and of what `use a::...` imports)
    pub fn path_candidates(&self, ns: NsId, p: &Path, locals: bool) -> Vec<String> {
        let mut out = Vec::new();
        if p.segs.len() == 1 || self.lookup(ns, &p.segs[0].name).is_none() {
            if locals && p.segs.len() == 1 {
                for s in &self.cx.scopes {
                    out.extend(s.vars.keys().cloned());
                }
                out.extend(self.cx.env.generics.iter().map(|(n, _)| n.clone()));
            }
            let mut cur = Some(ns);
            while let Some(n) = cur {
                self.ns_names(n, &mut out);
                cur = self.nss[n].parent;
            }
        } else {
            let prefix = Path { segs: p.segs[..p.segs.len() - 1].to_vec(), span: p.span };
            if let Some(Found::Ns(n)) = self.lookup_path_ns(ns, &prefix) {
                self.ns_names(n, &mut out);
            }
            if p.segs.len() == 2 {
                // `use a::b::c;` makes c's members reachable as a::name
                let mut cur = Some(ns);
                while let Some(n) = cur {
                    for u in self.nss[n].uses.iter().filter(|u| u.segs[0].name == p.segs[0].name) {
                        let mut target = Some(Found::Ns(0));
                        for seg in &u.segs {
                            target = match target {
                                Some(Found::Ns(m)) => self.ns_member(m, &seg.name),
                                _ => None,
                            };
                        }
                        match target {
                            Some(Found::Ns(m)) => self.ns_names(m, &mut out),
                            Some(_) => out.push(u.last().to_string()),
                            None => {}
                        }
                    }
                    cur = self.nss[n].parent;
                }
            }
        }
        out.sort();
        out.dedup();
        out
    }

    /// `unknown name 'x'` / `unknown type 'x'`, with a did-you-mean when a close name exists
    pub fn unknown(&self, span: Span, what: &str, ns: NsId, p: &Path, locals: bool) -> Diag {
        let missing = self.missing_part(ns, p);
        let mut cands = self.path_candidates(ns, p, locals);
        if what == "type" && (p.segs.len() == 1) {
            cands.extend(["void", "never", "bool", "type", "str", "cstr", "f16", "f32", "f64", "f128", "error"].map(String::from));
            cands.extend(crate::types::INTS.iter().map(|k| k.name().to_string()));
            cands.sort();
            cands.dedup();
        }
        let d = Diag::new(span, format!("unknown {what} '{missing}'"));
        match closest(&missing, &cands) {
            Some(c) => d.help(format!("did you mean '{c}'?")),
            None => d,
        }
    }

    /// `T has no field 'x'`, with a did-you-mean from the fields that exist
    pub fn no_field(&self, span: Span, ty: TyId, name: &str, fields: &[String]) -> Diag {
        let d = Diag::new(span, format!("{} has no field '{name}'", self.ty_name(ty)));
        let mut cands = fields.to_vec();
        cands.sort();
        match closest(name, &cands) {
            Some(c) => d.help(format!("did you mean '{c}'?")),
            None => d,
        }
    }

    /// the span of `name` inside an item's span s (all of s when it isn't there): where an error
    /// about a declaration points
    pub fn name_span(&self, s: Span, name: &str) -> Span {
        let text = &self.sm.files[s.file as usize].1;
        let (lo, hi) = ((s.lo as usize).min(text.len()), (s.hi as usize).min(text.len()));
        let body = &text[lo..hi];
        let word = |c: u8| c.is_ascii_alphanumeric() || c == b'_';
        let mut from = 0;
        while let Some(i) = body[from..].find(name).map(|i| i + from) {
            let before = i == 0 || !word(body.as_bytes()[i - 1]);
            let after = i + name.len() >= body.len() || !word(body.as_bytes()[i + name.len()]);
            if before && after && !name.is_empty() {
                return Span { file: s.file, lo: (lo + i) as u32, hi: (lo + i + name.len()) as u32 };
            }
            from = i + name.len().max(1);
        }
        s
    }
}
