// --target: building for bare metal (no OS, no libc, no C compiler). Each target is an LLVM triple,
// CPU and features, the values @cfg sees, and the start code voltc puts in the program: it sets up
// the stack, copies .data, zeroes .bss, runs constructors, calls main and then volt_exit. The board
// (the program, or a package for it) supplies volt_exit and volt_console_write; when it doesn't, the
// defaults here stop the CPU and drop the text. The symbols the start code reads come from the linker
// script.
use std::io;

struct target_info {
    name: str;     // what --target takes
    triple: str;
    cpu: str;
    features: str;
    arch: str;     // @cfg("arch")
    bits: str;     // @cfg("pointer_bits")
    cfg: str[3];   // the --cfg settings that make @cfg see the target
}

fn targets() -> std::vec<target_info> {
    var v: std::vec<target_info> = {};
    // -relax: the start code doesn't set gp, so the linker mustn't relax addresses through it
    put(&v, { name: "riscv32-none", triple: "riscv32-unknown-none-elf", cpu: "generic-rv32", features: "+m,+a,+c,-relax", arch: "riscv32", bits: "32", cfg: { "os=none", "arch=riscv32", "pointer_bits=32" } });
    put(&v, { name: "riscv64-none", triple: "riscv64-unknown-none-elf", cpu: "generic-rv64", features: "+m,+a,+f,+d,+c,-relax", arch: "riscv64", bits: "64", cfg: { "os=none", "arch=riscv64", "pointer_bits=64" } });
    put(&v, { name: "thumbv7m-none", triple: "thumbv7m-none-eabi", cpu: "cortex-m3", features: "", arch: "arm", bits: "32", cfg: { "os=none", "arch=arm", "pointer_bits=32" } });
    put(&v, { name: "thumbv7em-none", triple: "thumbv7em-none-eabi", cpu: "cortex-m4", features: "", arch: "arm", bits: "32", cfg: { "os=none", "arch=arm", "pointer_bits=32" } });
    return move v;
}

fn find_target(name: str) -> target_info? {
    for (t&) in targets().items() {
        if (t.name == name) {
            return *t;
        }
    }
    return null;
}

// the --target names, for messages
fn target_names() -> std::string {
    var s: std::string = {};
    for (t&) in targets().items() {
        if (s.len() > 0) {
            s.append(", ");
        }
        s.append(t.name);
    }
    return move s;
}

// the defaults for the board's hooks the program doesn't define: volt_exit stops (on Cortex-M through
// ARM semihosting: qemu -semihosting, or a debugger), volt_console_write drops the text
fn hook_defaults_asm(t: target_info, exit: bool, console: bool) -> std::string {
    var out: std::string = {};
    if (t.arch == "arm") {
        out.append("    .section .text.volt_hooks,\"ax\",%progbits\n    .syntax unified\n    .thumb\n");
        if (exit) {
            out.append("    .thumb_func\n    .globl volt_exit\n    .type volt_exit,%function\nvolt_exit:\n    sub sp, sp, #8\n    ldr r1, =0x20026\n    str r1, [sp]\n    str r0, [sp, #4]\n    movs r0, #0x20\n    mov r1, sp\n    bkpt 0xab\n1:  b 1b\n    .ltorg\n");
        }
        if (console) {
            out.append("    .thumb_func\n    .globl volt_console_write\n    .type volt_console_write,%function\nvolt_console_write:\n    bx lr\n");
        }
        return move out;
    }
    out.append("    .section .text.volt_hooks,\"ax\",@progbits\n");
    if (exit) {
        out.append("    .globl volt_exit\n    .type volt_exit,@function\nvolt_exit:\n1:  wfi\n    j 1b\n");
    }
    if (console) {
        out.append("    .globl volt_console_write\n    .type volt_console_write,@function\nvolt_console_write:\n    ret\n");
    }
    return move out;
}

// the start code for t, as module-level assembly
fn start_asm(t: target_info) -> std::string {
    var out: std::string = {};
    if (t.arch == "arm") {
        // Cortex-M: the vector table (the stack top, then the reset handler, then faults) starts the
        // CPU
        val lines: str[] = {
            "    .syntax unified",
            "    .section .vector_table,\"a\",%progbits",
            "    .globl __volt_vectors",
            "    .p2align 2",
            "__volt_vectors:",
            "    .word __stack_top",
            "    .word _start",
            "    .rept 14",
            "    .word volt_fault",
            "    .endr",
            "",
            "    .section .text.volt_start,\"ax\",%progbits",
            "    .thumb",
            "    .thumb_func",
            "    .globl _start",
            "    .type _start,%function",
            "_start:",
            "    ldr r0, =__data_load",
            "    ldr r1, =__data_start",
            "    ldr r2, =__data_end",
            "1:  cmp r1, r2",
            "    bhs 2f",
            "    ldr r3, [r0]",
            "    str r3, [r1]",
            "    adds r0, r0, #4",
            "    adds r1, r1, #4",
            "    b 1b",
            "2:  ldr r1, =__bss_start",
            "    ldr r2, =__bss_end",
            "    movs r3, #0",
            "3:  cmp r1, r2",
            "    bhs 4f",
            "    str r3, [r1]",
            "    adds r1, r1, #4",
            "    b 3b",
            "4:  ldr r4, =__init_array_start",
            "    ldr r5, =__init_array_end",
            "5:  cmp r4, r5",
            "    bhs 6f",
            "    ldr r0, [r4]",
            "    blx r0",
            "    adds r4, r4, #4",
            "    b 5b",
            "6:  movs r0, #0",
            "    movs r1, #0",
            "    bl main",
            "    bl volt_exit",
            "7:  b 7b",
            "    .ltorg",
            "",
            "    .thumb_func",
            "    .weak volt_fault",
            "    .type volt_fault,%function",
            "volt_fault:",
            "    b volt_fault",
            "",
            "    .thumb_func",
            "    .globl volt_heap_start",
            "    .type volt_heap_start,%function",
            "volt_heap_start:",
            "    ldr r0, =__heap_start",
            "    bx lr",
            "    .thumb_func",
            "    .globl volt_heap_end",
            "    .type volt_heap_end,%function",
            "volt_heap_end:",
            "    ldr r0, =__heap_end",
            "    bx lr",
            "    .ltorg",
            "",
            "    .thumb_func",
            "    .globl volt_hook_console_write",
            "    .type volt_hook_console_write,%function",
            "volt_hook_console_write:",
            "    b volt_console_write",
            "    .thumb_func",
            "    .globl volt_hook_exit",
            "    .type volt_hook_exit,%function",
            "volt_hook_exit:",
            "    b volt_exit",
            "",
            "    .section .bss.volt_args,\"aw\",%nobits",
            "    .globl volt_argc",
            "    .globl volt_argv",
            "    .p2align 2",
            "volt_argc:",
            "    .zero 4",
            "volt_argv:",
            "    .zero 4",
        };
        for (l) in lines {
            out.append(l);
            out.push('\n');
            if (l == "_start:" && t.name == "thumbv7em-none") {
                // a Cortex-M4's FPU is off at reset: grant access to it (CPACR's CP10 and CP11)
                out.append("    ldr r0, =0xE000ED88\n    ldr r1, [r0]\n    orr r1, r1, #0xF00000\n    str r1, [r0]\n    dsb\n    isb\n");
            }
        }
        return move out;
    }
    // RISC-V: the init_array walk and argv take a pointer's size
    var ld = "lw";
    var sz = "4";
    if (t.bits == "64") {
        ld = "ld";
        sz = "8";
    }
    val lines: str[] = {
        "    .section .text.volt_start,\"ax\",@progbits",
        "    .globl _start",
        "    .type _start,@function",
        "_start:",
        "    la sp, __stack_top",
        "    la t0, __data_load",
        "    la t1, __data_start",
        "    la t2, __data_end",
        "1:  bgeu t1, t2, 2f",
        "    lw t3, 0(t0)",
        "    sw t3, 0(t1)",
        "    addi t0, t0, 4",
        "    addi t1, t1, 4",
        "    j 1b",
        "2:  la t1, __bss_start",
        "    la t2, __bss_end",
        "3:  bgeu t1, t2, 4f",
        "    sw zero, 0(t1)",
        "    addi t1, t1, 4",
        "    j 3b",
        "4:  la s0, __init_array_start",
        "    la s1, __init_array_end",
        "5:  bgeu s0, s1, 6f",
        "{INIT}",
        "    j 5b",
        "6:  li a0, 0",
        "    li a1, 0",
        "    call main",
        "    call volt_exit",
        "7:  j 7b",
        "",
        "    .globl volt_heap_start",
        "    .type volt_heap_start,@function",
        "volt_heap_start:",
        "    la a0, __heap_start",
        "    ret",
        "    .globl volt_heap_end",
        "    .type volt_heap_end,@function",
        "volt_heap_end:",
        "    la a0, __heap_end",
        "    ret",
        "",
        "    .globl volt_hook_console_write",
        "    .type volt_hook_console_write,@function",
        "volt_hook_console_write:",
        "    tail volt_console_write",
        "    .globl volt_hook_exit",
        "    .type volt_hook_exit,@function",
        "volt_hook_exit:",
        "    tail volt_exit",
        "",
        "    .section .bss.volt_args,\"aw\",@nobits",
        "    .globl volt_argc",
        "    .globl volt_argv",
        "    .p2align 3",
        "volt_argc:",
        "    .zero 8",
        "volt_argv:",
        "    .zero 8",
    };
    for (l) in lines {
        if (l == "    la sp, __stack_top" && t.name == "riscv64-none") {
            // its FPU (the F and D extensions) is off at reset: mstatus.FS from off to initial
            out.append("    li t0, 0x2000\n    csrs mstatus, t0\n");
        }
        if (l == "{INIT}") {
            out.append("    ");
            out.append(ld);
            out.append(" t0, 0(s0)\n    jalr t0\n    addi s0, s0, ");
            out.append(sz);
            out.push('\n');
        } else {
            out.append(l);
            out.push('\n');
        }
    }
    return move out;
}
