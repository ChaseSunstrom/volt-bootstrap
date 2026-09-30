error oops { BAD }
fn takes(r: oops!(i32&)) -> void {}
fn main() -> void {
    var x: oops!i32 = 1;
    takes(&x);
}
// error: argument 1 is a oops!i32&, but 'takes' wants a oops!(i32&)
