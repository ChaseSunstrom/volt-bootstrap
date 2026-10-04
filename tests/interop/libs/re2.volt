// re2, as installed (re2/re2.h on the include path; link with -lre2): its RE2 class
use std::io;
use cpp { "re2/re2.h" } as cpp;

fn main() -> void {
    val r = cpp::re2::RE2::new("a(b+)c");
    std::println("{} {} {}", r.ok(), r.pattern(), r.NumberOfCapturingGroups());
    val bad = cpp::re2::RE2::new("a(b");
    std::println("{}", bad.ok());
}
