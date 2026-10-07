// Linked into a client of a library built with voltc lib --leak-check: prints how many of the
// library's allocations are still live when the program has ended (0: it freed everything)
#include <stddef.h>
#include <stdio.h>
#ifdef __cplusplus
extern "C" {
#endif
extern size_t volt_live_allocs;
#ifdef __cplusplus
}
#endif

__attribute__((destructor)) static void volt_leak_report(void) {
    fprintf(stderr, "volt live: %zu\n", volt_live_allocs);
}
