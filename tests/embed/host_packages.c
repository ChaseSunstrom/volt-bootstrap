// A C program whose scripts use earlier scripts as packages (tests/embed.rs runs it): a script is
// the package its file names, so a later one calls util::make. In a plain VM and in a sandbox
// (whose allowances aren't needed for that), reloading a script others use is refused, reloading
// one nobody uses replaces it, a load that fails leaves no package, and a file whose name can't be
// a package's is refused.
#include <stdio.h>
#include <string.h>
#include "voltvm.h"

static volt_str S(const char *s) { return (volt_str){ (const uint8_t *)s, strlen(s) }; }

// what went wrong, its first line
static void say_error(voltvm_volt_vm *vm, const char *what) {
    volt_str e = volt_vm_error(vm);
    const char *nl = memchr(e.ptr, '\n', e.len);
    printf("%s: %.*s\n", what, (int)(nl ? nl - (const char *)e.ptr : (long)e.len), (const char *)e.ptr);
}

static const char *UTIL =
    "public struct point {\n"
    "    x: i32;\n"
    "    y: i32;\n"
    "}\n"
    "\n"
    "public var made: i32 = 0;\n"
    "\n"
    "public fn make(x: i32, y: i32) -> point {\n"
    "    made += 1;\n"
    "    return { x: x, y: y };\n"
    "}\n"
    "\n"
    "<T: type>\n"
    "public fn largest(a: T, b: T) -> T {\n"
    "    if (a > b) {\n"
    "        return a;\n"
    "    }\n"
    "    return b;\n"
    "}\n";

static const char *MAIN =
    "export fn run() -> i32 {\n"
    "    val p: util::point = util::make(3, 4);\n"
    "    val q = util::make(1, 2);\n"
    "    return p.x * 100 + util::largest<i32>(p.y, 9) * 10 + util::made + q.y - q.x;\n"
    "}\n";

static const char *SHAPES =
    "public trait shape {\n"
    "    fn area(this) -> i32;\n"
    "}\n"
    "\n"
    "public struct sq {\n"
    "    n: i32;\n"
    "}\n"
    "\n"
    "attach shape -> sq {\n"
    "    fn area(this) -> i32 { return this.n * this.n; }\n"
    "}\n"
    "\n"
    "public var held: shape? = null;\n"
    "\n"
    "public fn held_area() -> i32 {\n"
    "    val h = held ?? return 0;\n"
    "    return h.area();\n"
    "}\n";

static const char *HOLDERS =
    "public trait boxy {\n"
    "    fn v(this) -> i32;\n"
    "}\n"
    "public trait fieldy {\n"
    "    fn v(this) -> i32;\n"
    "}\n"
    "struct one { n: i32; }\n"
    "attach boxy -> one {\n"
    "    fn v(this) -> i32 { return this.n; }\n"
    "}\n"
    "attach fieldy -> one {\n"
    "    fn v(this) -> i32 { return this.n; }\n"
    "}\n"
    "public var two: boxy?[2] = { null, null };\n"
    "public struct slot {\n"
    "    f: fieldy?;\n"
    "    n: i32;\n"
    "}\n"
    "public var held_slot: slot = { f: null, n: 0 };\n";

int main(int argc, char **argv) {
    volt_str std_dir = S(argv[1]);
    for (int box = 0; box < 2; box++) {
        const char *kind = box ? "box" : "vm";
        voltvm_volt_vm *vm = volt_vm_new(std_dir);
        if (box && volt_vm_allow(vm, S("nothing_needed")).error) {
            say_error(vm, "allow");
            return 1;
        }
        if (volt_vm_load(vm, S("util.volt"), S(UTIL)).error) {
            say_error(vm, "util");
            return 1;
        }
        if (volt_vm_load(vm, S("main_script.volt"), S(MAIN)).error) {
            say_error(vm, "main_script");
            return 1;
        }
        printf("%s run %d\n", kind, ((int (*)(void))volt_vm_find(vm, S("run")))());
        if (volt_vm_load(vm, S("util.volt"), S("public fn make() -> i32 { return 0; }\n")).error) {
            say_error(vm, "reload util");
        } else {
            printf("reload util: loaded\n");
        }
        // util is still the first one
        printf("%s run %d\n", kind, ((int (*)(void))volt_vm_find(vm, S("run")))());
        if (volt_vm_load(vm, S("leaf.volt"), S("export fn leaf() -> i32 { return 1; }\n")).error) {
            say_error(vm, "leaf");
            return 1;
        }
        printf("%s leaf %d\n", kind, ((int (*)(void))volt_vm_find(vm, S("leaf")))());
        if (volt_vm_load(vm, S("leaf.volt"), S("export fn leaf() -> i32 { return 2; }\n")).error) {
            say_error(vm, "leaf again");
            return 1;
        }
        printf("%s leaf %d\n", kind, ((int (*)(void))volt_vm_find(vm, S("leaf")))());
        volt_vm_free(vm);
    }
    voltvm_volt_vm *vm = volt_vm_new(std_dir);
    if (volt_vm_load(vm, S("broken.volt"), S("public fn f() -> i32 { return \"no\"; }\n")).error) {
        say_error(vm, "broken");
    }
    if (volt_vm_load(vm, S("user.volt"), S("export fn g() -> i32 { return broken::f(); }\n")).error) {
        say_error(vm, "user");
    } else {
        printf("user: loaded\n");
    }
    // a load whose code doesn't link (a symbol nowhere) leaves nothing either: loaded again, fixed
    if (volt_vm_load(vm, S("missing.volt"), S("extern \"C\" fn not_a_function_anywhere() -> i32;\nexport fn m() -> i32 { return not_a_function_anywhere(); }\n")).error) {
        say_error(vm, "missing");
    }
    if (volt_vm_load(vm, S("missing.volt"), S("export fn m() -> i32 { return 5; }\n")).error) {
        say_error(vm, "missing again");
        return 1;
    }
    printf("m %d\n", ((int (*)(void))volt_vm_find(vm, S("m")))());
    // loaded again, it doesn't link: the old one made way for it, so neither is there
    if (volt_vm_load(vm, S("missing.volt"), S("extern \"C\" fn still_not_anywhere() -> i32;\nexport fn m() -> i32 { return still_not_anywhere(); }\n")).error) {
        say_error(vm, "missing replaced");
    }
    printf("m found %d\n", volt_vm_find(vm, S("m")) != 0);
    const char *names[] = { "my-util.volt", "std.volt", "dir/fn.volt" };
    for (int i = 0; i < 3; i++) {
        if (volt_vm_load(vm, S(names[i]), S("export fn z() -> i32 { return 0; }\n")).error) {
            say_error(vm, names[i]);
        } else {
            printf("%s: loaded\n", names[i]);
        }
    }
    // two files of one name: the second would be the first's package
    if (volt_vm_load(vm, S("a/init.volt"), S("export fn a_init() -> i32 { return 1; }\n")).error) {
        say_error(vm, "a/init");
        return 1;
    }
    if (volt_vm_load(vm, S("b/init.volt"), S("export fn b_init() -> i32 { return 2; }\n")).error) {
        say_error(vm, "b/init");
    }
    printf("a_init %d\n", ((int (*)(void))volt_vm_find(vm, S("a_init")))());
    // a path's directories aren't the package's name
    if (volt_vm_load(vm, S("scripts/helper.volt"), S("public fn seven() -> i32 { return 7; }\n")).error ||
        volt_vm_load(vm, S("scripts/use_helper.volt"), S("export fn h() -> i32 { return helper::seven(); }\n")).error) {
        say_error(vm, "helper");
        return 1;
    }
    printf("h %d\n", ((int (*)(void))volt_vm_find(vm, S("h")))());
    // a global holding a trait's union was laid out, and its script's code built, for the types
    // attached so far: a later script attaching the trait to another type is refused, one using the
    // global loads
    if (volt_vm_load(vm, S("shapes.volt"), S(SHAPES)).error) {
        say_error(vm, "shapes");
        return 1;
    }
    if (volt_vm_load(vm, S("wide.volt"), S("struct wide { a: i64; b: i64; c: i64; }\nattach shapes::shape -> wide {\n    fn area(this) -> i32 { return 1; }\n}\nexport fn w() -> i32 { return 0; }\n")).error) {
        say_error(vm, "wide");
    } else {
        printf("wide: loaded\n");
    }
    if (volt_vm_load(vm, S("held_user.volt"), S("export fn set_held() -> i32 {\n    val s: shapes::sq = { n: 6 };\n    shapes::held = s;\n    return shapes::held_area();\n}\n")).error) {
        say_error(vm, "held_user");
        return 1;
    }
    printf("held %d\n", ((int (*)(void))volt_vm_find(vm, S("set_held")))());
    // attaching a trait no global holds loads
    if (volt_vm_load(vm, S("named.volt"), S("public trait named {\n    fn len(this) -> i32;\n}\nstruct tag { n: i32; }\nattach named -> tag {\n    fn len(this) -> i32 { return this.n; }\n}\nexport fn named_len() -> i32 {\n    val t: tag = { n: 3 };\n    return t.len();\n}\n")).error) {
        say_error(vm, "named");
        return 1;
    }
    printf("named %d\n", ((int (*)(void))volt_vm_find(vm, S("named_len")))());
    // a union in an array, or in a struct's field, is held too
    if (volt_vm_load(vm, S("holders.volt"), S(HOLDERS)).error) {
        say_error(vm, "holders");
        return 1;
    }
    const char *attach[] = { "boxy", "fieldy" };
    for (int i = 0; i < 2; i++) {
        char src[256];
        snprintf(src, sizeof src, "struct more { n: i64; }\nattach holders::%s -> more {\n    fn v(this) -> i32 { return 0; }\n}\nexport fn more_%s() -> i32 { return 0; }\n", attach[i], attach[i]);
        if (volt_vm_load(vm, S("more.volt"), S(src)).error) {
            say_error(vm, attach[i]);
        } else {
            printf("%s: loaded\n", attach[i]);
        }
    }
    volt_vm_free(vm);
    return 0;
}
