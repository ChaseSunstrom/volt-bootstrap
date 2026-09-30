<T: type> fn z() -> T { return 0; }
fn main() -> void { val a = z(); }
// error: can't infer 'T'
