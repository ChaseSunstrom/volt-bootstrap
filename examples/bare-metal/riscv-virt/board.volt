// qemu's riscv virt board: an NS16550 UART for the console and the SiFive test device, which stops
// qemu with an exit code. It has no LED, so blinky's LED is only what it prints.

// the console: each byte into the UART's transmit register
export fn volt_console_write(p: u8*, n: usize) -> void {
    for (i) in 0..n {
        @volatile_write(@cast<u8*>(board::UART), p[i]);
    }
}

// the test device: 0x5555 stops qemu with exit code 0, (code << 16) | 0x3333 with that code
export fn volt_exit(code: i32) -> never {
    var v: u32 = 0x5555;
    if (code != 0) {
        v = (@cast<u32>(code) << 16) | 0x3333;
    }
    @volatile_write(@cast<u32*>(board::TEST), v);
    loop {}
}

namespace board {
    val NAME: str = "qemu riscv virt";
    val UART: usize = 0x10000000;
    val TEST: usize = 0x100000;

    fn led(on: bool) -> void {}

    // a busy wait the optimizer can't remove: every step is a volatile store
    fn wait(steps: u32) -> void {
        var n: u32 = 0;
        while (@volatile_read(&n) < steps) {
            @volatile_write(&n, @volatile_read(&n) + 1);
        }
    }
}
