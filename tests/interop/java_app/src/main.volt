use std::io;
// a Volt program calling Java through interop/java: static and instance methods, a constructor,
// strings both ways, the JDK's own classes, and an exception as an error

fn run(vm: java::vm&) -> java::java_error!void {
    val counter = try vm.find_class("Counter");
    std::println("add {}", try counter.call_static_int("add", "(II)I", 2, 40));
    std::println("{}", try counter.call_static_string("greet", "(Ljava/lang/String;Z)Ljava/lang/String;", "volt", true));
    val c = try counter.new_object("(Ljava/lang/String;I)V", "volt", 10);
    std::println("bump {} half {}", try c.call_int("bump", "(I)I", 5), try c.call_double("half", "()D"));
    std::println("object {} equal {}", try c.to_string(), try c.call_bool("equals", "(Ljava/lang/Object;)Z", copy c));
    val list = try (try vm.find_class("java/util/ArrayList")).new_object("()V");
    val added = try list.call_bool("add", "(Ljava/lang/Object;)Z", try vm.string("x"));
    std::println("list {} {}", added, try list.to_string());
    std::println("nanos {}", try (try vm.find_class("java/lang/System")).call_static_long("nanoTime", "()J") > 0);
    val math = try vm.find_class("java/lang/Math");
    std::println("max {} sqrt {}", try math.call_static_int("max", "(II)I", 3, 9), try math.call_static_double("sqrt", "(D)D", 2.25));
    val sb = try (try vm.find_class("java/lang/StringBuilder")).new_object("()V");
    val more = try sb.call_object("append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;", "built ");
    val again = try more.call_object("append", "(I)Ljava/lang/StringBuilder;", 42);
    std::println("{}", try again.to_string());
    val bad = counter.call_static_int("divide", "(II)I", 1, 0);
    if (bad.err) {
        std::println("caught {}", bad.err);
    }
    val missing = vm.find_class("NoSuchClass");
    std::println("missing {}", missing.err != null);
    val nothing = try counter.call_static_object("greet", "(Ljava/lang/String;Z)Ljava/lang/String;", "x", false);
    val none = try (try vm.find_class("java/lang/System")).call_static_object("getenv", "(Ljava/lang/String;)Ljava/lang/String;", "VOLT_NO_SUCH_VARIABLE");
    std::println("null {} {} {}", nothing.is_null(), none.is_null(), none.call_int("length", "()I").err);
}

fn main() -> !void {
    // the class path: the compiled classes next to the program (java/), or $JAVA_APP_CLASSES
    var vm = try java::start(std::process::env("JAVA_APP_CLASSES") ?? "java");
    try run(&vm);
}
