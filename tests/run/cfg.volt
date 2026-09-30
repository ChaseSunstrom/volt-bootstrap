use std::io;
// @cfg reads --cfg settings for the files it's written in (here: the program's own)
// flags: --cfg feature=fast --cfg level=3 --cfg other:feature=slow
fn speed() -> str {
    comptime if (@cfg("feature", "fast")) {
        return "fast";
    }
    return "normal";
}
fn main() -> void {
    std::println("{} {} {} {}", speed(), @cfg("level"), @cfg("level", "2"), @cfg("feature", "slow"));
}
// expect: fast true false false
