// a package that picks code per platform: the target keys reach every package, with no --cfg
fn target_os() -> str {
    comptime if (@cfg("os", "linux")) {
        return "linux";
    }
    comptime if (@cfg("os", "macos")) {
        return "macos";
    }
    return "elsewhere";
}

// the keys alone (any value) and the one this package was built for, as text
fn keys_set() -> bool {
    return @cfg("os") && @cfg("arch") && @cfg("pointer_bits");
}

fn built_for() -> str {
    comptime if (@cfg("os", "windows")) {
        return "windows";
    }
    comptime if (@cfg("os", "linux")) {
        return "linux";
    }
    return "other";
}
