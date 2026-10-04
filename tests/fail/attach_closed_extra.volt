@attributes([@closed])
trait widget_methods {
    fn width(this) -> i32;
}

@attributes([@attach_as("widget_methods")])
struct widget {
    id: i32;
}

struct plain {
    w: i32;
}

attach widget -> plain {
    fn width(this) -> i32 { return this.w; }
    fn widht(this) -> i32 { return 0; }
}

fn main() -> void {}
// error: 'widht' isn't one of widget's functions
