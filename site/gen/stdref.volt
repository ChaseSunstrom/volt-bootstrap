// The std reference: a page per std source file, from site/src/data/std.json (`voltc doc std`, kept
// in sync by tests/docs.rs). Each type gets its fields or variants and the methods attached to it;
// then the file's functions, methods on other types and globals. Rendered as the Astro page it
// replaces, through site/theme/stdref.html (its elements carry that component's scoped class, its
// code goes through Starlight's Code component).
use std::fmt;
use std::html;
use std::json;

// the std reference's pages, after the std docs in the sidebar
fn std_pages(site: str, group: usize, th: theme&, pages: std::vec<page>&) -> !void {
    val text = try std::fs::read_file(std::format("{}/src/data/std.json", site).as_str());
    var doc = try std::json::parse(text.as_str());
    val files = doc.get("files");
    val items = doc.get("items");
    for (k) in 0..files.len() {
        val f = files.at(k);
        val file = f.get("file").as_str() ?? "";
        val name = file[0..file.len - 5];
        var p: page = { path: std::format("std/{}", name), file: {}, section: std::string::from("std"), title: std::format("std::{}", name), description: file_doc(f.get("doc").as_str() ?? ""), body: {} };
        p.order = 2000000 + @cast<i64>(k);
        p.group = group;
        p.reference = true;
        std_page(th, name, items, &p);
        pages.push(move p);
    }
}

// the file's doc comment as one sentence: no package note, no "std::name:" lead, a capital first
fn file_doc(doc: str) -> std::string {
    var s: std::string = {};
    for (l&) in doc.lines().items() {
        if (l.starts_with("(Part of package std")) {
            continue;
        }
        if (s.len() > 0) {
            s.push(' ');
        }
        s.append(*l);
    }
    var t = s.as_str();
    if (t.starts_with("std::")) {
        val colon = t.find(":") ?? 0;
        val after = t[5..t.len].find(":");
        if (after) {
            var rest = t[5 + after + 1..t.len];
            rest = rest.trim_start();
            // only when it was std::NAME: (a word, then the colon)
            if (word_only(t[5..5 + after])) {
                t = rest;
            }
        }
    }
    var out: std::string = {};
    if (t.len > 0 && t[0] >= 'a' && t[0] <= 'z') {
        out.push(t[0] - 32);
        out.append(t[1..t.len]);
    } else {
        out.append(t);
    }
    return out;
}

fn word_only(s: str) -> bool {
    for (i) in 0..s.len {
        if (!word_char(s[i])) {
            return false;
        }
    }
    return s.len > 0;
}

fn kind_of(it: std::json::value&) -> str {
    return it.get("kind").as_str() ?? "";
}

fn is_type_kind(k: str) -> bool {
    return k == "struct" || k == "enum" || k == "error" || k == "trait";
}

// std::a::b::name
fn qual(it: std::json::value&, out: std::string&) -> void {
    out.append("std");
    val ns = it.get("namespace");
    for (i) in 0..ns.len() {
        out.append("::");
        out.append(ns.at(i).as_str() ?? "");
    }
    out.append("::");
    out.append(it.get("name").as_str() ?? "");
}

// lower case, runs of anything but [a-z0-9_] as one -
fn ref_slug(s: str) -> std::string {
    var out: std::string = {};
    var dash = false;
    for (i) in 0..s.len {
        var c = s[i];
        if (c >= 'A' && c <= 'Z') {
            c += 32;
        }
        if ((c >= 'a' && c <= 'z') || digit(c) || c == '_') {
            out.push(c);
            dash = false;
        } else if (!dash) {
            out.push('-');
            dash = true;
        }
    }
    return out;
}

// a doc comment: escaped, `code` as <code>, wrapped lines as one paragraph
fn prose(text: str, out: std::string&) -> void {
    var code = false;
    for (i) in 0..text.len {
        val c = text[i];
        if (c == '`') {
            // a lone backtick stays: only a pair makes code
            if (code || text[i + 1..text.len].contains("`")) {
                out.append(either(code, "</code>", "<code>"));
                code = !code;
                continue;
            }
        }
        if (c == '\n') {
            out.push(' ');
        } else {
            escape_char(c, out);
        }
    }
}

// text in a template: < > & " escaped
fn text(s: str, out: std::string&) -> void {
    for (i) in 0..s.len {
        if (s[i] == '"') {
            out.append("&quot;");
        } else {
            escape_char(s[i], out);
        }
    }
}

// one std page's content (site/theme/stdref.html) and table of contents
fn std_page(th: theme&, name: str, items: std::json::value&, p: page&) -> void {
    var first = true;
    val file = std::format("{}.volt", name);
    // what's in this file
    var types: std::vec<usize> = {};
    var fns: std::vec<usize> = {};
    var globals: std::vec<usize> = {};
    var others: std::vec<usize> = {};
    for (i) in 0..items.len() {
        val it = items.at(i);
        if ((it.get("file").as_str() ?? "") != file.as_str()) {
            continue;
        }
        val k = kind_of(it);
        if (is_type_kind(k)) {
            types.push(i);
        } else if (k == "fn") {
            fns.push(i);
        } else if (k == "global") {
            globals.push(i);
        } else if (k == "method" && !is_std_type(items, it.get("receiver").as_str() ?? "")) {
            others.push(i);
        }
    }
    // the values, in the page's order (its first signature brings the code stylesheet)
    var d = std::json::object();
    d.set("intro", prose_value(p.description.as_str()));
    d.set("name", std::json::string(name));
    var tv = std::json::array();
    if (types.len > 0) {
        p.headings.push({ depth: 2, id: std::string::from("types"), text: std::string::from("Types") });
    }
    for (ti&) in types.items() {
        val t = items.at(*ti);
        val tname = t.get("name").as_str() ?? "";
        val id = ref_slug(tname);
        var x = fn_value(th, t, &first);
        x.set("id", std::json::string(id.as_str()));
        x.set("kind", std::json::string(kind_of(t)));
        var impls = std::json::array();
        for (i) in 0..items.len() {
            val m = items.at(i);
            if (kind_of(m) == "impl" && (m.get("name").as_str() ?? "") == tname) {
                impls.add(std::json::string(m.get("trait").as_str() ?? ""));
            }
        }
        x.set("impls", move impls);
        // fields or variants
        var members = t.get("fields");
        var label = "Field";
        if (members.is_null()) {
            members = t.get("variants");
            label = "Variant";
        }
        x.set("label", std::json::string(label));
        var ms = std::json::array();
        for (m) in 0..members.len() {
            var mv = std::json::object();
            mv.set("sig", std::json::string(members.at(m).get("signature").as_str() ?? ""));
            mv.set("doc", prose_value(members.at(m).get("doc").as_str() ?? ""));
            ms.add(move mv);
        }
        x.set("members", move ms);
        // a trait's required functions
        val req = t.get("methods");
        var rs = std::json::array();
        for (m) in 0..req.len() {
            rs.add(fn_value(th, req.at(m), &first));
        }
        x.set("required", move rs);
        // methods attached to it, from any file
        var methods = std::json::array();
        for (i) in 0..items.len() {
            val m = items.at(i);
            if (kind_of(m) == "method" && (m.get("receiver").as_str() ?? "") == tname) {
                methods.add(fn_value(th, m, &first));
            }
        }
        x.set("methods", move methods);
        tv.add(move x);
        var shown: std::string = {};
        text(tname, &shown);
        p.headings.push({ depth: 3, id: move id, text: move shown });
    }
    d.set("types", move tv);
    if (fns.len > 0) {
        p.headings.push({ depth: 2, id: std::string::from("functions"), text: std::string::from("Functions") });
    }
    d.set("functions", fn_values(th, items, &fns, &first));
    if (others.len > 0) {
        p.headings.push({ depth: 2, id: std::string::from("methods-on-other-types"), text: std::string::from("Methods on other types") });
    }
    d.set("others", fn_values(th, items, &others, &first));
    if (globals.len > 0) {
        p.headings.push({ depth: 2, id: std::string::from("globals"), text: std::string::from("Globals") });
    }
    d.set("globals", fn_values(th, items, &globals, &first));
    var out: std::string = {};
    fill(&th.stdref, &d, &out);
    p.html = move out;
}

// an item's signature (as code), doc (as HTML) and qualified name
fn fn_value(th: theme&, it: std::json::value&, first: bool&) -> std::json::value {
    var x = std::json::object();
    var q: std::string = {};
    qual(it, &q);
    x.set("qual", std::json::string(q.as_str()));
    var sig: std::string = {};
    component_code(th, it.get("signature").as_str() ?? "", first, &sig);
    x.set("sig", std::json::string(sig.as_str()));
    x.set("doc", prose_value(it.get("doc").as_str() ?? ""));
    return x;
}

fn fn_values(th: theme&, items: std::json::value&, which: std::vec<usize>&, first: bool&) -> std::json::value {
    var xs = std::json::array();
    for (i&) in which.items() {
        xs.add(fn_value(th, items.at(*i), first));
    }
    return xs;
}

// a doc comment as HTML (see prose)
fn prose_value(text: str) -> std::json::value {
    var h: std::string = {};
    prose(text, &h);
    return std::json::string(h.as_str());
}

fn is_std_type(items: std::json::value&, name: str) -> bool {
    for (i) in 0..items.len() {
        val x = items.at(i);
        if (is_type_kind(kind_of(x)) && (x.get("name").as_str() ?? "") == name) {
            return true;
        }
    }
    return false;
}

// a signature through Starlight's Code component (wrapped); the page's first brings the stylesheet
fn component_code(th: theme&, sig: str, first: bool&, out: std::string&) -> void {
    code_frame(th, "volt", sig, *first, true, out);
    *first = false;
}
