// A C program running Volt through libvoltvm (tests/embed.rs builds and runs it with no C compiler
// on PATH): export fns called with values, a host function, globals, two scripts in one VM, compile
// errors as text, release mode, and a sandbox that refuses what the host didn't allow.
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include "voltvm.h"

static volt_str S(const char *s) { return (volt_str){ (const uint8_t *)s, strlen(s) }; }

static void say_error(voltvm_volt_vm *vm, const char *what) {
    volt_str e = volt_vm_error(vm);
    printf("%s: %.*s\n", what, (int)e.len, (const char *)e.ptr);
}

// a host function scripts call
static long long host_twice(long long x) { return 2 * x; }

int main(int argc, char **argv) {
    volt_str std_dir = S(argv[1]);
    voltvm_volt_vm *vm = volt_vm_new(std_dir);
    if (volt_vm_define(vm, S("host_twice"), (size_t)host_twice).error) {
        say_error(vm, "define");
        return 1;
    }
    const char *script =
        "use std::io;\n"
        "extern \"C\" fn host_twice(x: i64) -> i64;\n"
        "val GREETING = \"hello from volt\";\n"
        "var calls: i64 = 0;\n"
        "export fn add(a: i64, b: i64) -> i64 {\n"
        "    calls += 1;\n"
        "    return host_twice(a) + b;\n"
        "}\n"
        "export fn count() -> i64 { return calls; }\n"
        "export fn hello() -> void { std::println(\"{} {}\", GREETING, calls); }\n";
    if (volt_vm_load(vm, S("script.volt"), S(script)).error) {
        say_error(vm, "load");
        return 1;
    }
    long long (*add)(long long, long long) = (long long (*)(long long, long long))volt_vm_find(vm, S("add"));
    long long (*count)(void) = (long long (*)(void))volt_vm_find(vm, S("count"));
    void (*hello)(void) = (void (*)(void))volt_vm_find(vm, S("hello"));
    printf("add %lld\n", add(20, 2));
    add(1, 1);
    printf("count %lld\n", count());
    fflush(stdout);
    hello();
    // a second script with std of its own, in the same VM
    if (volt_vm_load(vm, S("second.volt"), S("use std::io;\nexport fn shout() -> void { std::println(\"second\"); }\n")).error) {
        say_error(vm, "second");
        return 1;
    }
    ((void (*)(void))volt_vm_find(vm, S("shout")))();
    printf("missing %zu\n", volt_vm_find(vm, S("nothing_here")));
    if (volt_vm_load(vm, S("bad.volt"), S("export fn oops() -> i32 { return \"no\"; }\n")).error) {
        volt_str e = volt_vm_error(vm);
        const char *nl = memchr(e.ptr, '\n', e.len);
        printf("bad: %.*s\n", (int)(nl ? nl - (const char *)e.ptr : (long)e.len), (const char *)e.ptr);
    }
    volt_vm_free(vm);

    // release: optimized, and overflow wraps instead of stopping the program
    voltvm_volt_vm *fast = volt_vm_new(S(""));
    volt_vm_release(fast, true);
    if (volt_vm_load(fast, S("fast.volt"), S("export fn next(x: i32) -> i32 { return x + 1; }\n")).error) {
        say_error(fast, "fast");
        return 1;
    }
    printf("next %d\n", ((int (*)(int))volt_vm_find(fast, S("next")))(INT_MAX));
    volt_vm_free(fast);

    // a sandbox: std's printing, strlen because the host allows it, and nothing else of the C library
    voltvm_volt_vm *box = volt_vm_new(std_dir);
    volt_vm_allow(box, S("strlen"));
    const char *ok =
        "use std::io;\n"
        "extern \"C\" fn strlen(s: cstr) -> usize;\n"
        "export fn run() -> void { std::println(\"sandboxed {}\", strlen(\"four\")); }\n";
    if (volt_vm_load(box, S("ok.volt"), S(ok)).error) {
        say_error(box, "ok");
        return 1;
    }
    ((void (*)(void))volt_vm_find(box, S("run")))();
    fflush(stdout);
    const char *escape = "extern \"C\" fn getpid() -> i32;\nexport fn pid() -> i32 { return getpid(); }\n";
    if (volt_vm_load(box, S("escape.volt"), S(escape)).error) {
        say_error(box, "escape");
    } else {
        printf("escape: loaded\n");
    }
    // nor the rest of what libvoltvm exports: a second VM, with no sandbox, would be a way out
    const char *inner = "extern \"C\" fn volt_vm_new(std_dir: str) -> void*;\nexport fn make() -> void* { return volt_vm_new(\"\"); }\n";
    if (volt_vm_load(box, S("inner.volt"), S(inner)).error) {
        say_error(box, "inner");
    } else {
        printf("inner: loaded\n");
    }
    // and its allowances are fixed once it has loaded something
    if (volt_vm_allow(box, S("getpid")).error) {
        say_error(box, "allow");
    }
    volt_vm_free(box);
    return 0;
}
