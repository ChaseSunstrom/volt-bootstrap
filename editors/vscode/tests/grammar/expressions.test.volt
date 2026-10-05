// SYNTAX TEST "source.volt" "expressions"
fn main() -> void {
    val total = add(0x1F, 1_000) + 2.5e3;
//  ^^^ storage.type.volt
//              ^^^ entity.name.function.call.volt
//                  ^^^^ constant.numeric.hex.volt
//                        ^^^^^ constant.numeric.integer.volt
//                                 ^^^^^ constant.numeric.float.volt
    var name: str = "a {} b\n";
//  ^^^ storage.type.volt
//            ^^^ support.type.primitive.volt
//                  ^^^^^^^^^^ string.quoted.double.volt
//                     ^^ constant.other.placeholder.volt
//                         ^^ constant.character.escape.volt
    val c = 'x';
//          ^^^ string.quoted.single.volt
    val v = parse(text) catch |e| { return; };
//                      ^^^^^ keyword.control.volt
    val n = find(x) ?? 0;
//                  ^^ keyword.operator.volt
    val q = @cast<u8>(n); // a comment
//          ^^^^^ support.function.builtin.volt
//                ^^ support.type.primitive.volt
//                        ^^^^^^^^^^^^ comment.line.double-slash.volt
    std::println("{}", true);
//  ^^^ entity.name.namespace.volt
//       ^^^^^^^ entity.name.function.call.volt
//                     ^^^^ constant.language.volt
    /* a block
//  ^^^^^^^^^^ comment.block.volt
       comment */
    match (x) { .SOME(v) => {}, default => {} }
//  ^^^^^ keyword.control.volt
//               ^^^^ constant.other.caps.volt
//                       ^^ keyword.operator.volt
//                              ^^^^^^^ keyword.control.volt
    for (i) in 0..n { defer free(i); }
//  ^^^ keyword.control.volt
//          ^^ keyword.control.volt
//              ^^ keyword.operator.volt
//                    ^^^^^ keyword.control.volt
    val m = move p;
//          ^^^^ keyword.other.volt
    val z = null;
//          ^^^^ constant.language.volt
    val path = r"C:\dir\n";
//             ^^^^^^^^^^^ string.quoted.raw.volt
//                     ^^ - constant.character.escape.volt
    val page = """
//             ^^^ string.quoted.triple.volt
        <li>{}</li> \t
//          ^^ constant.other.placeholder.volt
//                  ^^ constant.character.escape.volt
        """;
//      ^^^ string.quoted.triple.volt
    val re = r"""
//           ^^^^ string.quoted.triple.raw.volt
        \d+ "x"
//      ^^^^^^^ string.quoted.triple.raw.volt
        """;
}
