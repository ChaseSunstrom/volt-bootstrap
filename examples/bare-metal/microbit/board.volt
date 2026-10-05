// The BBC micro:bit (an nRF51822: a Cortex-M0 with 16K of RAM), as qemu's microbit: UART0 for the
// console and the top-left LED of the 5x5 matrix (row 1, column 1). It leaves volt_exit to voltc's
// default, which stops through ARM semihosting (qemu -semihosting, or a debugger), passing the exit
// code on.

// the console: each byte into UART0's TXD, waiting for TXDRDY between them
export fn volt_console_write(p: u8*, n: usize) -> void {
    board::uart_start();
    for (i) in 0..n {
        @volatile_write(board::reg(board::UART0 + board::TXDRDY), 0);
        @volatile_write(board::reg(board::UART0 + board::TXD), @cast<u32>(p[i]));
        while (@volatile_read(board::reg(board::UART0 + board::TXDRDY)) == 0) {}
    }
}

namespace board {
    val NAME: str = "micro:bit (Cortex-M0)";
    val UART0: usize = 0x40002000;
    val STARTTX: usize = 0x008;
    val TXDRDY: usize = 0x11C;
    val ENABLE: usize = 0x500;
    val TXD: usize = 0x51C;
    val GPIO: usize = 0x50000000;
    val OUTSET: usize = 0x508;
    val OUTCLR: usize = 0x50C;
    val DIRSET: usize = 0x518;
    val ROW1: u32 = 0x2000;            // P0.13 high and
    val COL1: u32 = 0x10;              // P0.04 low light the LED

    var uart_on = false;
    var led_ready = false;

    fn reg(at: usize) -> u32* {
        return @cast<u32*>(at);
    }

    fn uart_start() -> void {
        if (!uart_on) {
            @volatile_write(reg(UART0 + ENABLE), 4);
            @volatile_write(reg(UART0 + STARTTX), 1);
            uart_on = true;
        }
    }

    fn led(on: bool) -> void {
        if (!led_ready) {
            @volatile_write(reg(GPIO + DIRSET), ROW1 | COL1);
            @volatile_write(reg(GPIO + OUTCLR), COL1);
            led_ready = true;
        }
        if (on) {
            @volatile_write(reg(GPIO + OUTSET), ROW1);
        } else {
            @volatile_write(reg(GPIO + OUTCLR), ROW1);
        }
    }

    // a busy wait the optimizer can't remove: every step is a volatile store
    fn wait(steps: u32) -> void {
        var n: u32 = 0;
        while (@volatile_read(&n) < steps) {
            @volatile_write(&n, @volatile_read(&n) + 1);
        }
    }
}
