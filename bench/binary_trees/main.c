// binary-trees (the Benchmarks Game): allocate and walk many perfect binary trees, then free them
#include <stdio.h>
#include <stdlib.h>

typedef struct node { struct node *left, *right; } node;

static node *make(int depth) {
    node *n = malloc(sizeof(node));
    if (depth > 0) { n->left = make(depth - 1); n->right = make(depth - 1); }
    else { n->left = n->right = NULL; }
    return n;
}
static int check(const node *n) { return 1 + (n->left ? check(n->left) + check(n->right) : 0); }
static void drop(node *n) { if (n->left) { drop(n->left); drop(n->right); } free(n); }

int main(int argc, char **argv) {
    int max = argc > 1 ? atoi(argv[1]) : 18;
    if (max < 6) max = 6;
    node *stretch = make(max + 1);
    printf("stretch tree of depth %d\t check: %d\n", max + 1, check(stretch));
    drop(stretch);
    node *long_lived = make(max);
    for (int d = 4; d <= max; d += 2) {
        int iters = 1 << (max - d + 4), sum = 0;
        for (int i = 0; i < iters; i++) { node *t = make(d); sum += check(t); drop(t); }
        printf("%d\t trees of depth %d\t check: %d\n", iters, d, sum);
    }
    printf("long lived tree of depth %d\t check: %d\n", max, check(long_lived));
    drop(long_lived);
    return 0;
}
