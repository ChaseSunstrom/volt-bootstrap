// flags: --leak-check
use std::io;
use std::text;
// std::text: searching, trimming, splitting, replacing, parsing and UTF-8, plus the string mutators

fn main() -> void {
    // searching
    val s = "one two one";
    std::println("{} {} {} {} {} {} {}", s.find("one"), s.rfind("one"), s.find("zzz"), s.contains("two"), s.starts_with("one"), s.ends_with("two"), s.count("one"));
    // trimming and stripping
    val padded = "   hi there  ";
    std::println("[{}] [{}] [{}]", padded.trim(), padded.trim_start(), padded.trim_end());
    std::println("{} {} {} {} {}", "v1.2".strip_prefix("v"), "v1.2".strip_prefix("x"), "file.txt".strip_suffix(".txt"), "key=value=x".split_once("="), "novalue".split_once("="));
    // splitting and joining
    val parts = "a,b,,c".split(",");
    val lines = "l1\nl2\r\nl3\n".lines();
    val words = "  many   spaced words ".words();
    val letters = "héllo".split("");
    std::println("{} {} {} | {} {} | {} | {} {}", parts.len, std::text::join(parts.items(), "|"), "".split(",").len, lines.len, std::text::join(lines.items(), "+"), std::text::join(words.items(), "_"), letters.len, *letters.at(1));
    // replacing, repeating, case, comparing
    std::println("{} {} {} {} {} {}", "a-b-c".replace("-", "+"), "aaa".replace("aa", "b"), "ab".repeat(3), "MiXeD 1".to_upper(), "MiXeD 1".to_lower(), "Hello".eq_ignore_case("hELLO"));
    std::println("{} {} {} {}", "apple".cmp("banana"), "b".cmp("a"), "x".cmp("x"), "ab".cmp("abc"));
    // parsing
    std::println("{} {} {} {} {} {} {}", "42".parse_int(), "-9223372036854775808".parse_int(), "9223372036854775808".parse_int(), "+7".parse_int(), "12a".parse_int(), "".parse_int(), "-".parse_int());
    std::println("{} {}", "18446744073709551615".parse_uint(), "-1".parse_uint());
    std::println("{} {} {} {} {} {} {} {} {}", "3.5".parse_float(), "-1e3".parse_float(), "1e".parse_float(), ".5".parse_float(), "5.".parse_float(), "inf".parse_float(), "1.2.3".parse_float(), " 1".parse_float(), "true".parse_bool());
    // UTF-8
    val u = "héllo, 世界";
    std::println("{} {} {} {} {} {} {:c}", u.len, u.char_count(), u.is_utf8(), "\xff".is_utf8(), u.char_at(1), u.char_at(2), (*u.chars().at(7)));
    // ASCII classes on u8
    std::println("{} {} {} {} {} {:c}{:c}", '7'.is_digit(), 'x'.is_alpha(), ' '.is_space(), 'F'.is_hex_digit(), 'g'.is_hex_digit(), 'a'.to_upper(), 'Q'.to_lower());
    // std::string: pop, insert, push_char, truncate, clear
    var st = std::string::from("hello!");
    val bang = st.pop();
    st.insert(0, ">> ");
    st.push_char(0x263A);
    val before = st.len();
    st.truncate(5);
    std::print("{} {} {} {} ", st, bang, before, st.is_empty());
    st.clear();
    std::println("{}", st.is_empty());
}
// expect: 0 8 null true true false 2
// expect: [hi there] [hi there  ] [   hi there]
// expect: 1.2 null file (key, value=x) null
// expect: 4 a|b||c 1 | 3 l1+l2+l3 | many_spaced_words | 5 é
// expect: a+b+c ba ababab MIXED 1 mixed 1 true
// expect: -1 1 0 -1
// expect: 42 -9223372036854775808 error.OVERFLOW 7 error.INVALID error.EMPTY error.INVALID
// expect: 18446744073709551615 error.INVALID
// expect: 3.5 -1000 error.INVALID 0.5 5 inf error.INVALID error.INVALID true
// expect: 14 9 true false (233, 2) null 世
// expect: true true true true false Aq
// expect: >> he 33 11 false true
