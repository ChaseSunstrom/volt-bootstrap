use std::io;
use std::string;
// a catch handler or `??` fallback that returns moves only on its own path: the local is still
// usable after it
error odd { ODD }

fn half(x: i32) -> odd!i32 {
    if (x % 2 == 1) {
        return odd::ODD;
    }
    return x / 2;
}

fn via_catch(x: i32) -> std::string {
    var out = std::string::from("c");
    val h = half(x) catch |e| {
        return move out;
    };
    out.push('!');
    return move out;
}

fn via_orelse(x: i32?) -> std::string {
    var out = std::string::from("o");
    val v = x ?? return move out;
    out.push('!');
    return move out;
}

fn main() -> void {
    std::println("{} {} {} {}", via_catch(2).as_str(), via_catch(3).as_str(), via_orelse(1).as_str(), via_orelse(null).as_str());
}
// expect: c! c o! o
