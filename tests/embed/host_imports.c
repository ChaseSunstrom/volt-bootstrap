// A C program running a Volt script that imports a C header and a C++ one (tests/embed.rs runs it
// with the compilers on PATH): their C and C++ is compiled for the script as it loads. A sandbox's
// script can't import them.
#include <stdio.h>
#include <string.h>
#include "voltvm.h"

static volt_str S(const char *s) { return (volt_str){ (const uint8_t *)s, strlen(s) }; }

static void say_error(voltvm_volt_vm *vm, const char *what) {
    volt_str e = volt_vm_error(vm);
    printf("%s: %.*s\n", what, (int)e.len, (const char *)e.ptr);
}

int main(int argc, char **argv) {
    volt_str std_dir = S(argv[1]);
    char script[2048];
    snprintf(script, sizeof script,
             "use { \"%s/vmhost.h\" } as h;\n"
             "use { \"%s/vmhost.hpp\" } as hp;\n"
             "export fn run() -> i64 {\n"
             "    val a: i32 = 4;\n"
             "    var t = hp::vm::Tally::new();\n"
             "    t.add(10);\n"
             "    t.add(20);\n"
             "    val v: i32[3] = { 1, 2, 3 };\n"
             "    return @cast<i64>(h::h_twice(a) + h::H_MAX(a, 9) + hp::vm::total(v[0..3]) + t.value());\n"
             "}\n",
             argv[2], argv[2]);
    voltvm_volt_vm *vm = volt_vm_new(std_dir);
    if (volt_vm_load(vm, S("imports.volt"), S(script)).error) {
        say_error(vm, "load");
        return 1;
    }
    printf("run %lld\n", ((long long (*)(void))volt_vm_find(vm, S("run")))());
    volt_vm_free(vm);
    voltvm_volt_vm *box = volt_vm_new(std_dir);
    if (volt_vm_allow(box, S("strlen")).error) {
        say_error(box, "allow");
        return 1;
    }
    if (volt_vm_load(box, S("imports.volt"), S(script)).error) {
        say_error(box, "box");
    } else {
        printf("box: loaded\n");
    }
    volt_vm_free(box);
    return 0;
}
