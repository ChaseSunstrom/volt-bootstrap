// A package's API is what it marks public; the rest is its own (tests/run/vis_public.volt and
// tests/fail/vis_unmarked.volt).

public fn answer() -> i32 {
    return helper() + 1;
}

fn helper() -> i32 {
    return 41;
}

public val LIMIT: i32 = 3;
val HIDDEN: i32 = 4;

// fields follow their struct
public struct point {
    x: i32;
    y: i32;
}

public attach fn sum(this: point&) -> i32 {
    return this.x + this.y + this.bonus();
}

attach fn bonus(this: point&) -> i32 {
    return 0;
}

// a trait's functions in an attach block follow the trait
public trait shape {
    fn area(this) -> i32;
}

public struct square {
    side: i32;
}

attach shape -> square {
    fn area(this) -> i32 { return this.side * this.side; }
}

// export fn: a C symbol, so public
export fn vis_seven() -> i32 {
    return 7;
}
