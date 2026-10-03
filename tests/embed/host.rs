// Rust running Volt through libvoltvm's generated module (tests/embed.rs compiles it with rustc): a
// host function, an export fn called through its address, and a compile error as an Err
#[path = "voltvm.rs"]
#[allow(non_camel_case_types, dead_code)]
mod voltvm;

extern "C" fn cube(x: i64) -> i64 {
    x * x * x
}

fn main() {
    let std_dir = std::env::args().nth(1).unwrap();
    let vm = voltvm::volt_vm::new(&std_dir);
    vm.define("host_cube", cube as extern "C" fn(i64) -> i64 as usize).unwrap();
    vm.load("cubes.volt", "extern \"C\" fn host_cube(x: i64) -> i64;\nexport fn cubes(n: i64) -> i64 {\n    var total: i64 = 0;\n    for (i) in 1..n + 1 {\n        total += host_cube(i);\n    }\n    return total;\n}\n").unwrap();
    let cubes: extern "C" fn(i64) -> i64 = unsafe { std::mem::transmute(vm.find("cubes")) };
    println!("cubes {}", cubes(4));
    match vm.load("bad.volt", "export fn f() -> bool { return 1 + ; }\n") {
        Err(e) => println!("error {} {}", e.name(), vm.error().lines().next().unwrap_or("")),
        Ok(()) => println!("loaded"),
    }
}
