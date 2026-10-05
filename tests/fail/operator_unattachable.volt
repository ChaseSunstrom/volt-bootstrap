// && || ?? = . and the wrapping operators keep their meaning on every type
struct flag {
    on: bool;
}

attach operator &&(this: flag, o: flag) -> bool {
    return this.on && o.on;
}

fn main() -> void {}
// error: && can't be attached; these can: + - * / % & | ^ << >> ~ < == []
