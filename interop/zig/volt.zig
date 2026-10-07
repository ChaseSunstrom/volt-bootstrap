//! Use a Volt package from Zig: in build.zig,
//!
//!     const volt = @import("volt.zig");
//!     volt.addPackage(b, exe, "mathlib", "volt/mathlib");
//!
//! and in the code, `const mathlib = @import("mathlib");`. It runs voltc lib NAME --static and
//! voltc bindings NAME --lang zig, links the one and makes the other module NAME. voltc comes from
//! $VOLTC, else the PATH; std from $VOLT_STD, else voltc's own.
const std = @import("std");

pub fn addPackage(b: *std.Build, compile: *std.Build.Step.Compile, name: []const u8, dir: []const u8) void {
    const voltc = b.graph.environ_map.get("VOLTC") orelse "voltc";
    // --pkg NAME=DIR: an absolute DIR as it is, a relative one from the build root
    const lib = b.addSystemCommand(&.{ voltc, "lib", name, "--pkg" });
    const bindings = b.addSystemCommand(&.{ voltc, "bindings", name, "--pkg" });
    if (std.fs.path.isAbsolute(dir)) {
        lib.addArg(b.fmt("{s}={s}", .{ name, dir }));
        bindings.addArg(b.fmt("{s}={s}", .{ name, dir }));
    } else {
        lib.addPrefixedDirectoryArg(b.fmt("{s}=", .{name}), b.path(dir));
        bindings.addPrefixedDirectoryArg(b.fmt("{s}=", .{name}), b.path(dir));
    }
    bindings.addArgs(&.{ "--lang", "zig" });
    if (b.graph.environ_map.get("VOLT_STD")) |s| {
        lib.addArgs(&.{ "--std", s });
        bindings.addArgs(&.{ "--std", s });
    }
    lib.addArgs(&.{ "--static", "-o" });
    const archive = lib.addOutputFileArg(b.fmt("lib{s}.a", .{name}));
    bindings.addArg("-o");
    const source = bindings.addOutputFileArg(b.fmt("{s}.zig", .{name}));
    // voltc runs every build (it's quick, and Zig doesn't know which .volt files it reads)
    lib.has_side_effects = true;
    bindings.has_side_effects = true;
    compile.root_module.addImport(name, b.createModule(.{ .root_source_file = source }));
    compile.root_module.addObjectFile(archive);
    compile.root_module.link_libc = true;
    compile.root_module.linkSystemLibrary("m", .{});
    compile.root_module.linkSystemLibrary("pthread", .{});
}
