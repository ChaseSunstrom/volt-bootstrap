// The std reference: a page per std source file, from site/src/data/std.json (`voltc doc std`, kept
// in sync by tests/docs.rs). Each type gets its fields or variants and the methods attached to it;
// then the file's functions, methods on other types and globals. Rendered as the Astro page it
// replaces (its elements carry that component's scoped class, its code goes through Starlight's
// Code component).
use std::fmt;

val SCOPED: str = "astro-e45xea6i";

// the std reference's pages, after the std docs in the sidebar
fn std_pages(site: str, group: usize, pages: std::vec<page>&) -> !void {
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
        std_page(name, items, &p);
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

fn doc_para(it: std::json::value&, out: std::string&) -> void {
    val d = it.get("doc").as_str() ?? "";
    if (d.len > 0) {
        std::write(out, "<p class=\"{}\">", SCOPED);
        prose(d, out);
        out.append("</p>");
    }
}

// one std page's content and table of contents
fn std_page(name: str, items: std::json::value&, p: page&) -> void {
    var out: std::string = {};
    var first = true;
    val file = std::format("{}.volt", name);
    std::write(&out, "<p class=\"{}\">", SCOPED);
    prose(p.description.as_str(), &out);
    std::write(&out, "</p><p class=\"std-source {}\">Source: <code class=\"{}\">std/{}.volt</code></p>", SCOPED, SCOPED, name);
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
    if (types.len > 0) {
        std::write(&out, "<h2 id=\"types\" class=\"{}\">Types</h2>", SCOPED);
        p.headings.push({ depth: 2, id: std::string::from("types"), text: std::string::from("Types") });
        for (ti&) in types.items() {
            val t = items.at(*ti);
            val tname = t.get("name").as_str() ?? "";
            val id = ref_slug(tname);
            std::write(&out, "<section class=\"std-item {}\"><h3 id=\"{}\" class=\"{}\"><span class=\"std-kind {}\">{}</span> ", SCOPED, id.as_str(), SCOPED, SCOPED, kind_of(t));
            qual(t, &out);
            out.append("</h3>");
            var shown: std::string = {};
            text(tname, &shown);
            p.headings.push({ depth: 3, id: move id, text: move shown });
            component_code(t.get("signature").as_str() ?? "", &first, &out);
            doc_para(t, &out);
            for (i) in 0..items.len() {
                val x = items.at(i);
                if (kind_of(x) == "impl" && (x.get("name").as_str() ?? "") == tname) {
                    std::write(&out, "<p class=\"{}\">Implements <code class=\"{}\">", SCOPED, SCOPED);
                    text(x.get("trait").as_str() ?? "", &out);
                    out.append("</code>.</p>");
                }
            }
            // fields or variants
            var members = t.get("fields");
            var label = "Field";
            if (members.is_null()) {
                members = t.get("variants");
                label = "Variant";
            }
            if (!members.is_null() && members.len() > 0) {
                std::write(&out, "<table class=\"{}\"><thead class=\"{}\"><tr class=\"{}\"><th class=\"{}\">{}</th><th class=\"{}\"></th></tr></thead><tbody class=\"{}\">", SCOPED, SCOPED, SCOPED, SCOPED, label, SCOPED, SCOPED);
                for (m) in 0..members.len() {
                    val mm = members.at(m);
                    std::write(&out, "<tr class=\"{}\"><td class=\"{}\"><code class=\"{}\">", SCOPED, SCOPED, SCOPED);
                    text(mm.get("signature").as_str() ?? "", &out);
                    std::write(&out, "</code></td><td class=\"{}\">", SCOPED);
                    prose(mm.get("doc").as_str() ?? "", &out);
                    out.append("</td></tr>");
                }
                out.append("</tbody></table>");
            }
            // a trait's required functions
            val req = t.get("methods");
            if (!req.is_null() && req.len() > 0) {
                std::write(&out, "<h4 class=\"{}\">Required functions</h4>", SCOPED);
                for (m) in 0..req.len() {
                    std::write(&out, "<div class=\"std-fn {}\">", SCOPED);
                    component_code(req.at(m).get("signature").as_str() ?? "", &first, &out);
                    doc_para(req.at(m), &out);
                    out.append("</div>");
                }
            }
            // methods attached to it, from any file
            var any = false;
            for (i) in 0..items.len() {
                val x = items.at(i);
                if (kind_of(x) == "method" && (x.get("receiver").as_str() ?? "") == tname) {
                    if (!any) {
                        std::write(&out, "<h4 class=\"{}\">Methods</h4>", SCOPED);
                        any = true;
                    }
                    std::write(&out, "<div class=\"std-fn {}\">", SCOPED);
                    component_code(x.get("signature").as_str() ?? "", &first, &out);
                    doc_para(x, &out);
                    out.append("</div>");
                }
            }
            out.append("</section>");
        }
    }
    if (fns.len > 0) {
        std::write(&out, "<h2 id=\"functions\" class=\"{}\">Functions</h2>", SCOPED);
        p.headings.push({ depth: 2, id: std::string::from("functions"), text: std::string::from("Functions") });
        for (fi&) in fns.items() {
            val f = items.at(*fi);
            std::write(&out, "<div class=\"std-fn {}\"><p class=\"std-name {}\"><code class=\"{}\">", SCOPED, SCOPED, SCOPED);
            qual(f, &out);
            out.append("</code></p>");
            component_code(f.get("signature").as_str() ?? "", &first, &out);
            doc_para(f, &out);
            out.append("</div>");
        }
    }
    if (others.len > 0) {
        std::write(&out, "<h2 id=\"methods-on-other-types\" class=\"{}\">Methods on other types</h2><p class=\"{}\">Attached to built-in types, or to every type (<code class=\"{}\">T</code>).</p>", SCOPED, SCOPED, SCOPED);
        p.headings.push({ depth: 2, id: std::string::from("methods-on-other-types"), text: std::string::from("Methods on other types") });
        for (oi&) in others.items() {
            val m = items.at(*oi);
            std::write(&out, "<div class=\"std-fn {}\">", SCOPED);
            component_code(m.get("signature").as_str() ?? "", &first, &out);
            doc_para(m, &out);
            out.append("</div>");
        }
    }
    if (globals.len > 0) {
        std::write(&out, "<h2 id=\"globals\" class=\"{}\">Globals</h2>", SCOPED);
        p.headings.push({ depth: 2, id: std::string::from("globals"), text: std::string::from("Globals") });
        for (gi&) in globals.items() {
            val g = items.at(*gi);
            std::write(&out, "<div class=\"std-fn {}\">", SCOPED);
            component_code(g.get("signature").as_str() ?? "", &first, &out);
            doc_para(g, &out);
            out.append("</div>");
        }
    }
    p.html = move out;
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
fn component_code(sig: str, first: bool&, out: std::string&) -> void {
    code_frame("volt", sig, *first, true, out);
    *first = false;
}
