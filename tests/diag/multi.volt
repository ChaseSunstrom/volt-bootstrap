// independent errors in different functions are all reported, in source order
fn a() -> i32 {
    return "not a number";
}

fn b() -> void {
    undefined_thing();
}

fn main() -> void {
    val t = true + 1;
}
