// The site's generator: the docs (site/src/content/docs, Markdown), the std reference
// (site/src/data/std.json) and the landing page into site/dist, with Starlight's look: its page
// markup (site/theme/*.html, cut from a Starlight build, as std::html templates) and its built CSS
// and scripts (site/theme/assets). From the repository:
//   voltc run site/gen/*.volt -- [SITE_DIR [OUT_DIR]]
use std::io;
use std::fmt;
use std::fs;
use std::html;
use std::json;

val BASE: str = "/volt-bootstrap";
val SITE_URL: str = "https://chasesunstrom.github.io/volt-bootstrap/";

// a page: a doc, a std reference page or the landing page
struct page {
    path: std::string;        // under BASE, no slashes at the ends: guide/basics
    file: std::string;        // the source under the docs directory (guide/basics.md), or ""
    section: std::string;     // the sidebar group's directory
    title: std::string;
    description: std::string;
    order: i64 = 1000000;
    group: usize = 0;         // its place in GROUPS
    body: std::string;        // the Markdown after the frontmatter
    reference: bool = false;  // a std reference page: html and headings are made already
    html: std::string = {};
    headings: std::vec<heading> = {};
}

// site/theme's templates (std::html), read once
struct theme {
    page: std::html::template;     // a docs or std reference page
    landing: std::html::template;  // the landing page
    stdref: std::html::template;   // a std reference page's content
    heading: std::html::template;  // an h2 or h3 with its anchor link
    code: std::html::template;     // an Expressive Code frame
    shiki: std::html::template;    // code on the landing page
    sitemap: std::html::template;
}

fn load_theme(site: str) -> !theme {
    return {
        page: try read_template(site, "page.html"),
        landing: try read_template(site, "landing.html"),
        stdref: try read_template(site, "stdref.html"),
        heading: try read_template(site, "heading.html"),
        code: try read_template(site, "code.html"),
        shiki: try read_template(site, "shiki.html"),
        sitemap: try read_template(site, "sitemap.xml"),
    };
}

fn read_template(site: str, name: str) -> !std::html::template {
    val t = std::html::template::read(std::format("{}/theme/{}", site, name).as_str()) catch |e| {
        std::eprintln("site/theme/{}: {}", name, e);
        return e;
    };
    return t;
}

// t with d's values, after out's text; a failure is a value the template names and site/gen doesn't
// give it, a bug in one or the other
fn fill(t: std::html::template&, d: std::json::value&, out: std::string&) -> void {
    t.render(d, out) catch |e| {
        @panic("a site/theme template names a value site/gen doesn't give it");
    };
}

// the sidebar's groups, in order: a docs directory and its label
val GROUPS: (str, str)[8] = {
    ("start", "Start here"),
    ("guide", "Language guide"),
    ("std", "Standard library"),
    ("voltc", "voltc"),
    ("bolt", "bolt"),
    ("interop", "Interop"),
    ("editors", "Editors"),
    ("internals", "Internals"),
};

error site_error {
    BROKEN_LINKS,
}

fn main() -> !void {
    val site = std::process::arg(1) ?? "site";
    val out = std::process::arg(2) ?? "site/dist";
    val docs = std::format("{}/src/content/docs", site);
    val th = try load_theme(site);
    val std_css = try std::fs::read_file(std::format("{}/theme/std.css", site).as_str());

    // the docs, grouped and ordered as the sidebar shows them
    var pages: std::vec<page> = {};
    for (g&, gi) in GROUPS {
        val dir = std::format("{}/{}", docs.as_str(), g.0);
        for (f&) in (try std::fs::walk(dir.as_str())).items() {
            if (f.as_str().ends_with(".md")) {
                var p = try read_page(docs.as_str(), f.as_str(), g.0);
                p.group = gi;
                pages.push(move p);
            }
        }
    }
    try std_pages(site, 2, &th, &pages);
    pages.items().sort_by(|| (a: page&, b: page&) -> i32 {
        if (a.group != b.group) {
            return @cast<i32>(a.group) - @cast<i32>(b.group);
        }
        if (a.order != b.order) {
            return @cast<i32>(a.order - b.order);
        }
        return a.path.as_str().cmp(b.path.as_str());
    });

    var sidebar_pages: std::vec<(std::string, std::string, std::string)> = {};
    for (p&) in pages.items() {
        sidebar_pages.push((copy p.path, copy p.title, copy p.section));
    }
    // every page's HTML, and its content for the search index
    var written: std::vec<(std::string, std::string)> = {};
    var contents: std::vec<std::string> = {};
    for (p&, i) in pages.items() {
        var content: std::string = {};
        var html = fill_page(&th, std_css.as_str(), &sidebar_pages, i, p, &content);
        try write_page(out, p.path.as_str(), html.as_str());
        written.push((copy p.path, move html));
        contents.push(move content);
    }
    written.push((std::string::from(""), try landing(site, out, &th)));
    try std::fs::copy_file(std::format("{}/theme/404.html", site).as_str(), std::format("{}/404.html", out).as_str());
    // the files beside the pages, as links name them
    var files = try copy_assets(std::format("{}/theme/assets", site).as_str(), out);
    try write_sitemap(&th, out, &written);
    try write_search(out, &pages, &contents);
    files.push(std::string::from("404.html"));
    files.push(std::string::from("sitemap-0.xml"));
    files.push(std::string::from("search.json"));
    val broken = check_links(&written, &files);
    if (broken > 0) {
        std::eprintln("{} broken link(s)", broken);
        return site_error::BROKEN_LINKS;
    }
    std::println("{} pages", written.len);
}

// sitemap-0.xml (site/theme/sitemap.xml): every page, in order of URL (sitemap-index.xml, which
// points at it, is an asset)
fn write_sitemap(th: theme&, out: str, pages: std::vec<(std::string, std::string)>&) -> !void {
    var urls: std::vec<std::string> = {};
    for (p&) in pages.items() {
        if (p.0.len() == 0) {
            urls.push(std::string::from(SITE_URL));
        } else {
            urls.push(std::format("{}{}/", SITE_URL, p.0.as_str()));
        }
    }
    urls.items().sort();
    var us = std::json::array();
    for (u&) in urls.items() {
        us.add(std::json::string(u.as_str()));
    }
    var d = std::json::object();
    d.set("urls", move us);
    var xml: std::string = {};
    fill(&th.sitemap, &d, &xml);
    try std::fs::write_file(std::format("{}/sitemap-0.xml", out).as_str(), xml.as_str());
}

// a docs file: its frontmatter and body
fn read_page(docs: str, file: str, section: str) -> !page {
    val text = try std::fs::read_file(file);
    val rel = file[docs.len + 1..file.len];
    var p: page = { path: std::string::from(rel[0..rel.len - 3]), file: std::string::from(rel), section: std::string::from(section), title: {}, description: {}, body: {} };
    var body = text.as_str();
    if (body.starts_with("---\n")) {
        val (front, rest) = body[4..body.len].split_once("\n---\n") ?? ("", body);
        for (l&) in front.lines().items() {
            val (key, value) = l.split_once(":") ?? continue;
            val v = unquote(value.trim());
            if (key == "title") {
                p.title = std::string::from(v);
            } else if (key == "description") {
                p.description = std::string::from(v);
            } else if (key.trim() == "order") {
                p.order = v.parse_int() catch 1000000;
            }
        }
        body = rest;
    }
    p.body = std::string::from(body);
    return p;
}

fn unquote(s: str) -> str {
    if (s.len >= 2 && ((s[0] == '"' && s[s.len - 1] == '"') || (s[0] == '\'' && s[s.len - 1] == '\''))) {
        return s[1..s.len - 1];
    }
    return s;
}

// one docs page: page.html rendered with its values
fn fill_page(th: theme&, std_css: str, all: std::vec<(std::string, std::string, std::string)>&, at: usize, p: page&, content: std::string&) -> std::string {
    var r: rendered = { html: copy p.html, headings: copy p.headings };
    if (!p.reference) {
        r = render_md(p.body.as_str(), th);
    }
    var d = std::json::object();
    d.set("title", std::json::string(p.title.as_str()));
    d.set("description", std::json::string(p.description.as_str()));
    d.set("url", std::json::string(std::format("{}{}/", SITE_URL, p.path.as_str()).as_str()));
    d.set("file", std::json::string(p.file.as_str()));
    d.set("reference", std::json::boolean(p.reference));
    d.set("std_css", std::json::string(std_css));
    d.set("content", std::json::string(r.html.as_str()));
    // the header's section: the path's first directory
    var section = std::json::object();
    section.set(p.section.as_str(), std::json::boolean(true));
    d.set("section", move section);
    // the sidebar: each group's pages, this one current
    var groups = std::json::array();
    for (g&, gi) in GROUPS {
        var ps = std::json::array();
        for (e&, i) in all.items() {
            if (e.2.as_str() == g.0) {
                var x = link(e);
                x.set("current", std::json::boolean(i == at));
                ps.add(move x);
            }
        }
        var gv = std::json::object();
        gv.set("label", std::json::string(g.1));
        gv.set("index", std::json::number(@cast<f64>(gi)));
        gv.set("pages", move ps);
        groups.add(move gv);
    }
    d.set("groups", move groups);
    d.set("toc", toc(&r.headings));
    if (at > 0) {
        d.set("prev", link(all.at(at - 1)));
    }
    if (at + 1 < all.len) {
        d.set("next", link(all.at(at + 1)));
    }
    var html: std::string = {};
    fill(&th.page, &d, &html);
    content.append(r.html.as_str());
    return html;
}

// a page to link to: its path and title
fn link(e: (std::string, std::string, std::string)&) -> std::json::value {
    var x = std::json::object();
    x.set("path", std::json::string(e.0.as_str()));
    x.set("title", std::json::string(e.1.as_str()));
    return x;
}

// the table of contents: Overview (with any h3s before the first h2), then the h2s with their h3s
fn toc(hs: std::vec<heading>&) -> std::json::value {
    var top = std::json::array();
    top.add(toc_item("_top", "Overview"));
    for (h&) in hs.items() {
        if (h.depth == 2) {
            top.add(toc_item(h.id.as_str(), h.text.as_str()));
        } else {
            top.at(top.len() - 1).get("subs").add(toc_item(h.id.as_str(), h.text.as_str()));
        }
    }
    return top;
}

// a heading in the table of contents (its text escaped already)
fn toc_item(id: str, text: str) -> std::json::value {
    var x = std::json::object();
    x.set("id", std::json::string(id));
    x.set("text", std::json::string(text));
    x.set("subs", std::json::array());
    return x;
}

fn write_page(out: str, path: str, html: str) -> !void {
    var dir = std::format("{}/{}", out, path);
    if (path.len == 0) {
        dir = std::string::from(out);
    }
    try std::fs::create_dir_all(dir.as_str());
    try std::fs::write_file(std::format("{}/index.html", dir.as_str()).as_str(), html);
}

// site/theme/assets as it is, into out; the paths it copied
fn copy_assets(from: str, out: str) -> !std::vec<std::string> {
    var copied: std::vec<std::string> = {};
    for (f&) in (try std::fs::walk(from)).items() {
        val rel = f.as_str()[from.len + 1..f.len()];
        val to = std::format("{}/{}", out, rel);
        val slash = to.as_str().rfind("/") ?? 0;
        try std::fs::create_dir_all(to.as_str()[0..slash]);
        try std::fs::copy_file(f.as_str(), to.as_str());
        copied.push(std::string::from(rel));
    }
    return copied;
}

// search.json, for search.js: per page its URL, title and sections (its top, then each h2 and h3:
// their URL, title and text)
fn write_search(out: str, pages: std::vec<page>&, contents: std::vec<std::string>&) -> !void {
    var all = std::json::array();
    for (p&, i) in pages.items() {
        val url = std::format("{}/{}/", BASE, p.path.as_str());
        var sections = std::json::array();
        var title = copy p.title;
        var at = copy url;
        var rest = contents.at(i).as_str();
        loop {
            var next = rest.len;
            val h2 = rest.find("<h2 id=\"");
            if (h2) {
                next = h2;
            }
            val h3 = rest.find("<h3 id=\"") ?? rest.len;
            if (h3 < next) {
                next = h3;
            }
            var text: std::string = {};
            strip_tags(rest[0..next], &text);
            var s = std::json::object();
            s.set("u", std::json::string(at.as_str()));
            s.set("t", std::json::string(title.as_str()));
            s.set("x", std::json::string(text.as_str().trim()));
            sections.add(move s);
            if (next == rest.len) {
                break;
            }
            // the heading: its id and text
            val h = rest[next + 8..rest.len];
            val (id, after) = h.split_once("\"") ?? break;
            val gt = after.find(">") ?? 0;
            val (inner, more) = after[gt + 1..after.len].split_once("</h") ?? break;
            at = std::format("{}#{}", url.as_str(), id);
            var t: std::string = {};
            strip_tags(inner, &t);
            title = std::string::from(t.as_str().trim());
            rest = more[(more.find(">") ?? 0) + 1..more.len];
        }
        var entry = std::json::object();
        entry.set("u", std::json::string(url.as_str()));
        entry.set("t", std::json::string(p.title.as_str()));
        entry.set("s", move sections);
        all.add(move entry);
    }
    try std::fs::write_file(std::format("{}/search.json", out).as_str(), all.text().as_str());
}

// HTML's text: tags dropped (and what's in one marked data-pagefind-ignore), entities decoded,
// white space as single spaces, a space at the end of a block
fn strip_tags(s: str, out: std::string&) -> void {
    val blocks: str[12] = { "</p", "</li", "</td", "</th", "</div", "</h", "</pre", "<br", "</tr", "</figcaption", "</blockquote", "</dd" };
    var i: usize = 0;
    while (i < s.len) {
        val c = s[i];
        if (c == '<') {
            val end = s[i..s.len].find(">") ?? (s.len - i - 1);
            val tag = s[i..i + end + 1];
            i += end + 1;
            if (tag.contains("data-pagefind-ignore")) {
                i += s[i..s.len].find("<") ?? (s.len - i);
            }
            for (b) in blocks {
                if (tag.starts_with(b)) {
                    space(out);
                }
            }
            continue;
        }
        if (c == ' ' || c == '\n' || c == '\t') {
            space(out);
            i += 1;
            continue;
        }
        if (c == '&') {
            val semi = s[i..s.len].find(";") ?? 0;
            if (semi > 0 && semi < 10) {
                val ch = decode_entity(s[i + 1..i + semi]);
                if (ch) {
                    out.push(ch);
                    i += semi + 1;
                    continue;
                }
            }
        }
        out.push(c);
        i += 1;
    }
}

fn space(out: std::string&) -> void {
    val t = out.as_str();
    if (t.len > 0 && t[t.len - 1] != ' ') {
        out.push(' ');
    }
}

// an entity's character: the named ones the generator writes, or &#N; &#xN; below 128
fn decode_entity(e: str) -> u8? {
    val named: (str, u8)[6] = { ("lt", '<'), ("gt", '>'), ("amp", '&'), ("quot", '"'), ("apos", '\''), ("nbsp", ' ') };
    for (n&) in named {
        if (e == n.0) {
            return n.1;
        }
    }
    if (e.len < 2 || e[0] != '#') {
        return null;
    }
    var v: u32 = 0;
    val hex = e[1] == 'x' || e[1] == 'X';
    var start: usize = 1;
    var radix: u32 = 10;
    if (hex) {
        start = 2;
        radix = 16;
    }
    for (c) in e[start..e.len] {
        var d: u32 = 0;
        if (c >= '0' && c <= '9') {
            d = c - '0';
        } else if (hex && c >= 'a' && c <= 'f') {
            d = c - 'a' + 10;
        } else if (hex && c >= 'A' && c <= 'F') {
            d = c - 'A' + 10;
        } else {
            return null;
        }
        v = v * radix + d;
        if (v >= 128) {
            return null;
        }
    }
    return @cast<u8>(v);
}

// every href and src on the pages: a page under BASE (and an id on it, after a #), a file this
// build wrote there (not whatever an earlier one left in the output directory), or somewhere else
// (http, mailto); prints each that isn't, and returns how many
fn check_links(pages: std::vec<(std::string, std::string)>&, files: std::vec<std::string>&) -> usize {
    var broken: usize = 0;
    val attrs: str[2] = { "href=\"", "src=\"" };
    for (p&) in pages.items() {
        for (a) in attrs {
            var rest = p.1.as_str();
            loop {
                val (_, after) = rest.split_once(a) ?? break;
                val (link, more) = after.split_once("\"") ?? break;
                rest = more;
                if (!link_ok(pages, files, p.1.as_str(), link)) {
                    std::eprintln("/{}: broken link {}", p.0.as_str(), link);
                    broken += 1;
                }
            }
        }
    }
    return broken;
}

fn link_ok(pages: std::vec<(std::string, std::string)>&, files: std::vec<std::string>&, here: str, link: str) -> bool {
    if (link.starts_with("https://") || link.starts_with("http://") || link.starts_with("mailto:") || link == "#") {
        return true;
    }
    if (link.starts_with("#")) {
        return has_id(here, link[1..link.len]);
    }
    val under = link.strip_prefix(BASE) ?? return false;
    val rel = under.strip_prefix("/") ?? return false;
    var path = rel;
    var frag = "";
    val hash = rel.find("#");
    if (hash) {
        path = rel[0..hash];
        frag = rel[hash + 1..rel.len];
    }
    // a page: its directory, with the slash
    if (path.len == 0 || path.ends_with("/")) {
        val dir = path.strip_suffix("/") ?? path;
        for (p&) in pages.items() {
            if (p.0.as_str() == dir) {
                return frag.len == 0 || has_id(p.1.as_str(), frag);
            }
        }
        return false;
    }
    if (frag.len > 0) {
        return false;
    }
    for (f&) in files.items() {
        if (f.as_str() == path) {
            return true;
        }
    }
    return false;
}

fn has_id(html: str, id: str) -> bool {
    return html.contains(std::format("id=\"{}\"", id).as_str());
}
