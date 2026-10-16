// A C program running a Volt script that imports a C header and a C++ one (tests/embed.rs runs it
// with the compilers on PATH): their C and C++ is compiled for the script as it loads. In a sandbox
// clang compiles it to LLVM bitcode the JIT runs, so it reaches only what the host allows; a C++
// compiler that isn't clang is refused there.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "voltvm.h"

static volt_str S(const char *s) { return (volt_str){ (const uint8_t *)s, strlen(s) }; }

// what the header's C++ needs (allocation, its library's errors, exceptions; the glue's panic prints
// with fprintf and leaves a call C++ made through longjmp), as this platform names it
#if defined(__linux__)
#define ALLOW_CXX "_Znwm", "_ZdlPvm", "_ZSt20__throw_length_errorPKc", "_ZSt28__throw_bad_array_new_lengthv", "_ZSt17__throw_bad_allocv", "__gxx_personality_v0", "__cxa_begin_catch", "__cxa_end_catch", "__cxa_rethrow", "_Unwind_Resume", "_ZSt9terminatev", "_ZSt17current_exceptionv", "_ZTVN10__cxxabiv117__class_type_infoE", "_ZSt21__glibcxx_assert_failPKciS0_S0_", "fprintf", "stderr", "longjmp",
#else
#define ALLOW_CXX
#endif

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
    // the sandbox: strlen and what the C++ needs (its library's allocation and errors), no more
    voltvm_volt_vm *box = volt_vm_new(std_dir);
    const char *allow[] = { "strlen", ALLOW_CXX NULL };
    for (int i = 0; allow[i]; i++) {
        if (volt_vm_allow(box, S(allow[i])).error) {
            say_error(box, "allow");
            return 1;
        }
    }
    if (volt_vm_load(box, S("imports.volt"), S(script)).error) {
        say_error(box, "box");
        return 1;
    }
    printf("box run %lld\n", ((long long (*)(void))volt_vm_find(box, S("run")))());
    const char *c = "use { \"string.h\" } as c;\npublic fn four() -> usize { return c::strlen(\"four\"); }\nexport fn n() -> usize { return four(); }\n";
    if (volt_vm_load(box, S("box_c.volt"), S(c)).error) {
        say_error(box, "box_c");
        return 1;
    }
    printf("box strlen %zu\n", ((size_t (*)(void))volt_vm_find(box, S("n")))());
    // a script using that one (its import's code is its own, so the two don't meet)
    if (volt_vm_load(box, S("box_user.volt"), S("export fn eight() -> usize { return box_c::four() * 2; }\n")).error) {
        say_error(box, "box_user");
        return 1;
    }
    printf("box user %zu\n", ((size_t (*)(void))volt_vm_find(box, S("eight")))());
    const char *pid = "use { \"unistd.h\" } as u;\nexport fn pid() -> i32 { return u::getpid(); }\n";
    if (volt_vm_load(box, S("box_pid.volt"), S(pid)).error) {
        say_error(box, "box_pid");
    } else {
        printf("box_pid: loaded\n");
    }
    // gcc can't write LLVM bitcode
    setenv("CXX", "g++", 1);
    char cpp[512];
    snprintf(cpp, sizeof cpp, "use { \"%s/vmhost.hpp\" } as hp;\nexport fn three() -> i32 { val v: i32[2] = { 1, 2 }; return hp::vm::total(v[0..2]); }\n", argv[2]);
    if (volt_vm_load(box, S("box_gxx.volt"), S(cpp)).error) {
        say_error(box, "box_gxx");
    } else {
        printf("box_gxx: loaded\n");
    }
    volt_vm_free(box);
    return 0;
}
