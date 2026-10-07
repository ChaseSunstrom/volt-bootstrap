use std::io;
use std::string;
// generic Rust fns, made for each set of types the program calls them with
use { "geom" } as geom;

fn main() -> void {
    val xs: i32[3] = { 3, 9, 4 };
    val ys: f64[2] = { 1.5, 0.5 };
    std::println("largest {} {}", geom::largest(xs[..]), geom::largest(ys[..]));
    val r = geom::repeat(7, 3);
    val h = geom::repeat<f64>(0.5, 2);
    std::println("repeat {} {} {}", r.len, *r.at(2), *h.at(1));
    std::println("pick {} {}", geom::pick(false, "a", "b"), geom::pick(true, 1, 2));
    val p = geom::Point::new(1.0, 2.0);
    val q = p.scaled_by(@cast<i32>(3));
    std::println("scaled {} {}", q.x, q.y);
    var st = geom::Stack<i32>::new();
    st.push(4);
    st.push(5);
    var names = geom::Stack<std::string>::new();
    names.push("volt");
    std::println("stack {} {} {}", st.len(), st.top() ?? 0, names.top() ?? std::string::from("none"));
}
