// qemu's aarch64 virt board (a Cortex-A53 here, at EL1 with the MMU off): a PL011 UART for the
// console, which needs no setup under qemu. It has no LED, so blinky's LED is only what it prints,
// and it leaves volt_exit to voltc's default, which stops through ARM semihosting (qemu
// -semihosting, or a debugger), passing the exit code on.

// the console: each byte into the PL011's data register
export fn volt_console_write(p: u8*, n: usize) -> void {
    for (i) in 0..n {
        @volatile_write(@cast<u8*>(board::UART), p[i]);
    }
}

namespace board {
    val NAME: str = "qemu aarch64 virt";
    val UART: usize = 0x09000000;

    fn led(on: bool) -> void {}

    // a busy wait the optimizer can't remove: every step is a volatile store
    fn wait(steps: u32) -> void {
        var n: u32 = 0;
        while (@volatile_read(&n) < steps) {
            @volatile_write(&n, @volatile_read(&n) + 1);
        }
    }
}
