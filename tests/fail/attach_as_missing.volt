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

attach widget -> plain {
    fn label(this) -> str { return "x"; }
}

fn main() -> void {}
// error: missing fn 'width', which 'widget' requires
