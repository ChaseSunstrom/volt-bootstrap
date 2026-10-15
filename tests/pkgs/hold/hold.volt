// a global whose type holds a trait union: its layout depends on the types the program attaches to
// hook, so a program never takes this package from its prebuilt library (packages_linked.volt
// links libhold.a, and voltc builds hold from source and says why)
public trait hook {
    fn fire(this, x: i32) -> i32;
}

public struct holder {
    h: hook?;
    n: i32;
}

public fn twice(x: i32) -> i32 {
    return x * 2;
}

// an untyped fn value before held: working out its type reaches twice while hold is still linked
public val cb = twice;

// untyped and before held: working out its type reaches held first, before hold is known to be built
// from source
public var spare = held;

public var held: holder = { h: null, n: 1 };

// no trait union in its signature, but its body reads held
public fn fire_held() -> i32 {
    val h = held.h ?? return held.n;
    return h.fire(held.n);
}
