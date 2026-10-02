// C calls the Volt library greet through its C header (bindings/greet.h)
#include <stdio.h>
#include "greet.h"

int main(void) {
    printf("add %lld\n", (long long)add(2, 3));
    // owned text: free it when done
    volt_text t = hello((volt_str){(const uint8_t *)"volt", 4});
    printf("%.*s\n", (int)t.len, (const char *)t.ptr);
    volt_text_free(t);
    // a class: a handle, freed with tally_free
    greet_tally *c = tally_new((volt_str){(const uint8_t *)"clicks", 6});
    tally_add(c, 1);
    int64_t n = tally_add(c, 2);
    volt_str name = tally_name(c);
    printf("%.*s %lld\n", (int)name.len, (const char *)name.ptr, (long long)n);
    tally_free(c);
    return 0;
}
