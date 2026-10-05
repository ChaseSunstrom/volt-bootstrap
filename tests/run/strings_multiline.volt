use std::io;
// multi-line strings ("""...""": the closing quotes' indentation comes off every line, escapes work
// as in "...") and raw strings (r"..." and r"""...""": backslashes stay as written)

fn main() -> void {
    val page = """
        <ul>
          <li>one</li>
        </ul>
        """;
    std::println(page);
    std::println("{}", page.len);

    // a blank line stays, even with less indentation; an empty line before the close is a final newline
    val gap = """
        a

        b

        """;
    std::println("{} {}", gap.len, gap[gap.len - 1] == 10);

    // \x41 is A, \""" puts three quotes in, and one or two need nothing
    val esc = """
        \x41 \"""quoted\""" say "hi" and ""
        """;
    std::println(esc);

    val path = r"C:\dir\new";
    std::println("{} {}", path, path.len);
    val pattern = r"""
        \d+\.\d+ "x" \n
        """;
    std::println(pattern);
}
// expect: <ul>
// expect:   <li>one</li>
// expect: </ul>
// expect: 25
// expect: 5 true
// expect: A """quoted""" say "hi" and ""
// expect: C:\dir\new 10
// expect: \d+\.\d+ "x" \n
