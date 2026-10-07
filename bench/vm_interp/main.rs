// vm_interp: a stack-machine bytecode interpreter counting the primes below n by trial division; Rust's instruction is an enum with payloads, run by a match
#[derive(Clone, Copy)]
enum Instr {
    Push(i64),
    Load(usize),
    Store(usize),
    Add,
    Mul,
    Mod,
    Lt,
    Jmp(usize),
    Jz(usize),
    Jnz(usize),
    Halt,
}
use Instr::*;

fn run(code: &[Instr]) -> i64 {
    let mut stack = [0i64; 256];
    let mut locals = [0i64; 8];
    let (mut sp, mut pc) = (0, 0);
    loop {
        let instr = code[pc];
        pc += 1;
        match instr {
            Push(v) => {
                stack[sp] = v;
                sp += 1;
            }
            Load(slot) => {
                stack[sp] = locals[slot];
                sp += 1;
            }
            Store(slot) => {
                sp -= 1;
                locals[slot] = stack[sp];
            }
            Add => {
                sp -= 1;
                stack[sp - 1] += stack[sp];
            }
            Mul => {
                sp -= 1;
                stack[sp - 1] *= stack[sp];
            }
            Mod => {
                sp -= 1;
                stack[sp - 1] %= stack[sp];
            }
            Lt => {
                sp -= 1;
                stack[sp - 1] = (stack[sp - 1] < stack[sp]) as i64;
            }
            Jmp(target) => pc = target,
            Jz(target) => {
                sp -= 1;
                if stack[sp] == 0 {
                    pc = target;
                }
            }
            Jnz(target) => {
                sp -= 1;
                if stack[sp] != 0 {
                    pc = target;
                }
            }
            Halt => return stack[sp - 1],
        }
    }
}

fn main() {
    let n: i64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1_000_000);
    // locals: 0 n, 1 d, 2 count, 3 limit, 4 prime
    let program = [
        Push(n), Store(3),
        Push(0), Store(2),
        Push(2), Store(0),
        // 6: while n < limit
        Load(0), Load(3), Lt, Jz(41),
        Push(1), Store(4),
        Push(2), Store(1),
        // 14: while !(n < d * d)
        Load(0), Load(1), Load(1), Mul, Lt, Jnz(32),
        // 20: if n % d == 0 { prime = 0; break }
        Load(0), Load(1), Mod, Jnz(27),
        Push(0), Store(4), Jmp(32),
        // 27: d += 1
        Load(1), Push(1), Add, Store(1), Jmp(14),
        // 32: count += prime; n += 1
        Load(2), Load(4), Add, Store(2),
        Load(0), Push(1), Add, Store(0), Jmp(6),
        // 41
        Load(2), Halt,
    ];
    println!("{}", run(&program));
}
