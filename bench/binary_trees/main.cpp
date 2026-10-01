// binary-trees (the Benchmarks Game): allocate and walk many perfect binary trees, then free them
#include <cstdio>
#include <cstdlib>
#include <memory>

struct node { std::unique_ptr<node> left, right; };

static std::unique_ptr<node> make(int depth) {
    auto n = std::make_unique<node>();
    if (depth > 0) { n->left = make(depth - 1); n->right = make(depth - 1); }
    return n;
}
static int check(const node &n) { return 1 + (n.left ? check(*n.left) + check(*n.right) : 0); }

int main(int argc, char **argv) {
    int max = argc > 1 ? std::atoi(argv[1]) : 18;
    if (max < 6) max = 6;
    std::printf("stretch tree of depth %d\t check: %d\n", max + 1, check(*make(max + 1)));
    auto long_lived = make(max);
    for (int d = 4; d <= max; d += 2) {
        int iters = 1 << (max - d + 4), sum = 0;
        for (int i = 0; i < iters; i++) sum += check(*make(d));
        std::printf("%d\t trees of depth %d\t check: %d\n", iters, d, sum);
    }
    std::printf("long lived tree of depth %d\t check: %d\n", max, check(*long_lived));
}
