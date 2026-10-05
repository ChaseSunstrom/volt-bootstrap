// std::testing: assertions that say what failed, and a runner for a file of tests. An assertion
// that fails prints both values to stderr and returns FAILED, so `try` ends the test there.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace testing {
    public error test_error {
        FAILED, // an assertion failed (what and why are on stderr)
    }

    // fails unless ok
    public fn assert(ok: bool, what: str = "") -> test_error!void {
        if (ok) {
            return;
        }
        if (what.len == 0) {
            std::io::eprintln("assertion failed");
        } else {
            std::io::eprintln("assertion failed: {}", what);
        }
        return test_error::FAILED;
    }

    // fails unless left equals right (by eq, so a type's own eq counts). Both are taken by value, so
    // an owned value (a std::string) moves in: pass `copy s`, or compare s.as_str()
    <T: type>
    public fn assert_eq(left: T, right: T, what: str = "") -> test_error!void {
        if (left.eq(&right)) {
            return;
        }
        if (what.len == 0) {
            std::io::eprintln("assertion failed: left == right");
        } else {
            std::io::eprintln("assertion failed: {}", what);
        }
        std::io::eprintln("  left:  {}", left);
        std::io::eprintln("  right: {}", right);
        return test_error::FAILED;
    }

    // fails if left equals right
    <T: type>
    public fn assert_ne(left: T, right: T, what: str = "") -> test_error!void {
        if (!left.eq(&right)) {
            return;
        }
        if (what.len == 0) {
            std::io::eprintln("assertion failed: left != right");
        } else {
            std::io::eprintln("assertion failed: {}: left != right", what);
        }
        std::io::eprintln("  both:  {}", left);
        return test_error::FAILED;
    }

    // fails unless left and right are at most tolerance (0 or more) apart. Equal infinities are near;
    // NaN is never near anything
    public fn assert_near(left: f64, right: f64, tolerance: f64, what: str = "") -> test_error!void {
        if (left == right) {
            return;
        }
        val gap = left - right;
        if (gap <= tolerance && -gap <= tolerance) {
            return;
        }
        if (what.len == 0) {
            std::io::eprintln("assertion failed: left and right are further apart than {}", tolerance);
        } else {
            std::io::eprintln("assertion failed: {}: further apart than {}", what, tolerance);
        }
        std::io::eprintln("  left:  {}", left);
        std::io::eprintln("  right: {}", right);
        return test_error::FAILED;
    }

    // one test: a name and a body that fails by returning an error
    public struct test {
        name: str;
        body: fn() -> !void;
    }

    // runs every test, even after one fails, printing `test NAME ... ok` or `... FAILED` for each
    // and a count at the end. Returns the exit code: 0 when all passed, 1 otherwise
    public fn run(tests: test[..]) -> i32 {
        var failed: usize = 0;
        for (t) in tests {
            val body = t.body;
            body() catch |e| {
                failed += 1;
                if (e == test_error::FAILED) {
                    std::io::println("test {} ... FAILED", t.name);
                } else {
                    std::io::println("test {} ... FAILED ({})", t.name, e);
                }
                continue;
            };
            std::io::println("test {} ... ok", t.name);
        }
        std::io::println("{} passed, {} failed", tests.len - failed, failed);
        if (failed > 0) {
            return 1;
        }
        return 0;
    }
}
