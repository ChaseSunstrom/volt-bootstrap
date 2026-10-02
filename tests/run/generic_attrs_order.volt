// attributes and generic parameters in either order (T-0173)
use std::io;

<T: type>
@attributes([@noinline])
fn twice(x: T) -> T {
    return x + x;
}

@attributes([@noinline])
<T: type>
fn thrice(x: T) -> T {
    return x + x + x;
}

fn main() -> void {
    std::println("{} {}", twice<i32>(4), thrice<i32>(2));
    std::println("{} {}", twice(1.5), thrice(1.5));
}
// expect: 8 6
// expect: 3 4.5
