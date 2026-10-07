// @instance names an instance of a generic export fn; anywhere else it's an error
@attributes([@instance(i32)])
export fn twice(x: i32) -> i32 {
    return x * 2;
}

fn main() -> void {}
// error: @instance goes on a generic export fn
