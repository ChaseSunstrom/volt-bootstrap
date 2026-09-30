use std::io;
use std::json;
// std::json: parse, look inside, build, write back
fn main() -> void {
    val v = std::json::parse(" {\"a\": [1, 2.5, -3e2, true, null], \"s\": \"q\\\"\\n\\u00e9\\ud83d\\ude00\", \"o\": {}} ") catch |e| {
        std::println("parse failed");
        return;
    };
    std::println("{}", v.text());
    val a = v.get("a");
    std::println("{} {} {}", a.len(), a.at(1).as_num() ?? 0.0, v.get("s").as_str() ?? "?");
    std::println("{}", v.get("nope").get("deeper").is_null());
    var o = std::json::object();
    o.set("id", std::json::number(7.0));
    o.set("name", std::json::string("tab\there"));
    var list = std::json::array();
    list.add(std::json::value::BOOL(false));
    o.set("list", move list);
    o.set("id", std::json::number(8.0));
    std::println("{}", o.text());
    val bad = std::json::parse("[1, 2") catch |e| std::json::value::NULL;
    std::println("{}", bad.is_null());
}
// expect: {"a":[1,2.5,-300,true,null],"s":"q\"\né😀","o":{}}
// expect: 5 2.5 q"
// expect: é😀
// expect: true
// expect: {"id":8,"name":"tab\there","list":[false]}
// expect: true
