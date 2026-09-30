// an argument of the wrong type: the parameter is labelled where it's declared
error oops { BAD }

fn takes(r: oops!(i32&)) -> void {}

fn main() -> void {
    var x: oops!i32 = 1;
    takes(&x);
}
