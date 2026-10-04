// Volt embedded in another program, as Lua is: voltc/embed builds the compiler into libvoltvm.so,
// whose interface is volt_vm. A VM compiles Volt source text in memory with this compiler and runs
// it through LLVM's ORC JIT, so no C compiler runs. A script's code calls the runtime the library
// itself exports (an LLVM-built shared library's runtime functions are weak and visible) and the
// process's C library; in a sandbox only the symbols the host allows, and what the runtime needs (not
// the rest of what this library exports: its header pointers, the compiler's helpers, volt_vm). The
// host looks up a script's export fns by name and calls them through the C ABI, and gives scripts
// functions of its own, which they declare `extern "C"`.
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
}

// a VM whose scripts see the std package in std_dir ("" for none: scripts see only the host's
// functions)
export fn volt_vm_new(std_dir: str) -> volt_vm {
    var v: volt_vm = { std_dir: std::string::from(std_dir) };
    llvm::LLVMInitializeX86TargetInfo();
    llvm::LLVMInitializeX86Target();
    llvm::LLVMInitializeX86TargetMC();
    llvm::LLVMInitializeX86AsmPrinter();
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
// and its globals are set up. Scripts loaded later can't redefine an export fn
export fn volt_vm_load(v: volt_vm&, name: str, source: str) -> vm_error!void {
    val j = v.jit ?? return v.no_jit();
    v.loads += 1;
    // each script is a package of its own, so its non-export names never meet another script's
    var pkg = S("script_");
    pkg.append_uint(@cast<u64>(v.loads));
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
    val chk = compile(&s.files, &s.asts, move o);
    if (chk.errors.len > 0) {
        val diags = all_diags(&*chk);
        return v.fail(vm_error::COMPILE, report(&s.files, &diags, 0, false, 20).as_str());
    }
    if (chk.c_includes.len > 0 || chk.link_flags.len > 0) {
        return v.fail(vm_error::COMPILE, "a script can't import C headers or code in other languages (no C compiler runs)");
    }
    var init = S("volt_vm_init_");
    init.append_uint(@cast<u64>(v.loads));
    var g: lg = { c: &*chk };
    val e = chk.llvm_jit_module(&g, init.as_str());
    if (e.len() > 0) {
        drop_backend(&g, true);
        return v.fail(vm_error::COMPILE, e.as_str());
    }
    if (!v.searching) {
        // the process's symbols (libc, the runtime this library exports), filtered in a sandbox
        if (v.sandbox) {
            runtime_names(&v.runtime);
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
    // the module and its context go to the JIT (so ask it what it has first); the rest of the
    // backend's state goes now
    val has_init = llvm::LLVMGetNamedFunction(g.m, init.c_str()) != null;
    drop_backend(&g, false);
    val tsc = llvm::LLVMOrcCreateNewThreadSafeContextFromLLVMContext(g.ctx);
    val tsm = llvm::LLVMOrcCreateNewThreadSafeModule(g.m, tsc);
    llvm::LLVMOrcDisposeThreadSafeContext(tsc);
    val ae = llvm::LLVMOrcLLJITAddLLVMIRModule(j, v.jd, tsm);
    if (ae != null) {
        return v.fail(vm_error::JIT, jit_error(ae).as_str());
    }
    // compile it now (looking up any of its symbols compiles the module), so a symbol that isn't
    // there or isn't allowed is this load's error; then set up its globals, when it has any
    if (!has_init) {
        return v.link_check(&*chk);
    }
    val addr = v.lookup(init.as_str()) ?? return vm_error::JIT;
    val run = @cast<extern "C" fn() -> void>(@cast<void*>(@cast<usize>(addr)));
    run();
    return;
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
                out.put(t[i..e], true);
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

// compile every export fn of a load that set up no globals, so a symbol that isn't there (or isn't
// allowed) is reported by the load, not by the first call
attach fn link_check(this: volt_vm&, chk: checker&) -> vm_error!void {
    for (f&) in chk.ir.fns.items() {
        if (f.body != null && f.used && f.link == linkage::EXPORTED && f.name != "main") {
            this.lookup(f.name) ?? return vm_error::JIT;
            return; // one symbol compiles the whole module
        }
    }
    return;
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
    val builtin: str[4] = { "memcpy", "memmove", "memset", "memcmp" };
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
