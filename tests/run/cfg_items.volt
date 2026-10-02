// @cfg on an item: it's only in the build when the setting holds; @volatile_read and @volatile_write
// keep every load and store (memory-mapped registers)
use std::io;
// flags: --cfg feature=fast

@attributes([@cfg("feature", "fast")])
fn speed() -> str { return "fast"; }

@attributes([@cfg("feature", "slow")])
fn speed() -> str { return "slow"; }

// never checked: the name it uses doesn't exist
@attributes([@cfg("os", "none")])
fn bare() -> void { no_such_thing(); }

@attributes([@cfg("feature", "slow")])
struct only_slow { x: i32; }

fn main() -> void {
    var reg: u32 = 0;
    @volatile_write(&reg, 5);
    @volatile_write(&reg, @volatile_read(&reg) + 1);
    std::println("{} {}", speed(), @volatile_read(&reg));
}
// expect: fast 6
