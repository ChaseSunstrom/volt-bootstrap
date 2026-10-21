// A C program running a Volt script that imports a C header and a C++ one (tests/embed.rs runs it
// with the compilers on PATH): their C and C++ is compiled for the script as it loads. In a sandbox
// clang compiles it to LLVM bitcode the JIT runs, so it reaches only what the host allows; a C++
// compiler that isn't clang is refused there (that half runs on Linux, given a third argument: the
// test passes one when $CC and $CXX are clang of the VM's LLVM). A later script using that one runs
// no compiler: its imports' code is already loaded. A second script whose C++ header does import
// std; builds no std module again, and a reload reads a header that changed, or one it includes.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "voltvm.h"

static volt_str S(const char *s) { return (volt_str){ (const uint8_t *)s, strlen(s) }; }

// what the header's C++ needs (allocation, its library's errors, exceptions and the typeinfo of
// std::exception, which the glue catches by; the glue's panic prints with fprintf and leaves a call
// C++ made through longjmp), as this platform names it
#define ALLOW_CXX "_Znwm", "_ZdlPvm", "_ZSt20__throw_length_errorPKc", "_ZSt28__throw_bad_array_new_lengthv", "_ZSt17__throw_bad_allocv", "__gxx_personality_v0", "__cxa_begin_catch", "__cxa_end_catch", "__cxa_rethrow", "_Unwind_Resume", "_ZSt9terminatev", "_ZSt17current_exceptionv", "_ZTVN10__cxxabiv117__class_type_infoE", "_ZTISt9exception", "_ZSt21__glibcxx_assert_failPKciS0_S0_", "fprintf", "stderr", "longjmp",

static void say_error(voltvm_volt_vm *vm, const char *what) {
    volt_str e = volt_vm_error(vm);
    printf("%s: %.*s\n", what, (int)e.len, (const char *)e.ptr);
}

// $CC and $CXX made `false`, which fails whatever it's given (a load running either fails), and put back
static char *cc_was, *cxx_was;
static void no_compilers(void) {
    cc_was = getenv("CC") ? strdup(getenv("CC")) : NULL;
    cxx_was = getenv("CXX") ? strdup(getenv("CXX")) : NULL;
    setenv("CC", "false", 1);
    setenv("CXX", "false", 1);
}
static void compilers_back(void) {
    if (cc_was) {
        setenv("CC", cc_was, 1);
    } else {
        unsetenv("CC");
    }
    if (cxx_was) {
        setenv("CXX", cxx_was, 1);
    } else {
        unsetenv("CXX");
    }
    free(cc_was);
    free(cxx_was);
}

// a script using imports.volt's sum, loaded with no compiler: its value, else -1
static long long user_of(voltvm_volt_vm *vm, const char *what) {
    no_compilers();
    int bad = volt_vm_load(vm, S("imports_user.volt"), S("export fn user() -> i64 { return imports::sum() + 1; }\n")).error;
    compilers_back();
    if (bad) {
        say_error(vm, what);
        return -1;
    }
    return ((long long (*)(void))volt_vm_find(vm, S("user")))();
}

// a script calling a static inline function of vmhost.h that imports.volt doesn't: its own C is
// built for it (with the compilers); its value, else -1
static long long thrice_of(voltvm_volt_vm *vm, const char *dir, const char *what) {
    char src[512];
    snprintf(src, sizeof src, "use { \"%s/vmhost.h\" } as h;\nexport fn thrice() -> i32 { return h::h_thrice(5); }\n", dir);
    if (volt_vm_load(vm, S("thrice.volt"), S(src)).error) {
        say_error(vm, what);
        return -1;
    }
    return ((int (*)(void))volt_vm_find(vm, S("thrice")))();
}

// a header the script imports changed on disk and the script loaded again: it reads the new one
static void header_changes(voltvm_volt_vm *vm) {
    char dir[] = "/tmp/voltvm-test-XXXXXX";
    if (!mkdtemp(dir)) {
        printf("reload: no temporary directory\n");
        return;
    }
    char h[64], src[256];
    snprintf(h, sizeof h, "%s/rh.h", dir);
    snprintf(src, sizeof src, "use { \"%s\" } as r;\nexport fn hv() -> i32 { return r::HV; }\n", h);
    for (int v = 1; v <= 2; v++) {
        FILE *f = fopen(h, "w");
        if (!f) {
            printf("reload: can't write %s\n", h);
            break;
        }
        fprintf(f, "#define HV %d\n", v * 10);
        fclose(f);
        if (volt_vm_load(vm, S("reload.volt"), S(src)).error) {
            say_error(vm, "reload");
            break;
        }
        printf("reload hv %d\n", ((int (*)(void))volt_vm_find(vm, S("hv")))());
    }
    // and when what changed is a header that one includes
    char in[64];
    snprintf(in, sizeof in, "%s/rh_in.h", dir);
    FILE *f = fopen(h, "w");
    if (f) {
        fprintf(f, "#include \"rh_in.h\"\n");
        fclose(f);
    }
    for (int v = 3; f && v <= 4; v++) {
        FILE *g = fopen(in, "w");
        if (!g) {
            printf("reload: can't write %s\n", in);
            break;
        }
        fprintf(g, "#define HV %d\n", v * 10);
        fclose(g);
        if (volt_vm_load(vm, S("reload.volt"), S(src)).error) {
            say_error(vm, "reload inner");
            break;
        }
        printf("reload inner hv %d\n", ((int (*)(void))volt_vm_find(vm, S("hv")))());
    }
    remove(in);
    remove(h);
    rmdir(dir);
}

// a compiler wrapper at path: it notes in log when it's given --precompile or the C++ library's std
// module source, then runs real (with PATH as it was)
static int wrapper(const char *path, const char *log, const char *real) {
    FILE *f = fopen(path, "w");
    if (!f) {
        return 0;
    }
    fprintf(f, "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --precompile|*/std.cc|*/std.cppm) echo \"$a\" >> '%s';; esac; done\nPATH='%s' exec %s \"$@\"\n", log, getenv("PATH"), real);
    fclose(f);
    return chmod(path, 0755) == 0;
}

// two scripts importing a C++ header that does import std;: the second one's load builds its own
// C++ (and libclang reads the header again), but the std module the first one's built is kept
static void std_kept(voltvm_volt_vm *vm, const char *dir) {
    char tmp[] = "/tmp/voltvm-test-XXXXXX";
    if (!mkdtemp(tmp)) {
        printf("std: no temporary directory\n");
        return;
    }
    char log[64], cxx[64], clangxx[64], path[4096], real[256];
    snprintf(log, sizeof log, "%s/log", tmp);
    snprintf(cxx, sizeof cxx, "%s/cxx", tmp);
    snprintf(clangxx, sizeof clangxx, "%s/clang++", tmp);
    snprintf(real, sizeof real, "%s", getenv("CXX") ? getenv("CXX") : "c++");
    char *path_was = strdup(getenv("PATH") ? getenv("PATH") : "/usr/bin:/bin");
    char *cxx_was = getenv("CXX") ? strdup(getenv("CXX")) : NULL;
    if (!wrapper(cxx, log, real) || !wrapper(clangxx, log, "clang++")) {
        printf("std: can't write the wrappers\n");
        return;
    }
    snprintf(path, sizeof path, "%s:%s", tmp, path_was);
    setenv("PATH", path, 1);
    setenv("CXX", cxx, 1);
    int got[2] = { -1, -1 };
    int again = 0;
    for (int i = 0; i < 2; i++) {
        char name[16], fn[16], src[512];
        snprintf(name, sizeof name, "std%d.volt", i + 1);
        snprintf(fn, sizeof fn, "std%d", i + 1);
        snprintf(src, sizeof src, "use { \"%s/vmstd.hpp\" } as s;\nexport fn %s() -> i32 { return s::vs::big(%d, 9); }\n", dir, fn, 3 + 10 * i);
        remove(log);
        if (volt_vm_load(vm, S(name), S(src)).error) {
            say_error(vm, name);
            break;
        }
        got[i] = ((int (*)(void))volt_vm_find(vm, S(fn)))();
        FILE *l = fopen(log, "r");
        if (l) {
            again = i == 1;
            fclose(l);
        }
    }
    setenv("PATH", path_was, 1);
    if (cxx_was) {
        setenv("CXX", cxx_was, 1);
    } else {
        unsetenv("CXX");
    }
    free(path_was);
    free(cxx_was);
    printf("std %d %d, %s\n", got[0], got[1], again ? "built again" : "kept");
    remove(log);
    remove(cxx);
    remove(clangxx);
    rmdir(tmp);
}

int main(int argc, char **argv) {
    volt_str std_dir = S(argv[1]);
    char script[2048];
    snprintf(script, sizeof script,
             "use { \"%s/vmhost.h\" } as h;\n"
             "use { \"%s/vmhost.hpp\" } as hp;\n"
             "public fn sum() -> i64 {\n"
             "    val a: i32 = 4;\n"
             "    var t = hp::vm::Tally::new();\n"
             "    t.add(10);\n"
             "    t.add(20);\n"
             "    val v: i32[3] = { 1, 2, 3 };\n"
             "    return @cast<i64>(h::h_twice(a) + h::H_MAX(a, 9) + hp::vm::total(v[0..3]) + t.value());\n"
             "}\n"
             "export fn run() -> i64 { return sum(); }\n",
             argv[2], argv[2]);
    voltvm_volt_vm *vm = volt_vm_new(std_dir);
    if (volt_vm_load(vm, S("imports.volt"), S(script)).error) {
        say_error(vm, "load");
        return 1;
    }
    printf("run %lld\n", ((long long (*)(void))volt_vm_find(vm, S("run")))());
    printf("user %lld\n", user_of(vm, "user"));
    printf("thrice %lld\n", thrice_of(vm, argv[2], "thrice"));
    std_kept(vm, argv[2]);
    header_changes(vm);
    volt_vm_free(vm);
#if defined(__linux__)
    if (argc < 4) {
        return 0;
    }
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
    printf("box imports user %lld\n", user_of(box, "box imports user"));
    printf("box thrice %lld\n", thrice_of(box, argv[2], "box thrice"));
    const char *c = "use { \"string.h\" } as c;\npublic fn four() -> usize { return c::strlen(\"four\"); }\nexport fn n() -> usize { return four(); }\n";
    if (volt_vm_load(box, S("box_c.volt"), S(c)).error) {
        say_error(box, "box_c");
        return 1;
    }
    printf("box strlen %zu\n", ((size_t (*)(void))volt_vm_find(box, S("n")))());
    // a script using that one, with no compiler: four is box_c's code, which its load built
    no_compilers();
    int bad = volt_vm_load(box, S("box_user.volt"), S("export fn eight() -> usize { return box_c::four() * 2; }\n")).error;
    compilers_back();
    if (bad) {
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
#endif
    return 0;
}
