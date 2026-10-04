// A struct can stand for a trait in attach blocks: @attach_as("trait") (how a C++ class's virtual
// methods are overridden). A trait's @optional fns may be left out of a block, a @closed trait's
// blocks hold its fns only, and @has_method(T, "name") says which ones a type has
use std::io;

@attributes([@closed])
trait widget_methods {
    fn width(this) -> i32;
    @attributes([@optional])
    fn label(this) -> str;
}

@attributes([@attach_as("widget_methods")])
struct widget {
    id: i32;
}

struct plain {
    w: i32;
}

struct fancy {
    w: i32;
}

attach widget -> plain {
    fn width(this) -> i32 { return this.w; }
}

attach widget -> fancy {
    fn width(this) -> i32 { return this.w * 2; }
    fn label(this) -> str { return "fancy"; }
}

<T: widget>
fn show(v: T&) -> void {
    comptime if (@has_method(T, "label")) {
        std::println("{} {}", v.label(), v.width());
    } else {
        std::println("(no label) {}", v.width());
    }
}

fn main() -> void {
    val p: plain = { w: 3 };
    val f: fancy = { w: 4 };
    show(&p);
    show(&f);
    std::println("{} {} {}", @attaches(plain, widget), @has_method(fancy, "width"), @has_method(plain, "label"));
}
// expect: (no label) 3
// expect: fancy 8
// expect: true true false
