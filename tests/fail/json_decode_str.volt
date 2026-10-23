// from_json can't make a str: it would point into the JSON value
use std::json;

@attributes([@derive(json)])
struct user {
    name: str;
}

fn main() -> void {
    val v = std::json::object();
    val u = user::from_json(&v);
}
// error: from_json can't read a str: it would point into the JSON value; make it a std::string
