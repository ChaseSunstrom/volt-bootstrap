// @field_default(T, "name") is what a literal that leaves the field out gives it; @typeinfo's
// default_expr is the default as written
use std::io;

struct opts {
    width: i64 = 40 * 2;
    title: std::string = std::string::from("untitled");
    tag: str?;
    id: u32;
}

fn main() -> void {
    std::println("{} {} {}", @field_default(opts, "width"), @field_default(opts, "title").as_str(), @field_default(opts, "tag"));
    comptime for (f) in @typeinfo(opts).fields {
        std::println("{} {}", f.name, f.default_expr ?? "none");
    }
}
// expect: 80 untitled null
// expect: width 40 * 2
// expect: title std::string::from("untitled")
// expect: tag none
// expect: id none
