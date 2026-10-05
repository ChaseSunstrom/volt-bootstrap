// The site's generator: the docs (site/src/content/docs, Markdown), the std reference
// (site/src/data/std.json) and the landing page into site/dist, with Starlight's look: its page
// markup (site/theme/page.html, cut from a Starlight build, with {{slots}}), the pieces it repeats
// (site/theme/parts.html) and its built CSS and scripts (site/theme/assets). From the repository:
//   voltc run site/gen/*.volt -- [SITE_DIR [OUT_DIR]]
use std::io;
use std::fmt;
use std::fs;

val BASE: str = "/volt-bootstrap";
val SITE_URL: str = "https://chasesunstrom.github.io/volt-bootstrap/";
val EDIT_URL: str = "https://github.com/ChaseSunstrom/volt-bootstrap/edit/main/site/src/content/docs/";

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

// the named pieces in parts.html
struct parts {
    names: std::vec<std::string>;
    texts: std::vec<std::string>;
}

attach fn get(this: parts&, name: str) -> str {
    for (n&, i) in this.names.items() {
        if (n.as_str() == name) {
            return this.texts.at(i).as_str();
        }
    }
    @panic("no such part");
}

fn load_parts(text: str) -> parts {
    var p: parts = { names: {}, texts: {} };
    var rest = text;
    loop {
        val (_, after) = rest.split_once("<!-- part: ") ?? break;
        val (name, body) = after.split_once(" -->\n") ?? break;
        var end = body.len;
        val next = body.find("<!-- part: ");
        if (next) {
            end = next;
        }
        p.names.push(std::string::from(name));
        p.texts.push(std::string::from(body[0..end].trim_end()));
        rest = body[end..body.len];
    }
    return p;
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

// the header's sections: label, link and the path that makes it current
val SECTIONS: (str, str, str)[5] = {
    ("Learn", "start/install", "/start/"),
    ("Guide", "guide/basics", "/guide/"),
    ("std", "std/overview", "/std/"),
    ("bolt", "bolt/overview", "/bolt/"),
    ("Interop", "interop/c", "/interop/"),
};

error site_error {
    BROKEN_LINKS,
}

fn main() -> !void {
    val site = std::process::arg(1) ?? "site";
    val out = std::process::arg(2) ?? "site/dist";
    val docs = std::format("{}/src/content/docs", site);
    val tmpl = try std::fs::read_file(std::format("{}/theme/page.html", site).as_str());
    val part_text = try std::fs::read_file(std::format("{}/theme/parts.html", site).as_str());
    val parts = load_parts(part_text.as_str());
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
    try std_pages(site, 2, &pages);
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
        var html = fill_page(tmpl.as_str(), std_css.as_str(), &parts, &sidebar_pages, i, p, &content);
        try write_page(out, p.path.as_str(), html.as_str());
        written.push((copy p.path, move html));
        contents.push(move content);
    }
    written.push((std::string::from(""), try landing(site, out)));
    try std::fs::copy_file(std::format("{}/theme/404.html", site).as_str(), std::format("{}/404.html", out).as_str());
    // the files beside the pages, as links name them
    var files = try copy_assets(std::format("{}/theme/assets", site).as_str(), out);
    try write_sitemap(out, &written);
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

// sitemap-0.xml: every page, in order of URL (sitemap-index.xml, which points at it, is an asset)
fn write_sitemap(out: str, pages: std::vec<(std::string, std::string)>&) -> !void {
    var urls: std::vec<std::string> = {};
    for (p&) in pages.items() {
        if (p.0.len() == 0) {
            urls.push(std::string::from(SITE_URL));
        } else {
            urls.push(std::format("{}{}/", SITE_URL, p.0.as_str()));
        }
    }
    urls.items().sort();
    var xml = std::string::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?><urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\" xmlns:news=\"http://www.google.com/schemas/sitemap-news/0.9\" xmlns:xhtml=\"http://www.w3.org/1999/xhtml\" xmlns:image=\"http://www.google.com/schemas/sitemap-image/1.1\" xmlns:video=\"http://www.google.com/schemas/sitemap-video/1.1\">");
    for (u&) in urls.items() {
        std::write(&xml, "<url><loc>{}</loc></url>", u.as_str());
    }
    xml.append("</urlset>");
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

// one docs page: the template with its slots filled
fn fill_page(tmpl: str, std_css: str, parts: parts&, all: std::vec<(std::string, std::string, std::string)>&, at: usize, p: page&, content: std::string&) -> std::string {
    var r: rendered = { html: copy p.html, headings: copy p.headings };
    if (!p.reference) {
        r = render_md(p.body.as_str(), parts);
    }
    var html: std::string = {};
    var rest = tmpl;
    loop {
        val (before, after) = rest.split_once("{{") ?? break;
        val (slot, more) = after.split_once("}}") ?? break;
        html.append(before);
        if (slot == "title") {
            attr(p.title.as_str(), &html);
        } else if (slot == "description") {
            attr(p.description.as_str(), &html);
        } else if (slot == "url") {
            std::write(&html, "{}{}/", SITE_URL, p.path.as_str());
        } else if (slot == "h1") {
            html.append("<h1 id=\"_top\" class=\"astro-bebwqqxs\">");
            escape(p.title.as_str(), &html);
            html.append("</h1>");
        } else if (slot == "nav") {
            nav(p.path.as_str(), &html);
        } else if (slot == "sidebar") {
            sidebar(all, at, parts, &html);
        } else if (slot == "toc") {
            toc(&r.headings, "", &html);
        } else if (slot == "toc_mobile") {
            toc(&r.headings, "isMobile ", &html);
        } else if (slot == "content") {
            html.append(r.html.as_str());
            content.append(r.html.as_str());
        } else if (slot == "footer") {
            footer(all, at, p.file.as_str(), parts, &html);
        } else if (slot == "head_extra") {
            // the std reference pages' styles
            if (p.reference) {
                std::write(&html, "<style>{}</style>", std_css);
            }
        }
        rest = more;
    }
    html.append(rest);
    return html;
}

// text for an attribute value: & and " escaped
fn attr(s: str, out: std::string&) -> void {
    for (i) in 0..s.len {
        if (s[i] == '"') {
            out.append("&quot;");
        } else if (s[i] == '&') {
            out.append("&amp;");
        } else {
            out.push(s[i]);
        }
    }
}

fn nav(path: str, out: std::string&) -> void {
    out.append("<nav class=\"v-links astro-nen7h5rs\" aria-label=\"Sections\">");
    val here = std::format("{}/{}/", BASE, path);
    for (s&) in SECTIONS {
        std::write(out, "<a href=\"{}/{}/\"", BASE, s.1);
        if (here.as_str().contains(s.2)) {
            out.append(" aria-current=\"true\"");
        }
        std::write(out, " class=\"astro-nen7h5rs\">{}</a>", s.0);
    }
    out.append("</nav>");
}

fn sidebar(all: std::vec<(std::string, std::string, std::string)>&, at: usize, parts: parts&, out: std::string&) -> void {
    out.append("<ul class=\"top-level astro-rmhv4bp6\">");
    for (g&, gi) in GROUPS {
        std::write(out, "<li class=\"astro-rmhv4bp6\"><details open class=\"astro-rmhv4bp6\"><summary class=\"astro-rmhv4bp6\"><span class=\"group-label astro-rmhv4bp6\"><span class=\"large astro-rmhv4bp6\">{}</span></span>{}</summary><sl-sidebar-restore data-index=\"{}\"></sl-sidebar-restore><ul class=\"astro-rmhv4bp6\">", g.1, parts.get("caret"), gi);
        for (e&, i) in all.items() {
            if (e.2.as_str() != g.0) {
                continue;
            }
            std::write(out, "<li class=\"astro-rmhv4bp6\"><a href=\"{}/{}/\"", BASE, e.0.as_str());
            if (i == at) {
                out.append(" aria-current=\"page\"");
            }
            out.append(" class=\"astro-rmhv4bp6\"><span class=\"astro-rmhv4bp6\">");
            escape(e.1.as_str(), out);
            out.append("</span></a></li>");
        }
        out.append("</ul></details></li>");
    }
    out.append("</ul>");
}

// the table of contents: Overview, then the h2s with their h3s inside
fn toc(hs: std::vec<heading>&, mobile: str, out: std::string&) -> void {
    std::write(out, "<ul class=\"{}astro-jugkfwgx\" style=\"--depth: 0;\">", mobile);
    toc_item("_top", "Overview", 0, out);
    out.append("</li>");
    var open_sub = false;
    for (h&, i) in hs.items() {
        if (h.depth == 2) {
            if (open_sub) {
                out.append("</ul>");
                open_sub = false;
            }
            if (i > 0) {
                out.append("</li>");
            }
            toc_item(h.id.as_str(), h.text.as_str(), 0, out);
        } else {
            if (!open_sub) {
                std::write(out, "<ul class=\"{}astro-jugkfwgx\" style=\"--depth: 1;\">", mobile);
                open_sub = true;
            }
            toc_item(h.id.as_str(), h.text.as_str(), 1, out);
            out.append("</li>");
        }
    }
    if (open_sub) {
        out.append("</ul>");
    }
    if (hs.len > 0) {
        out.append("</li>");
    }
    out.append("</ul>");
}

// an item's <li> and link, left open for its sub-list
fn toc_item(id: str, text: str, depth: u32, out: std::string&) -> void {
    std::write(out, "<li style=\"--depth: {};\" class=\"astro-jugkfwgx\"><a href=\"#{}\" style=\"--depth: {};\" class=\"astro-jugkfwgx\"><span style=\"--depth: {};\" class=\"astro-jugkfwgx\">{}</span></a>", depth, id, depth, depth, text);
}

fn footer(all: std::vec<(std::string, std::string, std::string)>&, at: usize, file: str, parts: parts&, out: std::string&) -> void {
    out.append("<footer class=\"sl-flex astro-ddtxxk7k\"><div class=\"meta sl-flex astro-ddtxxk7k\">");
    if (file.len > 0) {
        std::write(out, "<a href=\"{}{}\" class=\"sl-flex print:hidden astro-qlekgd3o\">{}Edit page</a>", EDIT_URL, file, parts.get("edit"));
    }
    out.append("</div><div class=\"pagination-links print:hidden astro-b5raizh3\" dir=\"ltr\">");
    if (at > 0) {
        val e = all.at(at - 1);
        std::write(out, "<a href=\"{}/{}/\" rel=\"prev\" class=\"astro-b5raizh3\">{}<span class=\"astro-b5raizh3\">Previous<br class=\"astro-b5raizh3\"><span class=\"link-title astro-b5raizh3\">", BASE, e.0.as_str(), parts.get("prev"));
        escape(e.1.as_str(), out);
        out.append("</span></span></a>");
    }
    if (at + 1 < all.len) {
        val e = all.at(at + 1);
        std::write(out, "<a href=\"{}/{}/\" rel=\"next\" class=\"astro-b5raizh3\">{}<span class=\"astro-b5raizh3\">Next<br class=\"astro-b5raizh3\"><span class=\"link-title astro-b5raizh3\">", BASE, e.0.as_str(), parts.get("next"));
        escape(e.1.as_str(), out);
        out.append("</span></span></a>");
    }
    out.append("</div></footer>");
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
