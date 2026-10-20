// Interrupts, for bare metal on a Cortex-M: a system exception is handled by an export fn of its name
// (volt_pendsv, volt_svcall, volt_systick...), each else going to volt_fault; device interrupts by a
// Volt table of handlers the linker puts right after the system ones. Each is raised from software
// here: PendSV through the ICSR, SVCall by the svc instruction (volt_svc, from the start code), and
// the board's device interrupt by pending it in the NVIC. board.volt (one per board directory) has
// the hardware.
use std::io;

var pendsv_runs: u32 = 0;
var svcall_runs: u32 = 0;
var irq_runs: u32 = 0;

export fn volt_pendsv() -> void {
    pendsv_runs += 1;
}

export fn volt_svcall() -> void {
    svcall_runs += 1;
}

export fn on_device_irq() -> void {
    irq_runs += 1;
}

// the device interrupts, IRQ 0 first (the NVIC's numbers; IRQ 0 is the LM3S6965's GPIO port A and
// the nRF51's POWER_CLOCK): the linker script keeps this section right after the system entries
@attributes([@section(".vector_table.irq")])
val IRQS: (extern "C" fn() -> void)[1] = { on_device_irq };

// the start code's: raises SVCall
extern "C" fn volt_svc() -> void;

fn main() -> i32 {
    // PendSV: pending it in the ICSR runs it as soon as nothing more urgent does
    @volatile_write(board::reg(0xE000ED04), 0x10000000);
    while (@volatile_read(&pendsv_runs) == 0) {}
    std::println("pendsv ran {}", pendsv_runs);
    volt_svc();
    std::println("svcall ran {}", svcall_runs);
    // IRQ 0: enabled (ISER) and pended (ISPR) in the NVIC
    @volatile_write(board::reg(0xE000E100), 1);
    @volatile_write(board::reg(0xE000E200), 1);
    while (@volatile_read(&irq_runs) == 0) {}
    std::println("irq ran {}", irq_runs);
    std::println("interrupts on {}", board::NAME);
    return 0;
}
