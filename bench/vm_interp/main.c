// vm_interp: a stack-machine bytecode interpreter counting the primes below n by trial division;
// C's instruction is a struct of an enum tag and a union, run by a switch
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef enum { PUSH, LOAD, STORE, ADD, MUL, MOD, LT, JMP, JZ, JNZ, HALT } opcode;
typedef struct {
    opcode op;
    union { int64_t value; int slot; int target; };
} instr;

static int64_t run(const instr *code) {
    int64_t stack[256], locals[8] = {0};
    int sp = 0, pc = 0;
    for (;;) {
        const instr *in = &code[pc++];
        switch (in->op) {
        case PUSH: stack[sp++] = in->value; break;
        case LOAD: stack[sp++] = locals[in->slot]; break;
        case STORE: locals[in->slot] = stack[--sp]; break;
        case ADD: sp--; stack[sp - 1] += stack[sp]; break;
        case MUL: sp--; stack[sp - 1] *= stack[sp]; break;
        case MOD: sp--; stack[sp - 1] %= stack[sp]; break;
        case LT: sp--; stack[sp - 1] = stack[sp - 1] < stack[sp]; break;
        case JMP: pc = in->target; break;
        case JZ: if (stack[--sp] == 0) pc = in->target; break;
        case JNZ: if (stack[--sp] != 0) pc = in->target; break;
        case HALT: return stack[sp - 1];
        }
    }
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? atol(argv[1]) : 1000000;
    // locals: 0 n, 1 d, 2 count, 3 limit, 4 prime
    instr program[] = {
        {PUSH, .value = n}, {STORE, .slot = 3},
        {PUSH, .value = 0}, {STORE, .slot = 2},
        {PUSH, .value = 2}, {STORE, .slot = 0},
        // 6: while n < limit
        {LOAD, .slot = 0}, {LOAD, .slot = 3}, {LT}, {JZ, .target = 41},
        {PUSH, .value = 1}, {STORE, .slot = 4},
        {PUSH, .value = 2}, {STORE, .slot = 1},
        // 14: while !(n < d * d)
        {LOAD, .slot = 0}, {LOAD, .slot = 1}, {LOAD, .slot = 1}, {MUL}, {LT}, {JNZ, .target = 32},
        // 20: if n % d == 0 { prime = 0; break }
        {LOAD, .slot = 0}, {LOAD, .slot = 1}, {MOD}, {JNZ, .target = 27},
        {PUSH, .value = 0}, {STORE, .slot = 4}, {JMP, .target = 32},
        // 27: d += 1
        {LOAD, .slot = 1}, {PUSH, .value = 1}, {ADD}, {STORE, .slot = 1}, {JMP, .target = 14},
        // 32: count += prime; n += 1
        {LOAD, .slot = 2}, {LOAD, .slot = 4}, {ADD}, {STORE, .slot = 2},
        {LOAD, .slot = 0}, {PUSH, .value = 1}, {ADD}, {STORE, .slot = 0}, {JMP, .target = 6},
        // 41
        {LOAD, .slot = 2}, {HALT},
    };
    printf("%lld\n", (long long)run(program));
    return 0;
}
