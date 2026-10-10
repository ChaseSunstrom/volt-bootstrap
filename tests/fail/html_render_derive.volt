use std::html;
struct page { title: str; }
fn main() -> void { var out: std::string = {}; val p: page = { title: "t" }; std::html::render("{{title}}", &p, &out); }
// error: std::html::render: page needs @attributes([@derive(json)])
