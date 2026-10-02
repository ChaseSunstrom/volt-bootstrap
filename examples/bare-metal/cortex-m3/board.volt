// The EK-LM3S6965 (a Cortex-M3), as qemu's lm3s6965evb: UART0 for the console and the user LED on
// port F, pin 0. It leaves volt_exit to voltc's default, which stops through ARM semihosting (qemu
// -semihosting, or a debugger), passing the exit code on.

// the console: each byte into UART0's data register
export fn volt_console_write(p: u8*, n: usize) -> void {
    for (i) in 0..n {
        @volatile_write(@cast<u8*>(board::UART0), p[i]);
    }
}

namespace board {
    val NAME: str = "lm3s6965 (Cortex-M3)";
    val UART0: usize = 0x4000C000;
    val RCGC2: usize = 0x400FE108;     // the clock gates of the GPIO ports
    val PORTF: usize = 0x40025000;
    val GPIO_DIR: usize = 0x400;
    val GPIO_DEN: usize = 0x51C;
    val LED: u32 = 1;                  // pin 0

    var ready = false;

    fn reg(at: usize) -> u32* {
        return @cast<u32*>(at);
    }

    fn led(on: bool) -> void {
        if (!ready) {
            // clock port F, then make the pin a digital output
            @volatile_write(reg(RCGC2), @volatile_read(reg(RCGC2)) | 0x20);
            @volatile_write(reg(PORTF + GPIO_DIR), @volatile_read(reg(PORTF + GPIO_DIR)) | LED);
            @volatile_write(reg(PORTF + GPIO_DEN), @volatile_read(reg(PORTF + GPIO_DEN)) | LED);
            ready = true;
        }
        // the data register's address bits pick the pins a write changes: base + (pins << 2)
        var v: u32 = 0;
        if (on) {
            v = LED;
        }
        @volatile_write(reg(PORTF + (@cast<usize>(LED) << 2)), v);
    }

    // a busy wait the optimizer can't remove: every step is a volatile store
    fn wait(steps: u32) -> void {
        var n: u32 = 0;
        while (@volatile_read(&n) < steps) {
            @volatile_write(&n, @volatile_read(&n) + 1);
        }
    }
}
