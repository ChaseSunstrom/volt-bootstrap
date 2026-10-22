// a type named like a function below (std::io::println): no path to the function for a type
fn main() -> void {
    val s: println = {};
}
// error: unknown type 'println'
// reject-stderr: std::io::println
