// dotnet: call .NET from Volt through hostfxr. start(runtimeconfig) starts the .NET runtime in this
// process for a library built with <EnableDynamicLoading>true</EnableDynamicLoading> (its
// NAME.runtimeconfig.json); function(assembly, type, method) loads a static [UnmanagedCallersOnly]
// method and gives its address, which @cast makes a Volt function:
//
//     val add = @cast<extern "C" fn(i32, i32) -> i32>(try rt.function("Lib.dll", "Lib.Calc, Lib", "Add"));
//
// The runtime starts once per process; it stays loaded until the process ends.

public error dotnet_error {
    FAILED: std::string,
}

public extern "C" fn hostfxr_initialize_for_runtime_config(config: cstr, params: void*, handle: void**) -> i32;
public extern "C" fn hostfxr_get_runtime_delegate(handle: void*, kind: i32, out: void**) -> i32;
public extern "C" fn hostfxr_close(handle: void*) -> i32;
public extern "C" fn free(p: void*) -> void;
public extern "C" fn strlen(s: cstr) -> usize;

// hostfxr's delegate kinds: hdt_load_assembly_and_get_function_pointer
public val LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER: i32 = 5;

public struct runtime {
    handle: void* = null;
    load: void* = null;
}

// hostfxr's codes: 0 to 2 are success, the others are errors (0x80008083 and so on)
public fn status(what: str, rc: i32) -> dotnet_error!void {
    if (rc >= 0 && rc <= 2) {
        return;
    }
    return dotnet_error::FAILED(std::fmt::format("{} failed: 0x{:x}", what, @cast<u32>(rc)));
}

// starts the runtime a library's NAME.runtimeconfig.json asks for
public fn start(runtimeconfig: str) -> dotnet_error!runtime {
    var path = std::string::from(runtimeconfig);
    var out: runtime = {};
    try status(std::fmt::format("starting .NET with {}", runtimeconfig).as_str(), hostfxr_initialize_for_runtime_config(path.c_str(), null, &out.handle));
    try status("hostfxr_get_runtime_delegate", hostfxr_get_runtime_delegate(out.handle, LOAD_ASSEMBLY_AND_GET_FUNCTION_POINTER, &out.load));
    return out;
}

public attach fn delete(this: runtime&) -> void {
    if (this.handle != null) {
        hostfxr_close(this.handle);
        this.handle = null;
    }
}

// the address of a static [UnmanagedCallersOnly] method: the assembly's path, its type as
// "Namespace.Type, Assembly", and the method's name
public attach fn function(this: runtime&, assembly: str, type_name: str, method: str) -> dotnet_error!(void*) {
    var a = std::string::from(assembly);
    var t = std::string::from(type_name);
    var m = std::string::from(method);
    // load_assembly_and_get_function_pointer: assembly path, "Namespace.Type, Assembly", method,
    // delegate type, reserved, the function
    val load = @cast<extern "C" fn(cstr, cstr, cstr, void*, void*, void**) -> i32>(this.load);
    var f: void* = null;
    // UNMANAGEDCALLERSONLY_METHOD: (const char_t*)-1
    val rc = load(a.c_str(), t.c_str(), m.c_str(), @cast<void*>(~@cast<usize>(0)), null, &f);
    try status(std::fmt::format("loading {}.{} from {}", type_name, method, assembly).as_str(), rc);
    return f;
}

// the text of a string .NET returned from Marshal.StringToCoTaskMemUTF8, which it frees
public fn take_string(p: void*) -> std::string {
    if (p == null) {
        return std::string::from("");
    }
    val out = std::string::from(@cast<str>(@slice(@cast<u8*>(p), strlen(@cast<cstr>(p)))));
    free(p);
    return out;
}
