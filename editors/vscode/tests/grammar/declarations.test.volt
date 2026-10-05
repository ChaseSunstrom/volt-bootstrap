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

type meters = f64;
// <---- storage.type.volt
//   ^^^^^^ entity.name.type.volt
//            ^^^ support.type.primitive.volt

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

// types where the grammar can tell without the server: after ->, in val x: T, attach headers,
// generic parameter lists, and names with generic arguments
fn origin() -> point {
//             ^^^^^ entity.name.type.volt
    val p: point = { x: 0, y: 0 };
//         ^^^^^ entity.name.type.volt
    var names: std::vec<i32> = {};
//                  ^^^ entity.name.type.volt
    return p;
}

attach shape -> circle {
// <------ keyword.other.volt
//     ^^^^^ entity.name.type.trait.volt
//              ^^^^^^ entity.name.type.volt
}

<T: shape, N: usize>
// <- punctuation.definition.generic.begin.volt
// <~- entity.name.type.parameter.volt
//  ^^^^^ entity.name.type.volt
//         ^ entity.name.type.parameter.volt
//            ^^^^^ support.type.primitive.volt
fn report(s: T&) -> void {
}

attach operator +(this: vec2, o: vec2) -> vec2 {
// <~~~~~~~-------- storage.type.function.volt
}

test "adds up" {
// <---- storage.type.volt
//   ^^^^^^^^^ string.quoted.double.volt
}
