// flags: --leak-check
use std::io;
use std::html;
use std::string;
// std::html::render: a template checked against a type while compiling (slots, raw slots, loops over
// a std::vec and nested ones, a loop's variable beside the data's fields, if/else, an optional used
// inside an {{if}} on it), then rendered from a value of that type

@attributes([@derive(json)])
struct link {
    title: str;
    path: std::string;
}

@attributes([@derive(json)])
struct group {
    label: str;
    pages: std::vec<link>;
}

@attributes([@derive(json)])
struct page {
    title: str;
    body: str;
    count: i64;
    ratio: f64;
    draft: bool;
    groups: std::vec<group>;
    next: link?;
}

// the template (a file would be @embed("page.html"))
comptime fn page_src() -> str {
    return "<h1>{{title}}</h1>{{{body}}}\n{{for g in groups}}<h2>{{g.label}} of {{title}}</h2>{{for p in g.pages}}<a href=\"{{p.path}}\">{{p.title}}</a>{{end}}{{end}}\n{{if draft}}draft{{else}}live{{end}} {{count}} {{ratio}}\n{{if next}}next: {{next.title}}{{else}}last{{end}}";
}

fn main() -> void {
    var p: page = { title: "Fish & Chips", body: "<b>hot</b>", count: 3, ratio: 0.5, draft: false, groups: {}, next: null };
    var g: group = { label: "Guide", pages: {} };
    g.pages.push({ title: "Start", path: std::string::from("/start/") });
    g.pages.push({ title: "<Types>", path: std::string::from("/types/") });
    p.groups.push(move g);
    var out: std::string = {};
    std::html::render(page_src(), &p, &out);
    std::println("{}", out.as_str());
    p.next = { title: "End", path: std::string::from("/end/") };
    var again: std::string = {};
    std::html::render(page_src(), &p, &again);
    std::println("{}", again.as_str()[again.len() - 9..]);
}
// expect: <h1>Fish &amp; Chips</h1><b>hot</b>
// expect: <h2>Guide of Fish &amp; Chips</h2><a href="/start/">Start</a><a href="/types/">&lt;Types&gt;</a>
// expect: live 3 0.5
// expect: last
// expect: next: End
