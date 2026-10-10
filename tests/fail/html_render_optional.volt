use std::html;
@attributes([@derive(json)])
struct link { title: str; }
@attributes([@derive(json)])
struct page { next: link?; }
fn main() -> void { var out: std::string = {}; val p: page = { next: null }; std::html::render("{{if next}}ok{{end}} {{next.title}}", &p, &out); }
// error: line 1: {{next.title}}: next can be null: use it inside {{if next}}
