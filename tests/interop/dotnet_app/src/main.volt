use std::io;
// a Volt program calling C# through interop/dotnet: numbers, an array, strings both ways, the .NET
// library (JSON), a Volt callback, and an error code for an exception

extern "C" fn twice(x: i32) -> i32 {
    return x * 2;
}

fn run(rt: dotnet::runtime&, dll: str) -> dotnet::dotnet_error!void {
    val t = "Lib.Calc, Lib";
    val add = @cast<extern "C" fn(i32, i32) -> i32>(try rt.function(dll, t, "Add"));
    std::println("add {}", add(2, 40));
    val mean = @cast<extern "C" fn(f64*, i32) -> f64>(try rt.function(dll, t, "Mean"));
    var xs: f64[4] = { 1.0, 2.0, 3.0, 4.5 };
    std::println("mean {}", mean(&xs[0], 4));
    val greet = @cast<extern "C" fn(cstr) -> void*>(try rt.function(dll, t, "Greet"));
    std::println("{}", dotnet::take_string(greet("volt")));
    val json = @cast<extern "C" fn(i32, i32) -> void*>(try rt.function(dll, t, "ToJson"));
    std::println("json {}", dotnet::take_string(json(3, 4)));
    val apply = @cast<extern "C" fn(extern "C" fn(i32) -> i32, i32) -> i32>(try rt.function(dll, t, "Apply"));
    std::println("apply {}", apply(twice, 20));
    val divide = @cast<extern "C" fn(i32, i32, i32*) -> i32>(try rt.function(dll, t, "Divide"));
    var q: i32 = 0;
    std::println("divide {} {}", divide(7, 2, &q), q);
    std::println("divide by zero {}", divide(1, 0, &q));
    val missing = rt.function(dll, t, "Nope");
    std::println("missing {}", missing.err != null);
}

fn main() -> !void {
    // the built library: lib/bin (dotnet build -o lib/bin), or $DOTNET_APP_LIB
    val dir = std::process::env("DOTNET_APP_LIB") ?? "lib/bin";
    var rt = try dotnet::start(std::fmt::format("{}/Lib.runtimeconfig.json", dir).as_str());
    try run(&rt, std::fmt::format("{}/Lib.dll", dir).as_str());
}
