use std::html;
@attributes([@derive(json)])
struct page { title: str; }
fn main() -> void { var out: std::string = {}; val p: page = { title: "t" }; std::html::render("<h1>\n{{titel}}</h1>", &p, &out); }
// error: line 2: {{titel}}: page has no field titel
