// a type alias whose comptime fn fails: Name::member reports that failure, not an unknown name

comptime fn codes(names: str[]) -> type {
    if (names.len == 0) {
        @compile_error("codes needs at least one name");
    }
    return enum {
        comptime for (n) in names {
            (n),
        }
    };
}

type status = codes({});

fn main() -> void {
    val s = status::parse("OK");
}
// error: codes needs at least one name
