use std::html;
@attributes([@derive(json)])
struct page { title: str; }
fn main() -> void { var out: std::string = {}; val p: page = { title: "t" }; std::html::render("{{for c in title}}{{c}}{{end}}", &p, &out); }
// error: line 1: {{for c in title}}: a loop goes over a std::vec, not str
