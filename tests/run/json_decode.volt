// T::from_json reads back what to_json writes: fields by name, a member that isn't there leaves the
// field's default (null for an optional), vectors, nested types and enums; a value that doesn't fit
// says where
use std::io;
use std::json;

@attributes([@derive(json)])
enum shape {
    NONE,
    CIRCLE: f64,
    RECT: (i32, i32),
}

@attributes([@derive(json)])
struct item {
    name: std::string;
    count: u8 = 1;
}

@attributes([@derive(json)])
struct order {
    id: i64;
    items: std::vec<item>;
    note: std::string?;
    shapes: std::vec<shape>;
    rush: bool = false;
}

fn show(text: str) -> void {
    val v = std::json::parse(text) catch |e| {
        std::println("not JSON");
        return;
    };
    val o = order::from_json(&v) catch |e| {
        std::println("{}", e);
        return;
    };
    std::println("{}", o.to_json().text());
}

fn main() -> void {
    show("{\"id\": 7, \"items\": [{\"name\": \"tea\", \"count\": 2}, {\"name\": \"cake\"}], \"shapes\": [\"NONE\", {\"CIRCLE\": 1.5}, {\"RECT\": [2, 3]}], \"extra\": 0}");
    show("{\"id\": -9007199254740993, \"items\": [], \"note\": null, \"shapes\": [], \"rush\": true}");
    show("{\"id\": 7, \"items\": [], \"note\": \"leave at the door\", \"shapes\": []}");
    show("{\"id\": 7, \"items\": [{\"name\": \"tea\", \"count\": 300}], \"shapes\": []}");
    show("{\"id\": 7.5, \"items\": [], \"shapes\": []}");
    show("{\"items\": [], \"shapes\": []}");
    show("{\"id\": 1, \"items\": [{\"name\": 5}], \"shapes\": []}");
    show("{\"id\": 1, \"items\": [{\"name\": null}], \"shapes\": []}");
    show("{\"id\": 1, \"items\": [], \"shapes\": [\"SQUARE\"]}");
    show("{\"id\": 1, \"items\": [], \"shapes\": [\"CIRCLE\"]}");
    show("{\"id\": 1, \"items\": [], \"shapes\": [{\"NONE\": 1}]}");
    show("{\"id\": 1, \"items\": [], \"shapes\": [{\"RECT\": [2]}]}");
    show("{\"id\": 1, \"items\": [], \"shapes\": [{\"RECT\": [2, true]}]}");
    show("{\"id\": 1, \"items\": {}, \"shapes\": []}");
    show("[1, 2]");
    show("{\"id\": \"a string much too long to show in the message\", \"items\": [], \"shapes\": [5]}");
    show("{\"id\": 1, \"items\": [], \"shapes\": [5]}");

    // what to_json wrote reads back as the same value
    var o: order = { id: 3, items: {}, note: null, shapes: {} };
    o.items.push({ name: std::string::from("pie"), count: 4 });
    o.shapes.push(shape::RECT(5, 6));
    val written = o.to_json();
    val back = order::from_json(&written) catch @panic("didn't read back");
    std::println("{} {} {}", back.id, back.items[0].name.as_str(), back.shapes[0]);

    // the types std knows have one too
    val n = std::json::parse("[1, 2, 3]") catch @panic("bad");
    val xs = std::vec<u16>::from_json(&n) catch @panic("bad");
    val big = std::json::number(256.0);
    std::println("{} {}", xs.len, u8::from_json(&big));
}
// flags: --leak-check
// expect: {"id":7,"items":[{"name":"tea","count":2},{"name":"cake","count":1}],"note":null,"shapes":["NONE",{"CIRCLE":1.5},{"RECT":[2,3]}],"rush":false}
// expect: {"id":-9007199254740992,"items":[],"note":null,"shapes":[],"rush":true}
// expect: {"id":7,"items":[],"note":"leave at the door","shapes":[],"rush":false}
// expect: INVALID(.items[0].count: expected a u8, got 300)
// expect: INVALID(.id: expected an i64, got 7.5)
// expect: INVALID(.id: missing)
// expect: INVALID(.items[0].name: expected a string, got 5)
// expect: INVALID(.items[0].name: expected a string, got null)
// expect: INVALID(.shapes[0]: shape has no variant SQUARE)
// expect: INVALID(.shapes[0]: CIRCLE takes a payload: {"CIRCLE": ...})
// expect: INVALID(.shapes[0]: NONE takes no payload: "NONE")
// expect: INVALID(.shapes[0].RECT: expected 2 elements, got 1)
// expect: INVALID(.shapes[0].RECT[1]: expected an i32, got true)
// expect: INVALID(.items: expected an array, got an object)
// expect: INVALID(expected an object, got an array)
// expect: INVALID(.id: expected an i64, got a string)
// expect: INVALID(.shapes[0]: expected a variant of shape, got 5)
// expect: 3 pie RECT(5, 6)
// expect: 3 error.INVALID(expected a u8, got 256)
