@attributes([@closed])
trait widget_methods {
    fn width(this, self: widget&) -> i32;
}

@attributes([@attach_as("widget_methods")])
struct widget {
    id: i32;
}

struct button {
    id: i32;
}

struct plain {
    w: i32;
}

attach widget -> plain {
    fn width(this, self: button&) -> i32 { return this.w; }
}

fn main() -> void {}
// error: 'width' takes a button& as argument 1 here but a widget& in 'widget'
