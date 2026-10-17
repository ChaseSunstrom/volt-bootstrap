// Volt embedded in another program, as Lua is: voltc/embed builds the compiler into libvoltvm.so,
// whose interface is volt_vm. A VM compiles Volt source text in memory with this compiler and runs
// it through LLVM's ORC JIT, so no C compiler runs (but for a script's C and C++ imports). A
// script's code calls the runtime the library
// itself exports (an LLVM-built shared library's runtime functions are weak and visible) and the
// process's C library; in a sandbox only the symbols the host allows, and what the runtime needs (not
// the rest of what this library exports: its header pointers, the compiler's helpers, volt_vm). The
// host looks up a script's export fns by name and calls them through the C ABI, and gives scripts
// functions of its own, which they declare `extern "C"`. Each script is the package its file names:
// a later one reaches an earlier one's public names as util::f.
use std::io;

// why a VM call failed; volt_vm_error says what happened
error vm_error {
    COMPILE, // the source didn't compile (the error has the diagnostics)
    JIT,     // LLVM couldn't add it: a symbol defined twice, one that isn't there or isn't allowed
}

// a Volt VM: the JIT, where scripts' std comes from, and what they may reach. Scripts and host
// functions live in a JITDylib of their own: LLJIT's main one reaches every symbol of the process,
// which a sandbox can't take back
export struct volt_vm {
    jit: llvm::LLVMOrcOpaqueLLJIT* = null;
    jd: llvm::LLVMOrcOpaqueJITDylib* = null;
    std_dir: std::string = {};
    release: bool = false;            // optimize scripts and wrap on overflow (else debug checks)
    sandbox: bool = false;            // only allowed symbols (and the runtime's) from the process
    allowed: std::vec<std::string> = {};
    message: std::string = {};        // the last failure's message
    session: std::string = {};        // what LLVM reported while compiling (a symbol not found)
    loads: u32 = 0;
    searching: bool = false;          // the process's symbols are reachable (set at the first load)
    runtime: std::map<str, bool> = {}; // the runtime's names, for a sandbox (runtime_names)
    scripts: std::vec<vm_script> = {}; // what's loaded, each a package to the scripts after it
}

// a loaded script: the package its file names, its source (a later script is checked with it, and
// compiled against what the JIT has of it) and the JIT's tracker of its code
struct vm_script {
    pkg: std::string = {};
    name: std::string = {};
    source: std::string = {};
    rt: llvm::LLVMOrcOpaqueResourceTracker* = null;
    native: bool = false; // its imports' code is a library the VM loaded (which stays)
}

// a VM whose scripts see the std package in std_dir ("" for none: scripts see only the host's
// functions)
export fn volt_vm_new(std_dir: str) -> volt_vm {
    var v: volt_vm = { std_dir: std::string::from(std_dir) };
    // the host's target, for the JIT
    comptime if (@cfg("arch", "aarch64")) {
        llvm::LLVMInitializeAArch64TargetInfo();
        llvm::LLVMInitializeAArch64Target();
        llvm::LLVMInitializeAArch64TargetMC();
        llvm::LLVMInitializeAArch64AsmPrinter();
    } else {
        llvm::LLVMInitializeX86TargetInfo();
        llvm::LLVMInitializeX86Target();
        llvm::LLVMInitializeX86TargetMC();
        llvm::LLVMInitializeX86AsmPrinter();
    }
    var j: llvm::LLVMOrcOpaqueLLJIT* = null;
    val e = llvm::LLVMOrcCreateLLJIT(&j, null);
    if (e != null) {
        v.message = jit_error(e);
        return v;
    }
    v.jit = j;
    v.jd = llvm::LLVMOrcExecutionSessionCreateBareJITDylib(llvm::LLVMOrcLLJITGetExecutionSession(j), "volt scripts");
    return v;
}

// the VM is in its final place (a handle, or a variable that won't move): LLVM's reports during
// compilation go into its message rather than to stderr
attach fn listen(this: volt_vm&) -> void {
    val j = this.jit ?? return;
    llvm::LLVMOrcExecutionSessionSetErrorReporter(llvm::LLVMOrcLLJITGetExecutionSession(j), vm_session_error, @cast<void*>(&*this));
}

// scripts are optimized, and wrap on overflow instead of stopping (as voltc --release builds)
export fn volt_vm_release(v: volt_vm&, on: bool) -> void {
    v.release = on;
}

// sandbox: from the process, scripts reach only the C symbols allowed this way (and what the
// runtime needs); the first call turns it on. After the first load it's too late: an error
export fn volt_vm_allow(v: volt_vm&, symbol: str) -> vm_error!void {
    if (v.searching && !v.sandbox) {
        return v.fail(vm_error::JIT, "this VM has loaded a script with the process's symbols in reach: make it a sandbox before its first load");
    }
    if (v.searching) {
        return v.fail(vm_error::JIT, "a sandbox's allowances are fixed at its first load");
    }
    v.sandbox = true;
    put(&v.allowed, std::string::from(symbol));
    return;
}

// a host function: a script declares `extern "C" fn name(...) -> R;` with the same C signature, and
// calls the function at `address`
export fn volt_vm_define(v: volt_vm&, name: str, address: usize) -> vm_error!void {
    val j = v.jit ?? return v.no_jit();
    var n = S(name);
    var pair: llvm::LLVMOrcCSymbolMapPair = {};
    pair.Name = llvm::LLVMOrcLLJITMangleAndIntern(j, n.c_str());
    pair.Sym.Address = @cast<u64>(address);
    pair.Sym.Flags.GenericFlags = @cast<u8>(llvm::LLVMJITSymbolGenericFlagsExported | llvm::LLVMJITSymbolGenericFlagsCallable);
    val mu = llvm::LLVMOrcAbsoluteSymbols(&pair, 1);
    val e = llvm::LLVMOrcJITDylibDefine(v.jd, mu);
    if (e != null) {
        return v.fail(vm_error::JIT, jit_error(e).as_str());
    }
    return;
}

// compile `source` (its errors name it `name`) and add it to the VM: its export fns can be found,
// and its globals are set up. It's the package its file names (util.volt is util: a later script
// calls util::f); loading that name again replaces it, unless a script loaded since uses it. Scripts
// loaded later can't redefine an export fn
export fn volt_vm_load(v: volt_vm&, name: str, source: str) -> vm_error!void {
    val j = v.jit ?? return v.no_jit();
    val pkg = S(script_pkg(name));
    if (pkg.as_str() == "std") {
        return v.fail(vm_error::COMPILE, fmt2("can't load {}: a script is the package its file names, and {} is std's", S(name), copy pkg).as_str());
    }
    if (!can_name_pkg(pkg.as_str())) {
        return v.fail(vm_error::COMPILE, fmt2("can't load {}: a script is the package its file names, and {} can't name a package", S(name), copy pkg).as_str());
    }
    // the script it replaces, which nothing loaded since may use
    var old = v.scripts.len;
    var users = S("");
    var n_users: usize = 0;
    for (i) in 0..v.scripts.len {
        val sc = v.scripts.at(i);
        if (sc.pkg.as_str() == pkg.as_str()) {
            old = i;
        } else if (names_pkg(sc.source.as_str(), pkg.as_str())) {
            if (n_users > 0) {
                users.append(", ");
            }
            users.append(sc.pkg.as_str());
            n_users += 1;
        }
    }
    if (old < v.scripts.len && v.scripts.at(old).name.as_str() != name) {
        var msg = fmt3("can't load {}: its package, {}, is {}'s (load ", S(name), copy pkg, copy v.scripts.at(old).name);
        msg.append(v.scripts.at(old).name.as_str());
        msg.append(" again to replace it, or give this one another name)");
        return v.fail(vm_error::COMPILE, msg.as_str());
    }
    // (a library stays loaded, and a new one's symbols of the same names would come from it)
    if (old < v.scripts.len && v.scripts.at(old).native) {
        return v.fail(vm_error::COMPILE, fmt("can't load {} again: its imports' code was loaded as a library, which stays (a new version goes in a new VM)", S(name)).as_str());
    }
    if (old < v.scripts.len && n_users > 0) {
        var msg = fmt2("can't load {} again: {} ", S(name), move users);
        if (n_users == 1) {
            msg.append("uses it");
        } else {
            msg.append("use it");
        }
        return v.fail(vm_error::COMPILE, msg.as_str());
    }
    v.loads += 1;
    var s: sources = {};
    var o: opts = { release: v.release, runtime: false, lib: null, line_info: false };
    if (v.std_dir.len() > 0) {
        for (f&) in volt_files(v.std_dir.as_str()).items() {
            val text = std::fs::read_file(f.as_str()) catch |e| {
                return v.fail(vm_error::COMPILE, fmt("can't read {}", copy *f).as_str());
            };
            put(&s.names, copy *f);
            put(&s.texts, move text);
            put(&s.units, { file: @cast<u32>(s.names.len - 1), pkg: "std" });
        }
    }
    // the scripts before it, as packages: their declarations and generic code from their source,
    // their other code and globals the JIT's (defined once, by their own load)
    for (i) in 0..v.scripts.len {
        if (i != old) {
            val sc = v.scripts.at(i);
            put(&s.names, copy sc.name);
            put(&s.texts, copy sc.source);
            put(&s.units, { file: @cast<u32>(s.names.len - 1), pkg: sc.pkg.as_str() });
            put(&o.linked, sc.pkg.as_str());
        }
    }
    put(&s.names, S(name));
    put(&s.texts, S(source));
    put(&s.units, { file: @cast<u32>(s.names.len - 1), pkg: pkg.as_str() });
    for (i) in 0..s.names.len {
        put(&s.files, { name: s.names.at(i).as_str(), text: s.texts.at(i).as_str() });
    }
    val bad = parse_sources(&s);
    if (bad.len > 0) {
        return v.fail(vm_error::COMPILE, report(&s.files, &bad, 0, false, 20).as_str());
    }
    o.lib = pkg.as_str();
    for (u&) in s.units.items() {
        if (u.pkg) {
            put(&o.pkg_files, { file: u.file, pkg: u.pkg });
        }
    }
    val chk = compile_rounds(&s.files, &s.asts, move o);
    if (chk.errors.len > 0) {
        val diags = all_diags(&*chk);
        return v.fail(vm_error::COMPILE, report(&s.files, &diags, 0, false, 20).as_str());
    }
    var init = S("volt_vm_init_");
    init.append_uint(@cast<u64>(v.loads));
    var g: lg = { c: &*chk };
    val e = chk.llvm_jit_module(&g, init.as_str());
    if (e.len() > 0) {
        drop_backend(&g, true);
        return v.fail(vm_error::COMPILE, e.as_str());
    }
    // what its C and C++ imports need, built by the C and C++ compilers into a library the JIT
    // finds their symbols in; in a sandbox, by clang into LLVM bitcode linked into the script's own
    // module, so the JIT runs it and what it reaches goes through the sandbox's filter (a library's
    // code would reach past it)
    var native: std::string? = null;
    var ctors: std::vec<std::string> = {};
    if (g.hdr.len > 0 || chk.c_includes.len > 0 || chk.c_units.len > 0 || chk.cpp_units.len > 0 || chk.link_flags.len > 0) {
        var err = S("");
        var bcs: std::vec<std::string> = {};
        if (v.sandbox) {
            if (v.runtime.len == 0) {
                runtime_names(&v.runtime);
            }
            val triple = S(c_text(llvm::LLVMOrcLLJITGetTripleString(j)));
            if (sandbox_compilers(&*chk, &err)) {
                val dir = vm_native(&*chk, &g.hdr, v.loads, triple.as_str(), &bcs, &err);
                if (dir) {
                    for (bc&) in bcs.items() {
                        if (err.len() == 0) {
                            err = v.link_bitcode(&g, bc.as_str());
                        }
                    }
                    vm_clean(dir.as_str());
                }
            }
            if (err.len() > 0) {
                drop_backend(&g, true);
                return v.fail(vm_error::COMPILE, err.as_str());
            }
            ctors = glue_ctors(&g, v.loads);
        } else {
            native = vm_native(&*chk, &g.hdr, v.loads, null, &bcs, &err);
            if (native == null) {
                drop_backend(&g, true);
                return v.fail(vm_error::COMPILE, err.as_str());
            }
        }
    }
    if (!v.searching) {
        // the process's symbols (libc, the runtime this library exports), filtered in a sandbox
        if (v.sandbox) {
            if (v.runtime.len == 0) {
                runtime_names(&v.runtime);
            }
            for (a) in g.aliases.iter() {
                put(&v.allowed, S(*a.value)); // the C functions the runtime's helpers are bound to
            }
        }
        var gen: llvm::LLVMOrcOpaqueDefinitionGenerator* = null;
        var ge: llvm::LLVMOpaqueError* = null;
        if (v.sandbox) {
            ge = llvm::LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(&gen, llvm::LLVMOrcLLJITGetGlobalPrefix(j), vm_allows, @cast<void*>(&*v));
        } else {
            ge = llvm::LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(&gen, llvm::LLVMOrcLLJITGetGlobalPrefix(j), null, null);
        }
        if (ge != null) {
            drop_backend(&g, true);
            return v.fail(vm_error::JIT, jit_error(ge).as_str());
        }
        llvm::LLVMOrcJITDylibAddGenerator(v.jd, gen);
        v.searching = true;
        // and the runtime from this library's own file: a host that loaded it without
        // RTLD_GLOBAL (Python's ctypes, dlopen's default) keeps its symbols out of the process's
        var info: dl_info = {};
        if (dladdr(@cast<void*>(vm_allows), &info) != 0 && info.fname != null) {
            var lib_gen: llvm::LLVMOrcOpaqueDefinitionGenerator* = null;
            val le = llvm::LLVMOrcCreateDynamicLibrarySearchGeneratorForPath(&lib_gen, info.fname ?? "", llvm::LLVMOrcLLJITGetGlobalPrefix(j), vm_runtime_only, @cast<void*>(&*v));
            if (le == null) {
                llvm::LLVMOrcJITDylibAddGenerator(v.jd, lib_gen);
            } else {
                llvm::LLVMConsumeError(le);
            }
        }
    }
    if (native) {
        var lib_gen: llvm::LLVMOrcOpaqueDefinitionGenerator* = null;
        var path = S(native.as_str());
        val le = llvm::LLVMOrcCreateDynamicLibrarySearchGeneratorForPath(&lib_gen, path.c_str(), llvm::LLVMOrcLLJITGetGlobalPrefix(j), null, null);
        vm_native_done(native.as_str());
        if (le != null) {
            drop_backend(&g, true);
            return v.fail(vm_error::JIT, jit_error(le).as_str());
        }
        llvm::LLVMOrcJITDylibAddGenerator(v.jd, lib_gen);
    }
    // the module and its context go to the JIT (so ask it what it has first); the rest of the
    // backend's state goes now
    val has_init = llvm::LLVMGetNamedFunction(g.m, init.c_str()) != null;
    drop_backend(&g, false);
    val tsc = llvm::LLVMOrcCreateNewThreadSafeContextFromLLVMContext(g.ctx);
    val tsm = llvm::LLVMOrcCreateNewThreadSafeModule(g.m, tsc);
    llvm::LLVMOrcDisposeThreadSafeContext(tsc);
    // its own tracker: a load that fails from here, or a script loaded again, takes its code out
    val rt = llvm::LLVMOrcJITDylibCreateResourceTracker(v.jd);
    if (old < v.scripts.len) {
        drop_tracker(v.scripts.at(old).rt);
        v.scripts.remove(old);
    }
    val ae = llvm::LLVMOrcLLJITAddLLVMIRModuleWithRT(j, rt, tsm);
    if (ae != null) {
        drop_tracker(rt);
        return v.fail(vm_error::JIT, jit_error(ae).as_str());
    }
    // its imports' constructors (a C import's stubs for the functions nothing defines), as loading
    // a library runs them; looking one up compiles the module
    for (c&) in ctors.items() {
        val at = v.lookup(c.as_str());
        if (at == null) {
            drop_tracker(rt);
            return vm_error::JIT;
        }
        val ctor = @cast<extern "C" fn() -> void>(@cast<void*>(@cast<usize>(at ?? 0)));
        ctor();
    }
    // compile it now (looking up any of its symbols compiles the module), so a symbol that isn't
    // there or isn't allowed is this load's error; then set up its globals, when it has any
    var probe = S(first_export(&*chk));
    if (has_init) {
        probe = copy init;
    }
    if (probe.len() > 0) {
        val addr = v.lookup(probe.as_str());
        if (addr == null) {
            drop_tracker(rt);
            return vm_error::JIT;
        }
        if (has_init) {
            val run = @cast<extern "C" fn() -> void>(@cast<void*>(@cast<usize>(addr ?? 0)));
            run();
        }
    }
    put(&v.scripts, { pkg: copy pkg, name: S(name), source: S(source), rt: rt, native: native != null });
    return;
}

// the package a load's name makes: its file's name without directories or extension
fn script_pkg(name: str) -> str {
    var start: usize = 0;
    for (i) in 0..name.len {
        if (name[i] == '/' || name[i] == '\\') {
            start = i + 1;
        }
    }
    var end = name.len;
    var i = name.len;
    while (i > start) {
        i -= 1;
        if (name[i] == '.') {
            end = i;
            break;
        }
    }
    return name[start..end];
}

// can n be a package's name (a Volt identifier, not a keyword)?
fn can_name_pkg(n: str) -> bool {
    if (n.len == 0 || is_digit(n[0]) || is_keyword(n)) {
        return false;
    }
    for (i) in 0..n.len {
        if (!(is_alpha(n[i]) || is_digit(n[i]) || n[i] == '_')) {
            return false;
        }
    }
    return true;
}

// a load's code and symbols, out of the JIT
fn drop_tracker(rt: llvm::LLVMOrcOpaqueResourceTracker*) -> void {
    val e = llvm::LLVMOrcResourceTrackerRemove(rt);
    if (e != null) {
        llvm::LLVMConsumeError(e);
    }
    llvm::LLVMOrcReleaseResourceTracker(rt);
}

// a script's native code (its imports' C: their headers' functions' pointers, a C unit of another
// standard; C++ wrappers and modules; the libraries --cc links), built by $CC and $CXX into a shared
// library under /tmp: its path, or why not in err. With a triple (a sandbox's), clang and clang++
// compile it to LLVM bitcode for that target instead, each file's path into bcs: the result is the
// directory they're in
fn vm_native(chk: checker&, hdr: std::vec<str>&, n: u64, triple: str?, bcs: std::vec<std::string>&, err: std::string&) -> std::string? {
    var t = S("/tmp/voltvm-XXXXXX");
    t.push(0);
    if (mkdtemp(@cast<u8*>(t.as_str().ptr)) == null) {
        *err = S("can't make a build directory in /tmp for the script's C");
        return null;
    }
    val dir = S(t.as_str()[0..t.len() - 1]);
    val so = vm_build(chk, hdr, dir.as_str(), n, triple, bcs, err);
    if (so == null) {
        vm_clean(dir.as_str());
    }
    return so;
}

// vm_native's work in dir
fn vm_build(chk: checker&, hdr: std::vec<str>&, dir: str, n: u64, triple: str?, bcs: std::vec<std::string>&, err: std::string&) -> std::string? {
    // bitcode: what the compilers are given, and what they write
    var bc_flags: std::vec<std::string> = {};
    var ext = ".o";
    if (triple) {
        put(&bc_flags, S("-fno-stack-protector"));
        put(&bc_flags, S("-emit-llvm"));
        put(&bc_flags, fmt("--target={}", S(triple)));
        ext = ".bc";
    }
    var objs: std::vec<std::string> = {};
    // C: Volt's own (the headers, the functions' pointers), and each kept unit
    var cs: std::vec<std::string> = {};
    var stds: std::vec<str> = {};
    put(&cs, llvm_runtime_c(chk, hdr, false));
    put(&stds, chk.c_own_std());
    for (u) in 0..chk.c_units.len {
        var text = copy *chk.c_unit_text.at(u);
        if (chk.c_unit_weak.at(u).len() > 0) {
            text.append("\n__attribute__((constructor)) static void volt_c_check(void) {\n");
            text.append(chk.c_unit_weak.at(u).as_str());
            text.append("}\n");
        }
        put(&cs, move text);
        put(&stds, *chk.c_units.at(u));
    }
    for (i) in 0..cs.len {
        val src = fmt2("{}/c{}.c", S(dir), unum(@cast<u64>(i)));
        var obj = fmt2("{}/c{}", S(dir), unum(@cast<u64>(i)));
        obj.append(ext);
        std::fs::write_file(src.as_str(), cs.at(i).as_str()) catch |e| {
            *err = fmt("can't write {}", copy src);
            return null;
        };
        var argv: std::vec<str> = {};
        var cc = "";
        if (triple) {
            cc = command_from(&argv, "CC", "clang");
        } else {
            cc = c_command(&argv);
        }
        for (f&) in bc_flags.items() {
            put(&argv, f.as_str());
        }
        val std_flag = fmt("-std={}", S(*stds.at(i)));
        val fixed: str[6] = { std_flag.as_str(), "-fPIC", "-w", "-c", "-o", obj.as_str() };
        for (f) in fixed {
            put(&argv, f);
        }
        put(&argv, src.as_str());
        for (f&) in chk.opts.pp_flags.items() {
            put(&argv, *f);
        }
        if (!vm_run(&argv, cc, err)) {
            return null;
        }
        put(&objs, obj);
    }
    // C++: each unit's wrappers the script reaches, with the modules it imports
    var any_cpp = false;
    var linked: std::vec<std::string> = {};
    if (chk.cpp_units.len > 0) {
        val live = reachable(chk);
        for (u) in 0..chk.cpp_units.len {
            val text = chk.cpp_unit(@cast<u32>(u), &live);
            if (text.len() == 0) {
                continue;
            }
            any_cpp = true;
            val src = fmt2("{}/cpp{}.cpp", S(dir), unum(@cast<u64>(u)));
            var obj = fmt2("{}/cpp{}", S(dir), unum(@cast<u64>(u)));
            obj.append(ext);
            std::fs::write_file(src.as_str(), text.as_str()) catch |e| {
                *err = fmt("can't write {}", copy src);
                return null;
            };
            val std_flag = fmt("-std={}", S(*chk.cpp_units.at(u)));
            // (a module's interface is compiled natively)
            if (triple != null && imports_modules(chk, @cast<u32>(u))) {
                *err = S("a sandbox's script can't import C++ modules: clang++ compiles its C++ to LLVM bitcode, and a module's interface is native code");
                return null;
            }
            val mflags = cpp_module_flags(chk, &chk.opts.pp_flags, dir, @cast<u32>(u), std_flag.as_str(), &objs, &linked, err);
            if (err.len() > 0) {
                return null;
            }
            var argv: std::vec<str> = {};
            var cxx = "";
            if (triple) {
                cxx = command_from(&argv, "CXX", "clang++");
            } else {
                cxx = cxx_command(&argv);
            }
            for (f&) in bc_flags.items() {
                put(&argv, f.as_str());
            }
            val fixed: str[6] = { std_flag.as_str(), "-fPIC", "-w", "-c", "-o", obj.as_str() };
            for (f) in fixed {
                put(&argv, f);
            }
            put(&argv, src.as_str());
            for (f&) in chk.opts.pp_flags.items() {
                put(&argv, *f);
            }
            for (f&) in mflags.items() {
                put(&argv, f.as_str());
            }
            if (!vm_run(&argv, cxx, err)) {
                return null;
            }
            put(&objs, obj);
        }
    }
    // bitcode: the JIT links it (and a sandbox loads no library: its code would run natively)
    if (triple) {
        *bcs = move objs;
        return S(dir);
    }
    // linked as a shared library (by the C++ compiler when there's C++: its runtime)
    val so = std::fmt::format("{}/script{}.so", dir, n);
    var argv: std::vec<str> = {};
    var link = "";
    if (any_cpp) {
        link = cxx_command(&argv);
    } else {
        link = c_command(&argv);
    }
    put(&argv, "-shared");
    put(&argv, "-o");
    put(&argv, so.as_str());
    for (o&) in objs.items() {
        put(&argv, o.as_str());
    }
    for (f&) in chk.link_flags.items() {
        put(&argv, f.as_str());
    }
    if (!vm_run(&argv, link, err)) {
        return null;
    }
    return so;
}

// does C++ unit u import a module (import std;, std.compat, or one of the script's)?
fn imports_modules(chk: checker&, u: u32) -> bool {
    for (x) in chk.cpp_std_units.items() {
        if (x == u) {
            return true;
        }
    }
    for (x) in chk.cpp_compat_units.items() {
        if (x == u) {
            return true;
        }
    }
    for (m&) in chk.cpp_modules.items() {
        if (m.unit == u) {
            return true;
        }
    }
    return false;
}

// a sandbox's compilers are clang's, of the LLVM this VM runs (gcc writes no LLVM bitcode, and the
// JIT reads only its own LLVM's): whether they are, else why not in err
fn sandbox_compilers(chk: checker&, err: std::string&) -> bool {
    var major: u32 = 0;
    var minor: u32 = 0;
    var patch: u32 = 0;
    llvm::LLVMGetVersion(&major, &minor, &patch);
    if (!clang_of(major, "CC", "clang", "C", err)) {
        return false;
    }
    return chk.cpp_units.len == 0 || clang_of(major, "CXX", "clang++", "C++", err);
}

// is $var_name (else dflt) a clang of LLVM major? else why not in err
fn clang_of(major: u32, var_name: str, dflt: str, lang: str, err: std::string&) -> bool {
    var argv: std::vec<str> = {};
    val tool = command_from(&argv, var_name, dflt);
    put(&argv, "--version");
    var says = S("");
    val r = std::process::capture(argv.items(), "") catch |e| {
        *err = fmt2("can't run '{}': a sandbox's script importing {} needs clang", S(tool), S(lang));
        return false;
    };
    says = copy r.out;
    var wanted = S(dflt);
    wanted.push(' ');
    wanted.append_uint(@cast<u64>(major));
    var how = fmt2("a sandbox's script imports {} through {} (LLVM bitcode, run by the JIT under the sandbox), and $", S(lang), copy wanted);
    how.append(var_name);
    how.append(" is ");
    how.append(tool);
    val at = says.as_str().find("clang version ");
    if (r.code != 0 || at == null) {
        // (the LLVM this VM runs only matters once it's clang)
        *err = fmt2("a sandbox's script imports {} through {} (LLVM bitcode, run by the JIT under the sandbox), and $", S(lang), S(dflt));
        err.append(var_name);
        err.append(" is ");
        err.append(tool);
        return false;
    }
    val rest = says.as_str()[(at ?? 0) + 14..says.len()];
    var e: usize = 0;
    while (e < rest.len && is_digit(rest[e])) {
        e += 1;
    }
    var mine = S("");
    mine.append_uint(@cast<u64>(major));
    if (rest[0..e] != mine.as_str()) {
        how.append(" ");
        how.append(rest[0..e]);
        *err = move how;
        return false;
    }
    return true;
}

// the bitcode at path, linked into the script's module, its definitions private to that module (two
// scripts' glue for one header never meet), but the runtime's that Volt's prelude defines for C
// (the library's are the ones the script calls): "", else why not
attach fn link_bitcode(this: volt_vm&, g: lg&, path: str) -> std::string {
    var p = S(path);
    var buf: llvm::LLVMOpaqueMemoryBuffer* = null;
    var msg: cstr? = null;
    if (llvm::LLVMCreateMemoryBufferWithContentsOfFile(p.c_str(), &buf, &msg) != 0) {
        return fmt2("can't read {}: {}", copy p, S(c_text(msg)));
    }
    var m: llvm::LLVMOpaqueModule* = null;
    if (llvm::LLVMParseBitcodeInContext2(g.ctx, buf, &m) != 0) {
        llvm::LLVMDisposeMemoryBuffer(buf);
        return fmt("clang wrote bitcode this VM's LLVM can't read ({})", copy p);
    }
    llvm::LLVMDisposeMemoryBuffer(buf);
    var names: std::vec<std::string> = {};
    var f = llvm::LLVMGetFirstFunction(m);
    while (f != null) {
        if (llvm::LLVMIsDeclaration(f) == 0) {
            this.glue_def(f, &names);
        }
        f = llvm::LLVMGetNextFunction(f);
    }
    var gv = llvm::LLVMGetFirstGlobal(m);
    while (gv != null) {
        if (llvm::LLVMIsDeclaration(gv) == 0 && !starts_with(value_name(gv), "llvm.")) {
            this.glue_def(gv, &names);
        }
        gv = llvm::LLVMGetNextGlobal(gv);
    }
    // (C++'s constructor and destructor aliases, C1 for C2)
    var al = llvm::LLVMGetFirstGlobalAlias(m);
    while (al != null) {
        this.glue_def(al, &names);
        al = llvm::LLVMGetNextGlobalAlias(al);
    }
    llvm::LLVMSetTarget(m, llvm::LLVMGetTarget(g.m));
    llvm::LLVMSetDataLayout(m, llvm::LLVMGetDataLayoutStr(g.m));
    if (llvm::LLVMLinkModules2(g.m, m) != 0) {
        return fmt("can't link the script's imports' code ({}) into it", copy p);
    }
    for (n&) in names.items() {
        var x = llvm::LLVMGetNamedFunction(g.m, n.c_str());
        if (x == null) {
            x = llvm::LLVMGetNamedGlobal(g.m, n.c_str());
        }
        if (x == null) {
            x = llvm::LLVMGetNamedGlobalAlias(g.m, n.c_str(), n.len());
        }
        if (x != null) {
            llvm::LLVMSetComdat(x, null);
            llvm::LLVMSetLinkage(x, llvm::LLVMInternalLinkage);
            llvm::LLVMSetVisibility(x, llvm::LLVMDefaultVisibility);
        }
    }
    return S("");
}

// a definition of the glue's: the runtime's (the prelude's weak one) is only there to be inlined,
// the library's being the one called; any other becomes the script module's own (its name into names)
attach fn glue_def(this: volt_vm&, x: llvm::LLVMOpaqueValue*, names: std::vec<std::string>&) -> void {
    val name = value_name(x);
    val link = llvm::LLVMGetLinkage(x);
    // (one private already: the linker renames it when the script has the name, which isn't the
    // glue's to touch)
    if (link == llvm::LLVMInternalLinkage || link == llvm::LLVMPrivateLinkage) {
        return;
    }
    if (this.runtime_name(name) && llvm::LLVMIsAGlobalAlias(x) == null) {
        llvm::LLVMSetLinkage(x, llvm::LLVMAvailableExternallyLinkage);
    } else {
        put(names, S(name));
    }
}

// a value's name
fn value_name(v: llvm::LLVMOpaqueValue*) -> str {
    var n: usize = 0;
    val p = llvm::LLVMGetValueName2(v, &n);
    return @cast<str>(@slice(@cast<u8*>(p ?? ""), n));
}

// the constructors the linked bitcode brought (llvm.global_ctors), named to be looked up and run,
// by priority (then as listed), once the JIT has the module: their names
fn glue_ctors(g: lg&, load: u64) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    val list = llvm::LLVMGetNamedGlobal(g.m, "llvm.global_ctors");
    if (list == null) {
        return out;
    }
    val init = llvm::LLVMGetInitializer(list);
    if (init != null) {
        val n = @cast<u32>(llvm::LLVMGetNumOperands(init));
        var order: std::vec<u32> = {};
        for (i) in 0..n {
            // (an insertion sort: a handful of entries)
            var at = order.len;
            while (at > 0 && ctor_priority(init, *order.at(at - 1)) > ctor_priority(init, i)) {
                at -= 1;
            }
            order.insert(at, i) catch @panic("out of memory");
        }
        for (i) in order.items() {
            val f = llvm::LLVMGetOperand(llvm::LLVMGetOperand(init, i), 1);
            if (f != null && llvm::LLVMIsAFunction(f) != null) {
                var name = S("volt_vm_ctor_");
                name.append_uint(load);
                name.push('_');
                name.append_uint(@cast<u64>(i));
                var cn = copy name;
                llvm::LLVMSetValueName2(f, cn.c_str(), name.len());
                llvm::LLVMSetLinkage(f, llvm::LLVMExternalLinkage);
                put(&out, move name);
            }
        }
    }
    llvm::LLVMDeleteGlobal(list);
    return out;
}

// entry i of llvm.global_ctors's priority
fn ctor_priority(init: llvm::LLVMOpaqueValue*, i: u32) -> u64 {
    return llvm::LLVMConstIntGetZExtValue(llvm::LLVMGetOperand(llvm::LLVMGetOperand(init, i), 0));
}

// argv run: whether it did, else its compiler's error in err
fn vm_run(argv: std::vec<str>&, tool: str, err: std::string&) -> bool {
    val r = std::process::capture(argv.items(), "") catch |e| {
        *err = fmt("can't run '{}': a script importing C or C++ needs a C compiler ($CC) and, for C++, $CXX", S(tool));
        return false;
    };
    if (r.code != 0) {
        *err = fmt2("'{}' failed on the script's C or C++:\n{}", S(tool), copy r.err);
        return false;
    }
    return true;
}

// the native library loaded (the JIT keeps it mapped): its directory goes
fn vm_native_done(so: str) -> void {
    var at = so.len;
    while (at > 0 && so[at - 1] != '/') {
        at -= 1;
    }
    vm_clean(so[0..at - 1]);
}

// a build directory of vm_native's, and what's in it, gone
fn vm_clean(dir: str) -> void {
    for (f&) in (std::fs::list_dir(dir) catch |e| { return; }).items() {
        unlink_path(fmt2("{}/{}", S(dir), copy *f).as_str());
    }
    rmdir_path(dir);
}

// the address of a script's export fn (or a host function), 0 when there's none; cast it to a
// function pointer of the fn's C signature to call it
export fn volt_vm_find(v: volt_vm&, name: str) -> usize {
    return @cast<usize>(v.lookup(name) ?? 0);
}

// what the last failure was: the compiler's diagnostics, or LLVM's message
export fn volt_vm_error(v: volt_vm&) -> str {
    return v.message.as_str();
}

attach fn delete(this: volt_vm&) -> void {
    val j = this.jit ?? return;
    for (sc&) in this.scripts.items() {
        llvm::LLVMOrcReleaseResourceTracker(sc.rt);
    }
    llvm::LLVMConsumeError(llvm::LLVMOrcDisposeLLJIT(j));
    this.jit = null;
}

// a VM whose JIT couldn't be made: its message (from volt_vm_new) says why
attach fn no_jit(this: volt_vm&) -> vm_error!void {
    if (this.message.len() == 0) {
        this.message = S("this VM has no JIT");
    }
    return vm_error::JIT;
}

// what the backend made besides the module and its context, which the JIT takes; with `all`, those
// too (a load that stops before the JIT has them)
fn drop_backend(g: lg&, all: bool) -> void {
    if (g.b != null) {
        llvm::LLVMDisposeBuilder(g.b);
    }
    if (g.eb != null) {
        llvm::LLVMDisposeBuilder(g.eb);
    }
    if (g.td != null) {
        llvm::LLVMDisposeTargetData(g.td);
    }
    if (g.tm != null) {
        llvm::LLVMDisposeTargetMachine(g.tm);
    }
    if (all) {
        if (g.m != null) {
            llvm::LLVMDisposeModule(g.m);
        }
        if (g.ctx != null) {
            llvm::LLVMContextDispose(g.ctx);
        }
    }
}

// the names the runtime defines and uses (volt_...), read from its C text: in a sandbox the part of
// this library a script's code may reach (a name written with ## stands for its 32- and 64-bit forms)
fn runtime_names(out: std::map<str, bool>&) -> void {
    val texts: str[2] = { PRELUDE_H, RUNTIME_H };
    for (t) in texts {
        var i: usize = 0;
        while (i + 5 <= t.len) {
            if (t[i..i + 5] == "volt_" && (i == 0 || !(is_alpha(t[i - 1]) || is_digit(t[i - 1]) || t[i - 1] == '_'))) {
                var e = i + 5;
                while (e < t.len && (is_alpha(t[e]) || is_digit(t[e]) || t[e] == '_')) {
                    e += 1;
                }
                // a macro's name (volt_q_add, volt_f128) is no symbol
                if (i < 8 || t[i - 8..i] != "#define ") {
                    out.put(t[i..e], true);
                }
                i = e;
            } else {
                i += 1;
            }
        }
    }
}

// is `name` one of the runtime's (a sized form of a ## name: volt_rt_atomic_load32)?
attach fn runtime_name(this: volt_vm&, name: str) -> bool {
    if (this.runtime.get(name) != null) {
        return true;
    }
    var e = name.len;
    while (e > 0 && is_digit(name[e - 1])) {
        e -= 1;
    }
    return e < name.len && this.runtime.get(name[0..e]) != null;
}

// record a failure's message and return the error
attach fn fail(this: volt_vm&, e: vm_error, msg: str) -> vm_error!void {
    this.message = S(msg);
    return e;
}

// a symbol of a load's own ("" when it has none), whose lookup compiles its module: a symbol that
// isn't there (or isn't allowed) is reported by the load, not by the first call
fn first_export(chk: checker&) -> str {
    for (f&) in chk.ir.fns.items() {
        if (f.body != null && f.used && f.link == linkage::EXPORTED && f.name != "main") {
            return f.name;
        }
    }
    return "";
}

// what a lookup gives its callback's context
struct vm_found_sym {
    done: bool = false;
    addr: u64 = 0;
    message: std::string = {};
}

// the address of `name` among the VM's scripts and host functions (null, with the message set,
// when it isn't there or its module doesn't link)
attach fn lookup(this: volt_vm&, name: str) -> u64? {
    val j = this.jit ?? return null;
    this.listen();
    this.session.clear();
    var n = S(name);
    var order: llvm::LLVMOrcCJITDylibSearchOrderElement[2] = { { JD: this.jd, JDLookupFlags: llvm::LLVMOrcJITDylibLookupFlagsMatchAllSymbols }, { JD: null, JDLookupFlags: llvm::LLVMOrcJITDylibLookupFlagsMatchAllSymbols } };
    var syms: llvm::LLVMOrcCLookupSetElement[2] = { { Name: llvm::LLVMOrcLLJITMangleAndIntern(j, n.c_str()), LookupFlags: llvm::LLVMOrcSymbolLookupFlagsRequiredSymbol }, { Name: null, LookupFlags: llvm::LLVMOrcSymbolLookupFlagsRequiredSymbol } };
    var r: vm_found_sym = {};
    llvm::LLVMOrcExecutionSessionLookup(llvm::LLVMOrcLLJITGetExecutionSession(j), llvm::LLVMOrcLookupKindStatic, &order[0], 1, &syms[0], 1, vm_found, @cast<void*>(&r));
    if (!r.done) {
        this.message = S("the JIT didn't answer the lookup right away");
        return null;
    }
    if (r.message.len() > 0) {
        // LLVM's own report says which symbol; the lookup's error only which module failed
        this.message = copy r.message;
        if (this.session.len() > 0) {
            this.message = copy this.session;
            if (this.sandbox && this.session.as_str().contains("Symbols not found")) {
                this.message.append(" (this VM is a sandbox: it reaches only the symbols volt_vm_allow gave it)");
            }
        }
        return null;
    }
    return r.addr;
}

// LLVM's report of a failure while compiling (a symbol not found), kept for the VM's message
fn vm_session_error(ctx: void*, err: llvm::LLVMOpaqueError*) -> void {
    val v = @cast<volt_vm*>(ctx);
    v->session = jit_error(err);
}

// a lookup's result, into its vm_found_sym
fn vm_found(err: llvm::LLVMOpaqueError*, result: llvm::LLVMOrcCSymbolMapPair*, n: usize, ctx: void*) -> void {
    val r = @cast<vm_found_sym*>(ctx);
    r->done = true;
    if (err != null) {
        r->message = jit_error(err);
        return;
    }
    if (n > 0) {
        r->addr = result->Sym.Address;
    }
}

// LLVM's message for an error, which it frees
fn jit_error(e: llvm::LLVMOpaqueError*) -> std::string {
    val m = llvm::LLVMGetErrorMessage(e);
    val out = S(c_text(m));
    llvm::LLVMDisposeErrorMessage(m);
    return out;
}

// where a function's code was loaded from (the shared library this is, when it is one)
struct dl_info {
    fname: cstr? = null;
    fbase: void* = null;
    sname: cstr? = null;
    saddr: void* = null;
}

extern "C" fn dladdr(addr: void*, info: dl_info*) -> i32;

// the filter on this library's own symbols: its runtime's (dlsym on a library also searches what it
// links, the C library among them, which a sandbox mustn't reach this way; and in a sandbox, only the
// runtime's names, not the rest of what this library exports)
fn vm_runtime_only(ctx: void*, sym: llvm::LLVMOrcOpaqueSymbolStringPoolEntry*) -> i32 {
    val v = @cast<volt_vm*>(ctx);
    val name = c_text(llvm::LLVMOrcSymbolStringPoolEntryStr(sym));
    if (v->sandbox) {
        return @cast<i32>(v->runtime_name(name));
    }
    return @cast<i32>(starts_with(name, "volt_"));
}

// the sandbox's filter on the process's symbols: the runtime's names, the memory functions LLVM calls
// on its own, the C functions the runtime's helpers are bound to, and what the host allowed
fn vm_allows(ctx: void*, sym: llvm::LLVMOrcOpaqueSymbolStringPoolEntry*) -> i32 {
    val v = @cast<volt_vm*>(ctx);
    val name = c_text(llvm::LLVMOrcSymbolStringPoolEntryStr(sym));
    if (v->runtime_name(name)) {
        return 1;
    }
    // (and the helpers clang's code calls for 128-bit arithmetic and thread locals)
    val builtin: str[11] = { "memcpy", "memmove", "memset", "memcmp", "__udivti3", "__umodti3", "__divti3", "__modti3", "__multi3", "__muloti4", "__emutls_get_address" };
    for (b) in builtin {
        if (name == b) {
            return 1;
        }
    }
    for (a&) in v->allowed.items() {
        if (a.as_str() == name) {
            return 1;
        }
    }
    return 0;
}
