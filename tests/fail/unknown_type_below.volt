// an unknown type whose name is exactly a type's below (std::string): that path; a function of the
// name (println) isn't offered for a type
fn main() -> void {
    val s: string = {};
}
// error: unknown type 'string'
// error: did you mean 'std::string'?
