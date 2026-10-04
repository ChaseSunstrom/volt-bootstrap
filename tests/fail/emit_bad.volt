// an error in emitted code points into the generated source
comptime fn broken() -> str {
    return quote {
        fn f() -> i32 {
            return "not a number";
        }
    };
}

@emit(broken());

fn main() -> void {
    val x = f();
}
// error: <emit at emit_bad.volt:10>
