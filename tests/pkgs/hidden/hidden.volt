// A package with internal items, for tests/fail/internal_comptime.volt and tests/run/internal_ok.volt.

internal val LIMIT: i32 = 3;

internal comptime fn twice(n: i32) -> i32 {
    return n * 2;
}

// public, and uses the internal items: fine inside the package, at compile time and at run time
comptime fn limit() -> i32 {
    return twice(LIMIT);
}

fn doubled() -> i32 {
    return twice(LIMIT);
}

internal enum mode {
    FAST,
    SAFE,
}

fn default_mode() -> i32 {
    val m = mode::SAFE;
    return 1;
}

internal trait secret {
    fn code(this) -> i32;
}
