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

// under --cfg os=windows (tests/diag/cfg_target_override), the package sees it too
fn windows_check() -> void {
    comptime if (@cfg("os", "windows")) {
        @compile_error("the package sees windows");
    }
}
