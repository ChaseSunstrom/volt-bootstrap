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

fn unit(out: std::vec<u8>&, u: u32) -> void {
    out.push(@cast<u8>(u & 0xFF)) catch @panic("out of memory");
    out.push(@cast<u8>(u >> 8)) catch @panic("out of memory");
}

// s as hostfxr's char_t, ending in a zero: UTF-16 on Windows (wchar_t), UTF-8 elsewhere
fn char_t(s: str) -> std::vec<u8> {
    var out: std::vec<u8> = {};
    comptime if (@cfg("os", "windows")) {
        var i: usize = 0;
        while (i < s.len) {
            val b = @cast<u32>(s[i]);
            var c = b;
            var n: usize = 1;
            if (b >= 0xF0) {
                c = b & 0x07;
                n = 4;
            } else if (b >= 0xE0) {
                c = b & 0x0F;
                n = 3;
            } else if (b >= 0xC0) {
                c = b & 0x1F;
                n = 2;
            }
            for (k) in 1..n {
                if (i + k < s.len) {
                    c = (c << 6) | (@cast<u32>(s[i + k]) & 0x3F);
                }
            }
            i += n;
            if (c >= 0x10000) {
                unit(&out, 0xD800 | ((c - 0x10000) >> 10));
                unit(&out, 0xDC00 | ((c - 0x10000) & 0x3FF));
            } else {
                unit(&out, c);
            }
        }
        unit(&out, 0);
    } else {
        for (i) in 0..s.len {
            out.push(s[i]) catch @panic("out of memory");
        }
        out.push(0) catch @panic("out of memory");
    }
    return out;
}

// hostfxr_initialize_parameters: its size, the host's path (none) and .NET's root ($DOTNET_ROOT
// when it's set: a hostfxr the system finds first, PowerShell's on Windows, would guess another)
struct fxr_params {
    size: usize;
    host_path: void* = null;
    dotnet_root: void* = null;
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
    val path = char_t(runtimeconfig);
    val root = char_t(std::process::env("DOTNET_ROOT") ?? "");
    var params: fxr_params = { size: @sizeof(fxr_params) };
    if (std::process::env("DOTNET_ROOT") != null) {
        params.dotnet_root = @cast<void*>(root.items().ptr);
    }
    var out: runtime = {};
    try status(std::fmt::format("starting .NET with {}", runtimeconfig).as_str(), hostfxr_initialize_for_runtime_config(@cast<cstr>(path.items().ptr), @cast<void*>(&params), &out.handle));
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
    val a = char_t(assembly);
    val t = char_t(type_name);
    val m = char_t(method);
    // load_assembly_and_get_function_pointer: assembly path, "Namespace.Type, Assembly", method,
    // delegate type, reserved, the function
    val load = @cast<extern "C" fn(cstr, cstr, cstr, void*, void*, void**) -> i32>(this.load);
    var f: void* = null;
    // UNMANAGEDCALLERSONLY_METHOD: (const char_t*)-1
    val rc = load(@cast<cstr>(a.items().ptr), @cast<cstr>(t.items().ptr), @cast<cstr>(m.items().ptr), @cast<void*>(~@cast<usize>(0)), null, &f);
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
