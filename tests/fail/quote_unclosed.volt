// a quote whose { never closes
fn main() -> void {}
// error: this quote's { is never closed
@emit(quote { fn g() -> void {
