// vm_interp: a stack-machine bytecode interpreter counting the primes below n by trial division;
// C++'s instruction is a std::variant of structs, run by std::visit with a lambda per kind
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <variant>
#include <vector>

struct push { int64_t value; };
struct load { int slot; };
struct store { int slot; };
struct add {};
struct mul {};
struct mod {};
struct lt {};
struct jmp { int target; };
struct jz { int target; };
struct jnz { int target; };
struct halt {};
using instr = std::variant<push, load, store, add, mul, mod, lt, jmp, jz, jnz, halt>;

template <class... Ts> struct overloaded : Ts... { using Ts::operator()...; };

static int64_t run(const std::vector<instr> &code) {
    std::array<int64_t, 256> stack;
    std::array<int64_t, 8> locals{};
    int sp = 0, pc = 0;
    bool running = true;
    while (running) {
        std::visit(overloaded{
            [&](const push &i) { stack[sp++] = i.value; },
            [&](const load &i) { stack[sp++] = locals[i.slot]; },
            [&](const store &i) { locals[i.slot] = stack[--sp]; },
            [&](add) { sp--; stack[sp - 1] += stack[sp]; },
            [&](mul) { sp--; stack[sp - 1] *= stack[sp]; },
            [&](mod) { sp--; stack[sp - 1] %= stack[sp]; },
            [&](lt) { sp--; stack[sp - 1] = stack[sp - 1] < stack[sp]; },
            [&](const jmp &i) { pc = i.target; },
            [&](const jz &i) { if (stack[--sp] == 0) pc = i.target; },
            [&](const jnz &i) { if (stack[--sp] != 0) pc = i.target; },
            [&](halt) { running = false; },
        }, code[pc++]);
    }
    return stack[sp - 1];
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? std::atol(argv[1]) : 1000000;
    // locals: 0 n, 1 d, 2 count, 3 limit, 4 prime
    std::vector<instr> program = {
        push{n}, store{3},
        push{0}, store{2},
        push{2}, store{0},
        // 6: while n < limit
        load{0}, load{3}, lt{}, jz{41},
        push{1}, store{4},
        push{2}, store{1},
        // 14: while !(n < d * d)
        load{0}, load{1}, load{1}, mul{}, lt{}, jnz{32},
        // 20: if n % d == 0 { prime = 0; break }
        load{0}, load{1}, mod{}, jnz{27},
        push{0}, store{4}, jmp{32},
        // 27: d += 1
        load{1}, push{1}, add{}, store{1}, jmp{14},
        // 32: count += prime; n += 1
        load{2}, load{4}, add{}, store{2},
        load{0}, push{1}, add{}, store{0}, jmp{6},
        // 41
        load{2}, halt{},
    };
    std::printf("%lld\n", (long long)run(program));
}
