// vm_interp: a stack-machine bytecode interpreter counting the primes below n by trial division;
// Volt's instruction is an enum with payloads, run by a match
use std::io;
use std::text;

enum instr {
    PUSH: i64,
    LOAD: usize,
    STORE: usize,
    ADD,
    MUL,
    MOD,
    LT,
    JMP: usize,
    JZ: usize,
    JNZ: usize,
    HALT,
}

fn run(code: instr[..]) -> i64 {
    var stack: i64[256];
    var locals: i64[8];
    var sp: usize = 0;
    var pc: usize = 0;
    loop {
        val ins = &code[pc];
        pc += 1;
        match (*ins) {
            .PUSH(v) => {
                stack[sp] = v;
                sp += 1;
            },
            .LOAD(slot) => {
                stack[sp] = locals[slot];
                sp += 1;
            },
            .STORE(slot) => {
                sp -= 1;
                locals[slot] = stack[sp];
            },
            .ADD => {
                sp -= 1;
                stack[sp - 1] += stack[sp];
            },
            .MUL => {
                sp -= 1;
                stack[sp - 1] *= stack[sp];
            },
            .MOD => {
                sp -= 1;
                stack[sp - 1] %= stack[sp];
            },
            .LT => {
                sp -= 1;
                stack[sp - 1] = if (stack[sp - 1] < stack[sp]) 1 else 0;
            },
            .JMP(target) => {
                pc = target;
            },
            .JZ(target) => {
                sp -= 1;
                if (stack[sp] == 0) {
                    pc = target;
                }
            },
            .JNZ(target) => {
                sp -= 1;
                if (stack[sp] != 0) {
                    pc = target;
                }
            },
            .HALT => {
                return stack[sp - 1];
            },
        }
    }
}

fn main() -> void {
    val n = (std::process::arg(1) ?? "1000000").parse_int() catch 1000000;
    // locals: 0 n, 1 d, 2 count, 3 limit, 4 prime
    val program: instr[] = {
        .PUSH(n), .STORE(3),
        .PUSH(0), .STORE(2),
        .PUSH(2), .STORE(0),
        // 6: while n < limit
        .LOAD(0), .LOAD(3), .LT, .JZ(41),
        .PUSH(1), .STORE(4),
        .PUSH(2), .STORE(1),
        // 14: while !(n < d * d)
        .LOAD(0), .LOAD(1), .LOAD(1), .MUL, .LT, .JNZ(32),
        // 20: if n % d == 0 { prime = 0; break }
        .LOAD(0), .LOAD(1), .MOD, .JNZ(27),
        .PUSH(0), .STORE(4), .JMP(32),
        // 27: d += 1
        .LOAD(1), .PUSH(1), .ADD, .STORE(1), .JMP(14),
        // 32: count += prime; n += 1
        .LOAD(2), .LOAD(4), .ADD, .STORE(2),
        .LOAD(0), .PUSH(1), .ADD, .STORE(0), .JMP(6),
        // 41
        .LOAD(2), .HALT,
    };
    std::println(run(program[..]));
}
