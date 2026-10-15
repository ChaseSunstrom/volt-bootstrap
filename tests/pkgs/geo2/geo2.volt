// uses hold: its library, built against libhold.a, refers to hold's symbols, so a program that builds
// hold from source builds geo2 from source too (packages_linked.volt). Its one use of hold hides
// behind a "//" in a string on the same line and a line break before the ::, which voltc still sees
public fn held_plus(x: i32) -> i32 {
    val u = "http://x"; return hold
        ::fire_held() + x + @cast<i32>(u.len) - 8;
}
