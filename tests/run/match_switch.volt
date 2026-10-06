// a match on whole variants runs as a switch on the tag: payload bindings, a catch-all in the middle
// (the arms after it never run), a repeated variant (the first arm wins), and the fallbacks to tests
// in order (a guard, a payload pattern) all pick the arm a chain of tests would
use std::io;

enum op { PUSH: i64, ADD, MUL, NEG, DUP, HALT }

struct a1 { k: i32; }
struct a2 { k: i32; }
trait sized {
    fn size(this) -> i32;
}
attach sized -> a1 {
    fn size(this) -> i32 { return this.k; }
}
attach sized -> a2 {
    fn size(this) -> i32 { return this.k * 2; }
}

fn run(code: op[..]) -> i64 {
    var stack: i64[8];
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
            .ADD => {
                sp -= 1;
                stack[sp - 1] += stack[sp];
            },
            .MUL => {
                sp -= 1;
                stack[sp - 1] *= stack[sp];
            },
            .NEG => { stack[sp - 1] = -stack[sp - 1]; },
            .DUP => {
                stack[sp] = stack[sp - 1];
                sp += 1;
            },
            .HALT => { return stack[sp - 1]; },
        }
    }
}

fn name(o: op) -> str {
    return match (o) {
        .ADD => "add",
        .ADD => "add again",
        .MUL => "mul",
        default => "other",
        .NEG => "neg",
    };
}

fn guarded(o: op) -> str {
    return match (o) {
        .PUSH(v) if v > 10 => "big push",
        .PUSH(_) => "push",
        default => "other",
    };
}

fn payload(o: op) -> str {
    return match (o) {
        .PUSH(0) => "push zero",
        .PUSH(_) => "push",
        .HALT => "halt",
        default => "other",
    };
}

fn member(s: sized) -> str {
    return match (s) {
        a2(x) => "a2",
        a1(x) => "a1",
    };
}

fn main() -> void {
    val code: op[] = { op::PUSH(6), .DUP, .MUL, op::PUSH(4), .NEG, .ADD, .HALT };
    std::println(run(code));
    std::println("{} {} {} {}", name(op::ADD), name(op::MUL), name(op::NEG), name(op::HALT));
    std::println("{} {} {}", guarded(op::PUSH(11)), guarded(op::PUSH(3)), guarded(op::DUP));
    std::println("{} {} {} {}", payload(op::PUSH(0)), payload(op::PUSH(2)), payload(op::HALT), payload(op::ADD));
    val x: a1 = { k: 1 };
    val y: a2 = { k: 2 };
    std::println("{} {}", member(x), member(y));
}
// expect: 32
// expect: add mul other other
// expect: big push push other
// expect: push zero push halt other
// expect: a1 a2
