// Blinky, for bare metal: no OS, no libc, no C compiler (voltc --target). It blinks the board's LED a
// few times and says so on the board's console, keeping the times in a vec and the count in a box,
// so it uses std's printing, allocation and floating point too. board.volt (one per board
// directory) has the hardware.
use std::io;

fn main() -> i32 {
    var blinks: std::vec<u32> = {};
    val count = u32::new(0) catch return 1;
    for (i) in 0..6 {
        val on = i % 2 == 0;
        board::led(on);
        if (on) {
            std::println("led on");
            blinks.push(@cast<u32>(i));
            *count += 1;
        } else {
            std::println("led off");
        }
        board::wait(200000);
    }
    std::println("{} blinks on {}", *count, board::NAME);
    // floating point: in hardware where the core has it, in std::softfloat where it doesn't
    std::println("on {:.1}% of the time, {} of {}", @cast<f64>(*count) / 6.0 * 100.0, @cast<f32>(*count) / 6.0, 1.0);
    // 0 when the vec and the box agree
    return @cast<i32>(blinks.len) - @cast<i32>(*count);
}
