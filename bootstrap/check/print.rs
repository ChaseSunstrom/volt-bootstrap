// std::io::println / print: format strings are checked at compile time and lowered to
// one print call per piece.
// ponytail: compiler intrinsic, move to Volt std once comptime can walk fmt strings.
use super::cty::c_str_lit;
use super::*;

impl Checker {
    /// The formatting intrinsics std declares: println, print, eprintln, eprint (to stdout or
    /// stderr), write (to a writer: `std::write(&out, fmt, args...)`) and format (a new value of the
    /// type its declaration returns, `ret`). The format string splits into text and {} holes at
    /// compile time; the values go into temps in order, and temporaries that own something are
    /// deleted after printing. Everything goes through one sink (VOLT_E in the C): a stream, or a
    /// writer's write_str.
    pub fn intrinsic(&mut self, name: &str, args: &[Expr], ret: TyId, span: Span) -> Res<Val> {
        let newline = matches!(name, "println" | "eprintln");
        let mut setup = match name {
            "println" | "print" => "const volt_sink *VOLT_E = volt_stdout(); ".to_string(),
            "eprintln" | "eprint" => "const volt_sink *VOLT_E = volt_stderr(); ".to_string(),
            "write" | "format" => String::new(),
            _ => return err(span, format!("unknown intrinsic '{name}'")),
        };
        let mut args = args;
        if name == "write" {
            let Some(target) = args.first() else { return err(span, "std::write takes a writer, a format and its values: std::write(&out, \"{}\", x)") };
            let w = self.expr(target, None)?;
            let Ty::Ref(wt) = self.t.get(w.ty).clone() else { return err(target.span, "std::write takes a reference to the writer: std::write(&out, ...)") };
            let Some(h) = self.hook(wt, "write_str")? else {
                let n = self.ty_name(wt);
                return err(target.span, format!("std::write needs a writer: {n} doesn't attach write_str(this: {n}&, s: str) -> void"));
            };
            let thunk = self.sink_fn(wt, h);
            setup = format!("volt_sink _sk = {{ {thunk}, (void*)({}) }}; const volt_sink *VOLT_E = &_sk; ", w.c);
            args = &args[1..];
        }
        let mut result = None;
        if name == "format" {
            let Some(h) = self.hook(ret, "write_str")? else {
                let n = self.ty_name(ret);
                return err(span, format!("std::format needs a writer type: {n} doesn't attach write_str(this: {n}&, s: str) -> void"));
            };
            let thunk = self.sink_fn(ret, h);
            let init = self.literal(&[], Some(ret), span)?;
            let rc = self.cty(ret);
            let f = self.tmp("f");
            setup = format!("{rc} {f} = {}; volt_sink _sk = {{ {thunk}, &{f} }}; const volt_sink *VOLT_E = &_sk; ", init.c);
            result = Some(f);
        }
        // text or a value's index (with its {:spec})
        let mut pieces: Vec<Result<Vec<u8>, (usize, Option<Spec>)>> = Vec::new();
        // the first argument is a format string when values follow it or it has a {} in it
        let fmt_arg = match args.first().map(|a| &a.kind) {
            Some(ExprKind::Str(s)) if args.len() > 1 || s.windows(2).any(|w| w == b"{}") || s.windows(2).any(|w| w == b"{:") => Some(s.clone()),
            _ => None,
        };
        let value_args: &[Expr] = match &fmt_arg {
            Some(fmt) => {
                let mut text = Vec::new();
                let mut next = 0;
                let mut i = 0;
                while i < fmt.len() {
                    match (fmt[i], fmt.get(i + 1)) {
                        (b'{', Some(b'{')) | (b'}', Some(b'}')) => {
                            text.push(fmt[i]);
                            i += 2;
                        }
                        (b'{', Some(b'}')) => {
                            pieces.push(Ok(std::mem::take(&mut text)));
                            pieces.push(Err((next, None)));
                            next += 1;
                            i += 2;
                        }
                        (b'{', Some(b':')) => {
                            let Some(close) = fmt[i..].iter().position(|&c| c == b'}') else {
                                return err(args[0].span, "use {} for a value, {{ and }} for braces");
                            };
                            let spec = parse_spec(&fmt[i + 2..i + close]).map_err(|m| Diag::new(args[0].span, m))?;
                            pieces.push(Ok(std::mem::take(&mut text)));
                            pieces.push(Err((next, spec)));
                            next += 1;
                            i += close + 1;
                        }
                        (b'{', _) | (b'}', _) => return err(args[0].span, "use {} for a value, {{ and }} for braces"),
                        (c, _) => {
                            text.push(c);
                            i += 1;
                        }
                    }
                }
                pieces.push(Ok(text));
                if next != args.len() - 1 {
                    return err(span, format!("format string has {next} {{}} but {} values were given", args.len() - 1));
                }
                &args[1..]
            }
            None => {
                if args.len() > 1 {
                    return err(span, "println with several values needs a format string first: println(\"{} {}\", a, b)");
                }
                if !args.is_empty() {
                    pieces.push(Err((0, None)));
                }
                args
            }
        };
        // evaluate values in order into temps
        let mut code = String::new();
        let mut drops = String::new();
        let mut temps = Vec::new();
        for a in value_args {
            let v = self.expr(a, None)?;
            if v.ty == VOID || v.ty == NEVER {
                return err(a.span, "this has no value to print");
            }
            let v = if v.ty == NULL { Val::pure(NULL, "0") } else { v };
            let t = self.tmp("p");
            let cty = self.cty(v.ty);
            code.push_str(&format!("{cty} {t} = {}; ", v.c));
            if !v.lv && self.needs_drop(v.ty)? {
                let d = self.drop_fn(v.ty)?;
                drops.push_str(&format!("{d}(&{t}); "));
            }
            temps.push((t, v.ty, a.span));
        }
        // the program's streams are held for the whole output, so threads' lines don't mix
        let stream = !matches!(name, "write" | "format");
        if stream {
            code.push_str("volt_lock_out(); ");
        }
        for p in pieces {
            match p {
                Ok(text) if text.is_empty() => {}
                Ok(text) => code.push_str(&format!("volt_out(VOLT_E, \"%s\", {}); ", c_str_lit(&text))),
                Err((i, None)) => {
                    let (t, ty, _) = temps[i].clone();
                    code.push_str(&self.print_code(&t, ty, span)?);
                }
                Err((i, Some(sp))) => {
                    let (t, ty, at) = temps[i].clone();
                    code.push_str(&self.spec_code(&t, ty, sp, at)?);
                }
            }
        }
        if newline {
            code.push_str("volt_out(VOLT_E, \"\\n\");");
        }
        if stream {
            code.push_str(" volt_unlock_out(); ");
        }
        code.push_str(&drops);
        Ok(match result {
            Some(f) => Val::new(ret, format!("({{ {setup}{code} {f}; }})")),
            None => Val::stmt(format!("{{ {setup}{code} }}")),
        })
    }

    /// C statements formatting value `c` of type `ty` by a {:spec}: numbers, bool, text (str,
    /// cstr, a type that attaches as_str), and integers as characters with {:c}
    fn spec_code(&mut self, c: &str, ty: TyId, sp: Spec, span: Span) -> Res<String> {
        let name = self.ty_name(ty);
        let kind = sp.ty as char;
        let pad = format!("{}u, {}, {}, {}", sp.fill, sp.align, sp.flags, sp.width);
        let for_ints = matches!(kind, 'x' | 'X' | 'b' | 'o' | 'c');
        let for_floats = matches!(kind, 'e' | 'E');
        match self.t.get(ty).clone() {
            Ty::Int(k) => {
                if sp.prec >= 0 {
                    return err(span, format!("precision applies to floats and text, not {name}"));
                }
                if for_floats {
                    return err(span, format!("{{:{kind}}} formats floats, not {name}"));
                }
                Ok(if k.signed() {
                    format!("volt_fmt_i(VOLT_E, (__int128)({c}), {}, {pad}, {}); ", k.bits(), sp.ty)
                } else {
                    format!("volt_fmt_u(VOLT_E, (unsigned __int128)({c}), 0, {pad}, {}); ", sp.ty)
                })
            }
            Ty::Float(b) => {
                if for_ints {
                    return err(span, format!("{{:{kind}}} formats integers, not {name}"));
                }
                Ok(format!("volt_fmt_f(VOLT_E, (double)({c}), {}, {pad}, {}, {}); ", (b == 32) as i32, sp.prec, sp.ty))
            }
            t => {
                let text = match t {
                    Ty::Bool => Some(format!("volt_fmt_bool(VOLT_E, ({c}) ? 1 : 0, {pad}, {}); ", sp.prec)),
                    Ty::Str => Some(format!("volt_fmt_text(VOLT_E, {c}, {pad}, {}); ", sp.prec)),
                    Ty::CStr => Some(format!("volt_fmt_cstr(VOLT_E, {c}, {pad}, {}); ", sp.prec)),
                    Ty::Struct(_) => match self.hook(ty, "as_str")? {
                        Some(h) => {
                            self.use_fn(h);
                            Some(format!("volt_fmt_text(VOLT_E, {}(&({c})), {pad}, {}); ", self.fns[h].c_name, sp.prec))
                        }
                        None => None,
                    },
                    _ => None,
                };
                let Some(text) = text else { return err(span, format!("a format spec needs a number, bool, character or text, not {name}")) };
                if for_ints {
                    return err(span, format!("{{:{kind}}} formats integers, not {name}"));
                }
                if for_floats {
                    return err(span, format!("{{:{kind}}} formats floats, not {name}"));
                }
                Ok(text)
            }
        }
    }

    /// the C function std::write and std::format give the sink for a writer of type ty: it calls
    /// the writer's write_str (h)
    fn sink_fn(&mut self, ty: TyId, h: usize) -> String {
        if let Some(n) = self.glue_names.get(&(ty, "sink")) {
            return n.clone();
        }
        let name = format!("volt_sink_{ty}");
        self.glue_names.insert((ty, "sink"), name.clone());
        self.use_fn(h);
        let tc = self.cty(ty);
        self.glue_protos.push_str(&format!("static void {name}(void* ctx, volt_str s);\n"));
        self.glue.push_str(&format!("static void {name}(void* ctx, volt_str s) {{ {}(({tc}*)ctx, s); }}\n", self.fns[h].c_name));
        name
    }

    /// C statements printing value `c` of type `ty`
    pub fn print_code(&mut self, c: &str, ty: TyId, span: Span) -> Res<String> {
        Ok(match self.t.get(ty).clone() {
            Ty::Int(k) if k.bits() == 128 => format!("volt_print_{}128(VOLT_E, {c}); ", if k.signed() { "i" } else { "u" }),
            Ty::Int(k) if k.signed() => format!("volt_out(VOLT_E, \"%lld\", (long long)({c})); "),
            Ty::Int(_) => format!("volt_out(VOLT_E, \"%llu\", (unsigned long long)({c})); "),
            Ty::Float(32) => format!("volt_print_f32(VOLT_E, (float)({c})); "),
            Ty::Float(_) => format!("volt_print_f64(VOLT_E, (double)({c})); "),
            Ty::Bool => format!("volt_out(VOLT_E, \"%s\", ({c}) ? \"true\" : \"false\"); "),
            Ty::Str => format!("volt_print_str(VOLT_E, {c}); "),
            Ty::CStr => format!("volt_out(VOLT_E, \"%s\", {c}); "),
            Ty::Null => "volt_out(VOLT_E, \"null\"); ".into(),
            Ty::Ref(_) | Ty::FnPtr(..) => format!("volt_out(VOLT_E, \"%p\", (void*)({c})); "),
            Ty::Ptr(_) | Ty::VoidPtr => format!("{{ void* _pp = (void*)({c}); if (_pp) volt_out(VOLT_E, \"%p\", _pp); else volt_out(VOLT_E, \"null\"); }} "),
            Ty::FnVal(..) | Ty::Closure(_) => "volt_out(VOLT_E, \"<fn>\"); ".into(),
            Ty::Opt(inner) => {
                let (test, val) = if self.t.is_niche(inner) { (c.to_string(), c.to_string()) } else { (format!("({c}).has"), format!("({c}).v")) };
                let inner_code = self.print_code(&val, inner, span)?;
                format!("if ({test}) {{ {inner_code}}} else volt_out(VOLT_E, \"null\"); ")
            }
            Ty::Array(t, n) => {
                let inner = self.print_code("(*_e)", t, span)?;
                let et = self.cty(t);
                format!("volt_out(VOLT_E, \"{{ \"); for (size_t _i = 0; _i < {n}; _i++) {{ {et}* _e = &({c}).a[_i]; if (_i) volt_out(VOLT_E, \", \"); {inner}}} volt_out(VOLT_E, \" }}\"); ")
            }
            Ty::Slice(t) => {
                let inner = self.print_code("(*_e)", t, span)?;
                let et = self.cty(t);
                format!("volt_out(VOLT_E, \"{{ \"); for (size_t _i = 0; _i < ({c}).len; _i++) {{ {et}* _e = &({c}).ptr[_i]; if (_i) volt_out(VOLT_E, \", \"); {inner}}} volt_out(VOLT_E, \" }}\"); ")
            }
            Ty::Tuple(ts, _) => {
                let mut code = "volt_out(VOLT_E, \"(\"); ".to_string();
                for (i, t) in ts.iter().enumerate() {
                    if i > 0 {
                        code.push_str("volt_out(VOLT_E, \", \"); ");
                    }
                    code.push_str(&self.print_code(&format!("({c}).f{i}"), *t, span)?);
                }
                code + "volt_out(VOLT_E, \")\"); "
            }
            Ty::Range(t) => {
                let lo = self.print_code(&format!("({c}).lo"), t, span)?;
                let hi = self.print_code(&format!("({c}).hi"), t, span)?;
                format!("{lo}volt_out(VOLT_E, \"..\"); {hi}")
            }
            // a type that attaches as_str(this: T&) -> str prints as that text (std's string does)
            Ty::Struct(_) if self.hook(ty, "as_str")?.is_some() => {
                let h = self.hook(ty, "as_str")?.unwrap();
                self.use_fn(h);
                format!("volt_print_str(VOLT_E, {}(&({c}))); ", self.fns[h].c_name)
            }
            Ty::Struct(_) if self.owner(ty).is_some() => {
                let (pf, inner) = self.owner(ty).unwrap();
                self.print_code(&format!("(*({c}).{})", c_field(&pf)), inner, span)?
            }
            Ty::Struct(sid) => {
                let fields = self.struct_fields(sid, span)?;
                let name = self.structs[sid as usize].name.clone();
                let mut code = format!("volt_out(VOLT_E, \"%s {{ \", {}); ", c_str_lit(name.as_bytes()));
                for (i, f) in fields.iter().enumerate() {
                    let sep = if i > 0 { ", " } else { "" };
                    code.push_str(&format!("volt_out(VOLT_E, \"{sep}{}: \"); ", f.name));
                    code.push_str(&self.print_code(&format!("({c}).{}", c_field(&f.name)), f.ty, span)?);
                }
                code + "volt_out(VOLT_E, \" }\"); "
            }
            Ty::Enum(e) => self.print_enum(c, e, span)?,
            Ty::TraitUnion(u) => {
                let members = self.unions[u as usize].members.clone();
                let mut code = format!("switch (({c}).tag) {{ ");
                for (i, m) in members.iter().enumerate() {
                    code.push_str(&format!("case {i}: {}break; ", self.print_code(&format!("({c}).u.m{i}"), *m, span)?));
                }
                code + "} "
            }
            Ty::AnyErr => format!("volt_out(VOLT_E, \"%s\", volt_err_name({c})); "),
            Ty::ErrUnion(e, t) => {
                let code = self.eu_code(ty, c);
                let pe = self.print_code(&format!("({c}).err"), e, span)?;
                let pv = if t == VOID { String::new() } else { self.print_code(&format!("({c}).v"), t, span)? };
                format!("if ({code}) {{ volt_out(VOLT_E, \"error.\"); {pe}}} else {{ {pv}}} ")
            }
            _ => return err(span, format!("can't print a {} yet", self.ty_name(ty))),
        })
    }
}

/// a {:spec}: [[fill]align][sign][#][0][width][.precision][type]
#[derive(Clone, Copy)]
pub(super) struct Spec {
    fill: u32,  // a code point
    align: u8,  // b'<', b'>', b'^' or 0 (numbers right, text left)
    flags: u8,  // 1 '+', 2 '#', 4 '0'
    width: i32, // -1: none
    prec: i32,  // -1: none
    ty: u8,     // 0 or one of x X b o e E c
}

/// the text between `{:` and `}`; None when it's empty (a plain {})
fn parse_spec(s: &[u8]) -> Result<Option<Spec>, String> {
    if s.is_empty() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(s);
    let chars: Vec<char> = text.chars().collect();
    let mut sp = Spec { fill: ' ' as u32, align: 0, flags: 0, width: -1, prec: -1, ty: 0 };
    let is_align = |c: char| matches!(c, '<' | '>' | '^');
    let mut i = 0;
    if chars.len() >= 2 && is_align(chars[1]) {
        (sp.fill, sp.align, i) = (chars[0] as u32, chars[1] as u8, 2);
    } else if is_align(chars[0]) {
        (sp.align, i) = (chars[0] as u8, 1);
    }
    if i < chars.len() && (chars[i] == '+' || chars[i] == '-') {
        if chars[i] == '+' {
            sp.flags |= 1;
        }
        i += 1;
    }
    if i < chars.len() && chars[i] == '#' {
        sp.flags |= 2;
        i += 1;
    }
    if i < chars.len() && chars[i] == '0' {
        sp.flags |= 4;
        i += 1;
    }
    // widths and precisions stop growing at a million
    let number = |i: &mut usize| -> Option<i32> {
        let start = *i;
        let mut n: i32 = 0;
        while *i < chars.len() && chars[*i].is_ascii_digit() {
            n = (n * 10 + (chars[*i] as i32 - '0' as i32)).min(1_000_000);
            *i += 1;
        }
        (*i > start).then_some(n)
    };
    if let Some(w) = number(&mut i) {
        sp.width = w;
    }
    if i < chars.len() && chars[i] == '.' {
        i += 1;
        sp.prec = number(&mut i).ok_or("precision needs a number after the '.': {:.2}")?;
    }
    if i < chars.len() {
        if i + 1 == chars.len() && matches!(chars[i], 'x' | 'X' | 'b' | 'o' | 'e' | 'E' | 'c') {
            sp.ty = chars[i] as u8;
        } else {
            let rest: String = chars[i..].iter().collect();
            return Err(format!("unknown format type '{rest}' (x, X, b, o, e, E or c)"));
        }
    }
    Ok(Some(sp))
}
