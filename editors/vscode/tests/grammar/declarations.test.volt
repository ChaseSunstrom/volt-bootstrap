// SYNTAX TEST "source.volt" "declarations"
use std::io;
// <--- keyword.other.volt
//  ^^^ entity.name.namespace.volt

struct point {
// <------ storage.type.volt
//     ^^^^^ entity.name.type.volt
    x: i32;
//     ^^^ support.type.primitive.volt
}

error parse_error { EMPTY, BAD_DIGIT }
// <----- storage.type.volt
//    ^^^^^^^^^^^ entity.name.type.volt
//                  ^^^^^ constant.other.caps.volt

attach fn sum(this: point&) -> i32 {
// <------ keyword.other.volt
//     ^^ storage.type.function.volt
//        ^^^ entity.name.function.volt
//            ^^^^ variable.language.this.volt
//                          ^^ keyword.operator.volt
    return this.x + this.y;
//  ^^^^^^ keyword.control.volt
}

<T: type>
//  ^^^^ support.type.primitive.volt
fn max(a: T, b: T) -> T {
    if (a > b) {
//  ^^ keyword.control.volt
        return a;
    }
    return b;
}

extern "C" fn puts(s: cstr) -> i32;
// <------ storage.modifier.volt
//     ^^^ string.quoted.double.volt
//                    ^^^^ support.type.primitive.volt

namespace geometry::shapes {
// <--------- storage.type.volt
//        ^^^^^^^^ entity.name.namespace.volt
}
