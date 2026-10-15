// a trait nothing in the package attaches, used as a type: voltc lib builds it (a type with no
// values there), and fns with a trait union in their signature are built in each program, never
// taken from the library (fn_linkage), so a program that attaches the trait (packages_linked.volt)
// calls them with values
public trait plugin {
    fn run(this, x: i32) -> i32;
}

public struct slot {
    p: plugin?;
    n: i32;
}

public fn run_plugin(p: plugin&, x: i32) -> i32 {
    return p.run(x) + 1;
}

public fn slot_total(s: slot&) -> i32 {
    val p = s.p ?? return s.n;
    return p.run(s.n);
}
