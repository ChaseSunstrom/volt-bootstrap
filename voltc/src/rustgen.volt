// use rust's generics: bolt declares a generic Rust fn as a Volt generic marked
// @rust_generic("mod::f"), and makes a fn per instance a program asks for, f__ARGS next to it. A
// call's instance is that fn; one bolt hasn't made yet is asked for (rust_wants), and compile_with
// has bolt make them and checks the program again.

// an instance to ask an import's bolt for: its line in OUT/instances (the fn's path, then each
// type argument as Volt names it, tab-separated)
struct rust_want {
    out: std::string;
    line: std::string;
}

// fn decl d's @rust_generic path, if it has one
attach fn rust_generic_of(this: checker&, d: u32) -> str? {
    for (a&) in this.item_of(d).attrs.items() {
        match (a.kind) {
            .BUILTIN(n, g, x) => {
                if (n == "rust_generic") {
                    return attr_str(a);
                }
            },
            default => {},
        }
    }
    return null;
}

// the instance of generic Rust type d for args that bolt made (Stack__i32), or none (and it's asked
// for)
attach fn rust_type_instance(this: checker&, d: u32, path: str, args: std::vec<gval>&, span: span) -> compile_error!(u32?) {
    match (this.item_of(d).kind) {
        .STRUCT(sd&) => { return try this.rust_made(d, sd.name, path, args, true, span); },
        default => { return null; },
    }
}

// the instance of generic Rust fn d for args that bolt made (f__i32), or none (and it's asked for)
attach fn rust_instance(this: checker&, d: u32, path: str, args: std::vec<gval>&, span: span) -> compile_error!(u32?) {
    val f = this.fn_decl_of(d) ?? return null;
    return try this.rust_made(d, f->name, path, args, false, span);
}

// what bolt made of generic d (named base) for args, NAME__ARGS next to it: a fn instance, or a
// type when is_type; none, and it's asked for, when it hasn't
attach fn rust_made(this: checker&, d: u32, base: str, path: str, args: std::vec<gval>&, is_type: bool, span: span) -> compile_error!(u32?) {
    var name = S(base);
    name.append("__");
    var line = S(path);
    for (k) in 0..args.len {
        match (*args.at(k)) {
            .TY(t) => {
                val tn = this.ty_name(t);
                if (k > 0) {
                    name.push('_');
                }
                name.append(ident_of(tn.as_str()).as_str());
                line.push('\t');
                line.append(tn.as_str());
            },
            default => { return null; },
        }
    }
    val l = this.ns(this.dl(d).ns).names.get(this.intern(copy name));
    if (l) {
        for (m&) in this.list(*l).items() {
            if (is_type) {
                match (this.item_of(*m).kind) {
                    .STRUCT(x) => { return try this.struct_inst(*m, {}, span); },
                    default => {},
                }
            } else if (this.fn_decl_of(*m) != null) {
                return try this.fn_inst(*m, {}, span);
            }
        }
    }
    val out = this.import_outs.get(this.dl(d).item.span.file) ?? return null;
    if (this.opts.rust_again) {
        // bolt was asked: rustc's reason, when it rejected the instance (OUT/instances.failed)
        var what = S(path);
        what.push('<');
        what.append(line.as_str()[path.len + 1..line.len()].replace("\t", ", ").as_str());
        what.push('>');
        var failed = copy *out;
        failed.append("/instances.failed");
        val text = std::fs::read_file(failed.as_str()) catch |e| S("");
        var prefix = copy line;
        prefix.push('\t');
        for (l) in text.as_str().lines().items() {
            if (starts_with(l, prefix.as_str())) {
                return with_help(fail(span, fmt2("{}: Rust doesn't take these types: {}", move what, S(l[prefix.len()..l.len]))), S("each instance a program calls is built by rustc, which checks the fn's bounds for its types"));
            }
        }
        // or bolt's, from what its declarations left out (//   NAME__ARGS (why))
        var vf = copy *out;
        vf.append("/import.volt");
        val decls = std::fs::read_file(vf.as_str()) catch |e| S("");
        var left = S("//   ");
        left.append(name.as_str());
        left.append(" (");
        for (l) in decls.as_str().lines().items() {
            val t = l.trim();
            if (starts_with(t, left.as_str()) && t.len > left.len() + 1) {
                return fail(span, fmt2("{}: Volt can't use this instance: {}", move what, S(t[left.len()..t.len - 1])));
            }
        }
        return with_help(fail(span, fmt("{}: bolt couldn't make this instance", move what)), S("VOLT_SHOW_IMPORT=1 shows the import's declarations, and why an instance was left out"));
    }
    for (w&) in this.rust_wants.items() {
        if (w.line.as_str() == line.as_str() && w.out.as_str() == out.as_str()) {
            return null;
        }
    }
    put(&this.rust_wants, { out: copy *out, line: move line });
    return null;
}

// asks each import's bolt for the instances the check wanted: adds them to its OUT/instances (what
// was there stays: other programs share the import); whether any are new
attach fn ask_rust(this: checker&) -> bool {
    var added = false;
    for (w&) in this.rust_wants.items() {
        var file = copy w.out;
        file.append("/instances");
        var text = std::fs::read_file(file.as_str()) catch |e| S("");
        var have = false;
        for (l) in text.as_str().lines().items() {
            if (l == w.line.as_str()) {
                have = true;
            }
        }
        if (have) {
            continue;
        }
        text.append(w.line.as_str());
        text.push('\n');
        std::fs::write_file(file.as_str(), text.as_str()) catch |e| {
            continue;
        };
        added = true;
    }
    return added;
}
