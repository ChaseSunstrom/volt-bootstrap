// uses hold: its library, built against libhold.a, refers to hold's symbols, so a program that builds
// hold from source builds geo2 from source too (packages_linked.volt)
public fn held_plus(x: i32) -> i32 {
    return hold::fire_held() + x;
}
