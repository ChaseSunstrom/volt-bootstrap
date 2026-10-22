// a lone name that isn't in scope but is, exactly, in a namespace (std::io): the help names its path
fn main() -> void {
    println("x");
}
// error: unknown name 'println'
// error: did you mean 'std::io::println'?
