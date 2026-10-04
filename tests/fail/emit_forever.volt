// code that emits itself stops with an error, not a hang
comptime fn again() -> str {
    return "@emit(again());";
}

@emit(again());

fn main() -> void {}
// error: @emit expands without end
