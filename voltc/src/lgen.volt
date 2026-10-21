// The LLVM backend: the IR (ir.volt) lowered through the llvm-c API into an object file. Layouts
// mirror cgen's C ones (struct members in order, void members dropped, a payload union as its most
// aligned member plus padding) and every function uses the target's C ABI (SysV x86-64, AAPCS64,
// Apple's arm64 or Windows x64), so LLVM-built code shares memory and calls with C-backend libraries,
// C headers and the runtime (compiled by cc).
use std::mem;
use { "llvm-c/Core.h", "llvm-c/Target.h", "llvm-c/TargetMachine.h", "llvm-c/Analysis.h", "llvm-c/Transforms/PassBuilder.h", "llvm-c/DebugInfo.h", "llvm-c/LLJIT.h", "llvm-c/Orc.h", "llvm-c/BitReader.h", "llvm-c/Linker.h", "llvm-c/Comdat.h" } as llvm;

// the C calling convention, from the triple
enum callconv {
    SYSV,     // x86-64 but Windows (and bare metal, where only Volt calls Volt)
    AAPCS64,  // aarch64 Linux and the like
    DARWIN64, // Apple's arm64: AAPCS64, with small ints extended by the caller
    WIN64,    // Windows x64
    WASM,     // WebAssembly: an aggregate of one scalar as that scalar, any other by a pointer to a copy
}

// how a value crosses a call
enum pass {
    NONE,   // void or empty: nothing
    DIRECT, // as its own LLVM type (a scalar)
    PIECES, // SysV: an aggregate of at most 16 bytes, as one or two eightbyte scalars
    COERCE, // AAPCS64, Windows: the whole value as one LLVM type (cty), reinterpreted through memory
    MEMORY, // params: a pointer to a copy (byval on SysV); returns: a pointer the caller gives (sret)
}

// how one param or return value crosses a call
struct abi_part {
    how: pass;
    ty: u32 = 0;                                  // the Volt type
    pieces: std::vec<llvm::LLVMOpaqueType*> = {}; // PIECES: the eightbytes' types
    cty: llvm::LLVMOpaqueType* = null;            // COERCE: the type it crosses as
    hfa: bool = false;                            // COERCE: floats in FP registers (AAPCS64)
    ext: u32 = 0;                                 // DIRECT small ints: 1 zeroext, 2 signext
}

// a function's lowered signature: how its return and each param cross, and the LLVM function type
struct abi_fn {
    ret: abi_part;
    params: std::vec<abi_part> = {};
    va: bool = false;
    ty: llvm::LLVMOpaqueType* = null;
}

// one eightbyte's class while classifying an aggregate
struct eightbyte {
    cls: u32 = 0; // 0 none, 1 INTEGER, 2 SSE, 3 SSE+SSEUP (an fp128: both eightbytes of one register)
    // the half, float and double scalars in it (pick the SSE piece's type)
    halves: u32 = 0;
    far: u32 = 0; // a half or float at the eightbyte's offset 4 or 6
    floats: u32 = 0;
    doubles: u32 = 0;
}

// the LLVM backend's state: the module being built, its caches, and the function being lowered
struct lg {
    c: checker&;
    ctx: llvm::LLVMOpaqueContext* = null;
    m: llvm::LLVMOpaqueModule* = null;
    b: llvm::LLVMOpaqueBuilder* = null;
    eb: llvm::LLVMOpaqueBuilder* = null; // allocas, in the function's first block
    td: llvm::LLVMOpaqueTargetData* = null;
    // caches: LLVM types by Volt type id; functions, their ABIs and globals by IR index
    tys: std::map<u32, llvm::LLVMOpaqueType*> = {};
    fns: std::map<u32, llvm::LLVMOpaqueValue*> = {};
    abis: std::map<u32, abi_fn> = {};
    globals: std::map<u32, llvm::LLVMOpaqueValue*> = {};
    bytes: std::map<str, llvm::LLVMOpaqueValue*> = {}; // literal byte arrays (NUL-terminated)
    aliases: std::map<str, str> = {};                   // prelude names bound to libc symbols
    names: std::vec<std::string> = {};                  // NUL-terminated names handed to LLVM
    ctors: std::vec<u32> = {};                          // globals set by a constructor
    // the current function
    fn_idx: u32 = 0;
    f: llvm::LLVMOpaqueValue* = null;
    abi: abi_fn = { ret: { how: pass::NONE } };
    locals: std::vec<llvm::LLVMOpaqueValue*> = {};
    labels: std::map<u32, llvm::LLVMOpaqueBasicBlock*> = {};
    // sret: the hidden return-slot param when the current fn returns by memory
    sret: llvm::LLVMOpaqueValue* = null;
    tm: llvm::LLVMOpaqueTargetMachine* = null;
    cc: callconv = callconv::SYSV;
    hdr: std::vec<str> = {}; // C header functions called through the runtime unit's pointers
    err: std::string = {};   // a program this backend can't lower (reported after the module)
    at_file: u32 = 0;        // the source line being lowered (the IR's AT marks; else its fn's), for err
    at_line: u32 = 0;
    opaques: std::map<u32, bool> = {}; // c_opaque's answers by type
    // debug info (DWARF line tables, when the IR marks statements' lines): the builder, a file per
    // source file, and the current function's subprogram and file
    di: llvm::LLVMOpaqueDIBuilder* = null;
    di_files: std::map<u32, llvm::LLVMOpaqueMetadata*> = {};
    di_sp: llvm::LLVMOpaqueMetadata* = null;
    di_file: u32 = 0;
    di_tys: std::map<u32, llvm::LLVMOpaqueMetadata*> = {}; // debug types by Volt type
    di_busy: std::map<u32, u32> = {};                      // aggregates being described (a pointer back to one is a forward declaration)
}

// ---------- small helpers ----------

// a NUL-terminated copy that lives as long as the backend
attach fn z(this: lg&, s: str) -> cstr {
    put(&this.names, S(s));
    return this.names.at(this.names.len - 1).c_str();
}

attach fn i1t(this: lg&) -> llvm::LLVMOpaqueType* { return llvm::LLVMInt1TypeInContext(this.ctx); }
attach fn i8t(this: lg&) -> llvm::LLVMOpaqueType* { return llvm::LLVMInt8TypeInContext(this.ctx); }
attach fn i32t(this: lg&) -> llvm::LLVMOpaqueType* { return llvm::LLVMInt32TypeInContext(this.ctx); }
attach fn i64t(this: lg&) -> llvm::LLVMOpaqueType* { return llvm::LLVMInt64TypeInContext(this.ctx); }
attach fn ptrt(this: lg&) -> llvm::LLVMOpaqueType* { return llvm::LLVMPointerTypeInContext(this.ctx, 0); }
attach fn voidt(this: lg&) -> llvm::LLVMOpaqueType* { return llvm::LLVMVoidTypeInContext(this.ctx); }

attach fn i64c(this: lg&, v: u64) -> llvm::LLVMOpaqueValue* {
    return llvm::LLVMConstInt(this.i64t(), v, 0);
}

// a usize constant (32 bits on a 32-bit target)
attach fn usizec(this: lg&, v: u64) -> llvm::LLVMOpaqueValue* {
    return llvm::LLVMConstInt(this.int_lt(int_ty::USIZE), v, 0);
}

attach fn size_of(this: lg&, t: llvm::LLVMOpaqueType*) -> u64 {
    return llvm::LLVMABISizeOfType(this.td, t);
}

attach fn align_of(this: lg&, t: llvm::LLVMOpaqueType*) -> u32 {
    return llvm::LLVMABIAlignmentOfType(this.td, t);
}

attach fn is_void(this: lg&, t: u32) -> bool {
    return t == VOID || t == NEVER || t == TYPE;
}

// an LLVM struct of these element types (packed: no padding between them)
fn struct_ty(ctx: llvm::LLVMOpaqueContext*, elems: std::vec<llvm::LLVMOpaqueType*>&, packed: bool) -> llvm::LLVMOpaqueType* {
    var p: i32 = 0;
    if (packed) {
        p = 1;
    }
    return llvm::LLVMStructTypeInContext(ctx, elems.ptr, @cast<u32>(elems.len), p);
}

// ---------- types ----------

// the LLVM type of a Volt type, in memory and as a value (bool is an i8, as in C)
attach fn lt(this: lg&, t: u32) -> llvm::LLVMOpaqueType* {
    val have = this.tys.get(t);
    if (have) {
        return *have;
    }
    val r = this.make_lt(t);
    this.tys.put(t, r);
    return r;
}

attach fn int_lt(this: lg&, k: int_ty) -> llvm::LLVMOpaqueType* {
    return llvm::LLVMIntTypeInContext(this.ctx, k.bits());
}

// lt without the cache: scalars map directly; an optional, enum or struct that isn't one falls
// through to the aggregate layout below
attach fn make_lt(this: lg&, t: u32) -> llvm::LLVMOpaqueType* {
    match (*this.c.t.get(t)) {
        .VOID => { return this.voidt(); },
        .NEVER => { return this.voidt(); },
        .TYPE => { return this.voidt(); },
        .BOOL => { return this.i8t(); },
        .NULL => { return this.ptrt(); },
        .VOIDPTR => { return this.ptrt(); },
        .CSTR => { return this.ptrt(); },
        .REF(x) => { return this.ptrt(); },
        .PTR(x) => { return this.ptrt(); },
        .FN_PTR(ps, r, va) => { return this.ptrt(); },
        .ANYERR => { return this.i32t(); },
        .INT(k) => { return this.int_lt(k); },
        .FLOAT(b) => {
            if (b == 16) {
                return llvm::LLVMHalfTypeInContext(this.ctx);
            }
            if (b == 32) {
                return llvm::LLVMFloatTypeInContext(this.ctx);
            }
            if (b == 64) {
                return llvm::LLVMDoubleTypeInContext(this.ctx);
            }
            return llvm::LLVMFP128TypeInContext(this.ctx);
        },
        .OPT(x) => {
            if (this.c.niche(x)) {
                return this.lt(x);
            }
        },
        .ENUM(e) => {
            if (!this.c.ei(e).has_payload) {
                return this.int_lt(this.c.ei(e).tag);
            }
        },
        .ARRAY(x, n) => { return llvm::LLVMArrayType2(this.lt(x), n); },
        .VECTOR(x, n) => { return llvm::LLVMVectorType(this.lt(x), @cast<u32>(n)); },
        .STRUCT(s) => {
            // (cimport's lay_out_partial gives the rest libclang's layout)
            if (this.c.partial_struct(s)) {
                this.cant(fmt("the LLVM backend can't lay out the C struct '{}': it has members Volt can't read, and libclang couldn't place the ones it can (or the struct is aligned to more than 16 bytes), so only C knows where its fields are", S(this.c.si(s).c_name)));
            }
        },
        default => {},
    }
    // an aggregate: its members in order (a union as one member)
    var elems: std::vec<llvm::LLVMOpaqueType*> = {};
    val n = this.member_count(t);
    if (this.is_union(t)) {
        put(&elems, this.lt(this.member_ty(t, 0)));
        // a trait union with no members is just its tag, as in C
        if (n > 1) {
            put(&elems, this.union_lt(t, 1));
        }
    } else if (this.c_union(t)) {
        return this.union_lt(t, 0);
    } else if (this.overlay(t).0 > 0) {
        val ov = this.overlay(t);
        return this.blob_lt(ov.0, @cast<u32>(ov.1));
    } else {
        val al = this.over_align(t);
        if (al > 0) {
            // a zero-length array of an n-byte vector: alignment n (LLVM aligns a vector to its
            // size), no bytes. LLVM then rounds the size, and places the struct in what holds it
            put(&elems, llvm::LLVMArrayType2(llvm::LLVMVectorType(this.i8t(), @cast<u32>(al)), 0));
        }
        for (i) in 0..n {
            val mt = this.member_ty(t, @cast<u32>(i));
            if (!this.is_void(mt)) {
                put(&elems, this.lt(mt));
            }
        }
    }
    match (*this.c.t.get(t)) {
        .CLOSURE(c) => {
            if (elems.len == 0) {
                put(&elems, this.i8t()); // C's `char unused`
            }
        },
        default => {},
    }
    val r = struct_ty(this.ctx, &elems, false);
    this.check_align(r, this.over_align(t), t);
    return r;
}

// an @align(n) type whose LLVM type isn't n-aligned: this target's data layout aligns no n-byte
// vector to n (ARM's aligns a 16-byte one to 8), so the alignment can't be carried
attach fn check_align(this: lg&, r: llvm::LLVMOpaqueType*, want: u64, t: u32) -> void {
    if (want > 0 && @cast<u64>(this.align_of(r)) != want) {
        this.cant(fmt2("the LLVM backend can't align '{}' to {} bytes on this target: its data layout aligns no type that way", this.c.ty_name(t), unum(want)));
    }
}

// a type's alignment without its own @align (C's unadjusted alignment, which AAPCS64 goes by)
attach fn natural_align(this: lg&, t: u32) -> u32 {
    if (this.over_align(t) == 0) {
        return this.align_of(this.lt(t));
    }
    var a: u32 = 1;
    for (i) in 0..this.member_count(t) {
        val mt = this.member_ty(t, @cast<u32>(i));
        if (!this.is_void(mt)) {
            val m = this.align_of(this.lt(mt));
            if (m > a) {
                a = m;
            }
        }
    }
    return a;
}

// a type's size without its own @align's padding: its fields' extent, as C's unadjusted size
attach fn natural_size(this: lg&, t: u32) -> u64 {
    if (this.over_align(t) == 0) {
        return this.size_of(this.lt(t));
    }
    var elems: std::vec<llvm::LLVMOpaqueType*> = {};
    for (i) in 0..this.member_count(t) {
        val mt = this.member_ty(t, @cast<u32>(i));
        if (!this.is_void(mt)) {
            put(&elems, this.lt(mt));
        }
    }
    return this.size_of(struct_ty(this.ctx, &elems, false));
}

// a struct's @align(n), when its type needs an element for it (0: none)
attach fn over_align(this: lg&, t: u32) -> u64 {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => { return this.c.si(s).align; },
        default => { return 0; },
    }
}

// a tagged union (an enum with payloads, a trait union): member 0 is the tag, 1 + i the payloads
attach fn is_union(this: lg&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .ENUM(e) => { return this.c.ei(e).has_payload; },
        .TRAIT_UNION(u) => { return true; },
        default => { return false; },
    }
}

// a C union imported from a header: its members share offset 0
attach fn c_union(this: lg&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => { return this.c.union_struct(s); },
        default => { return false; },
    }
}

// a header struct whose fields share bytes: C's size and alignment (size 0: it isn't one)
attach fn overlay(this: lg&, t: u32) -> (u64, u64) {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => { return this.c.overlay_size(s); },
        default => { return (0, 0); },
    }
}

// field i's byte offset in such a struct
attach fn overlay_offset(this: lg&, t: u32, i: u32) -> u64? {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => { return this.c.overlay_offset(s, i); },
        default => { return null; },
    }
}

// C's union of members `from`..: an integer as wide as its alignment, then bytes up to its size.
// No member's type: an aggregate load or store copies fields only, never padding, and one
// member's bytes may sit in another's padding.
attach fn union_lt(this: lg&, t: u32, from: usize) -> llvm::LLVMOpaqueType* {
    var size: u64 = 0;
    var align: u32 = 1;
    for (i) in from..this.member_count(t) {
        val mt = this.member_ty(t, @cast<u32>(i));
        if (this.is_void(mt)) {
            continue;
        }
        val l = this.lt(mt);
        val s = this.size_of(l);
        val a = this.align_of(l);
        if (s > size) {
            size = s;
        }
        if (a > align) {
            align = a;
        }
    }
    return this.blob_lt(size, align);
}

// size bytes aligned to align: an integer as wide as the alignment, then bytes
attach fn blob_lt(this: lg&, size: u64, align: u32) -> llvm::LLVMOpaqueType* {
    var elems: std::vec<llvm::LLVMOpaqueType*> = {};
    if (size == 0) {
        return struct_ty(this.ctx, &elems, false);
    }
    val full = (size + @cast<u64>(align) - 1) / @cast<u64>(align) * @cast<u64>(align);
    if (align > 16) {
        // (an @align struct's payload: LLVM aligns no integer past 16 bytes, but a vector to its size)
        put(&elems, llvm::LLVMArrayType2(llvm::LLVMVectorType(this.i8t(), align), 0));
        put(&elems, llvm::LLVMArrayType2(this.i8t(), full));
        val r = struct_ty(this.ctx, &elems, false);
        if (@cast<u64>(this.align_of(r)) != @cast<u64>(align)) {
            this.cant(fmt("the LLVM backend can't align a union to {} bytes on this target: its data layout aligns no type that way", unum(@cast<u64>(align))));
        }
        return r;
    }
    val lead = llvm::LLVMIntTypeInContext(this.ctx, align * 8);
    put(&elems, lead);
    if (full > @cast<u64>(align)) {
        put(&elems, llvm::LLVMArrayType2(this.i8t(), full - @cast<u64>(align)));
    }
    return struct_ty(this.ctx, &elems, false);
}

// how many members an aggregate has, and member i's type (ir.volt numbers them)
attach fn member_count(this: lg&, t: u32) -> usize {
    return this.c.field_count(t);
}

attach fn member_ty(this: lg&, agg: u32, i: u32) -> u32 {
    return this.c.field_ty(agg, i);
}

// the LLVM struct element member i lives in (void members have none; a union's payloads share 1,
// a C union's members 0)
attach fn elem(this: lg&, agg: u32, i: u32) -> u32 {
    if (this.c_union(agg)) {
        return 0;
    }
    if (this.is_union(agg)) {
        if (i == 0) {
            return 0;
        }
        return 1;
    }
    var k: u32 = 0;
    if (this.over_align(agg) > 0) {
        k = 1; // past the alignment element
    }
    for (j) in 0..@cast<usize>(i) {
        if (!this.is_void(this.member_ty(agg, @cast<u32>(j)))) {
            k += 1;
        }
    }
    return k;
}

// the byte offset of member i
attach fn offset_of(this: lg&, agg: u32, i: u32) -> u64 {
    val off = this.overlay_offset(agg, i);
    if (off) {
        return off;
    }
    return llvm::LLVMOffsetOfElement(this.td, this.lt(agg), this.elem(agg, i));
}

// ---------- the C ABI ----------

attach fn int_signed(this: lg&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .INT(k) => { return k.signed(); },
        .ENUM(e) => { return this.c.ei(e).tag.signed(); },
        default => { return false; },
    }
}

// the class of each eightbyte of t placed at byte `off`
attach fn classify(this: lg&, t: u32, off: u64, ebs: eightbyte[2]&) -> void {
    if (this.is_void(t)) {
        return;
    }
    val l = this.lt(t);
    val size = this.size_of(l);
    if (size == 0) {
        return;
    }
    val k = llvm::LLVMGetTypeKind(l);
    if (k == llvm::LLVMStructTypeKind) {
        for (i) in 0..this.member_count(t) {
            val mt = this.member_ty(t, @cast<u32>(i));
            if (!this.is_void(mt)) {
                this.classify(mt, off + this.offset_of(t, @cast<u32>(i)), ebs);
            }
        }
        return;
    }
    if (k == llvm::LLVMArrayTypeKind || k == llvm::LLVMVectorTypeKind) {
        // (a vector in a struct: its lanes, as C classifies them)
        match (*this.c.t.get(t)) {
            .ARRAY(x, n) => {
                val es = this.size_of(this.lt(x));
                for (j) in 0..n {
                    this.classify(x, off + @cast<u64>(j) * es, ebs);
                }
            },
            .VECTOR(x, n) => {
                val es = this.size_of(this.lt(x));
                for (j) in 0..n {
                    this.classify(x, off + @cast<u64>(j) * es, ebs);
                }
            },
            default => {},
        }
        return;
    }
    var cls: u32 = 1;
    var hf: u32 = 0;
    var fl: u32 = 0;
    var db: u32 = 0;
    if (k == llvm::LLVMHalfTypeKind) {
        cls = 2;
        hf = 1;
    } else if (k == llvm::LLVMFP128TypeKind) {
        cls = 3;
    } else if (k == llvm::LLVMFloatTypeKind) {
        cls = 2;
        fl = 1;
    } else if (k == llvm::LLVMDoubleTypeKind) {
        cls = 2;
        db = 1;
    }
    var at = off / 8;
    val last = (off + size - 1) / 8;
    while (at <= last && at < 2) {
        val j = @cast<usize>(at);
        val was = ebs[j].cls;
        if (cls == 3 || was == 3) {
            ebs[j].cls = 3;
        } else if (cls == 1 || was == 1) {
            ebs[j].cls = 1;
        } else {
            ebs[j].cls = 2;
        }
        ebs[j].halves += hf;
        if ((hf > 0 || fl > 0) && off % 8 >= 4) {
            ebs[j].far = 1;
        }
        ebs[j].floats += fl;
        ebs[j].doubles += db;
        at += 1;
    }
}

// how a value of type t crosses a call: as a param, or as the result when ret is set
attach fn part(this: lg&, t: u32, ret: bool) -> abi_part {
    if (this.is_void(t)) {
        return { how: pass::NONE, ty: t };
    }
    val l = this.lt(t);
    val k = llvm::LLVMGetTypeKind(l);
    if (k != llvm::LLVMStructTypeKind && k != llvm::LLVMArrayTypeKind) {
        val bits = int_bits(l);
        if (this.cc == callconv::WIN64 && bits == 128) {
            // Windows: an i128 goes by a pointer to a copy and comes back in xmm0
            if (ret) {
                return { how: pass::COERCE, ty: t, cty: llvm::LLVMVectorType(llvm::LLVMInt64TypeInContext(this.ctx), 2) };
            }
            return { how: pass::MEMORY, ty: t };
        }
        // a small int is extended by the caller on SysV and Apple's arm64 (to 32 bits); AAPCS64
        // leaves it to the callee, and Windows extends only a bool
        var ext: u32 = 0;
        if (bits > 0 && bits < 32 && (this.cc == callconv::SYSV || this.cc == callconv::DARWIN64 || this.cc == callconv::WASM || (this.cc == callconv::WIN64 && t == BOOL))) {
            ext = 1;
            if (this.int_signed(t)) {
                ext = 2;
            }
        }
        return { how: pass::DIRECT, ty: t, ext: ext };
    }
    val size = this.size_of(l);
    if (size == 0) {
        return { how: pass::NONE, ty: t };
    }
    if (this.cc == callconv::WIN64) {
        // Windows: 1, 2, 4 or 8 bytes as an integer that size; anything else by a pointer to a copy
        if (size == 1 || size == 2 || size == 4 || size == 8) {
            return { how: pass::COERCE, ty: t, cty: llvm::LLVMIntTypeInContext(this.ctx, @cast<u32>(size * 8)) };
        }
        return { how: pass::MEMORY, ty: t };
    }
    if (this.cc == callconv::WASM) {
        // WebAssembly (as clang has it): an aggregate of one scalar crosses as that scalar; any other
        // by a pointer to a copy (byval), or returned through a pointer the caller gives (sret)
        var leaves: std::vec<llvm::LLVMOpaqueType*> = {};
        scalar_leaves(l, &leaves);
        if (leaves.len == 1 && this.size_of(*leaves.at(0)) == size) {
            return { how: pass::COERCE, ty: t, cty: *leaves.at(0) };
        }
        return { how: pass::MEMORY, ty: t };
    }
    if (this.cc != callconv::SYSV) {
        return this.aapcs_part(t, size, ret);
    }
    if (size > 16) {
        return { how: pass::MEMORY, ty: t };
    }
    var ebs: eightbyte[2];
    ebs[0] = {};
    ebs[1] = {};
    this.classify(t, 0, &ebs);
    var r: abi_part = { how: pass::PIECES, ty: t };
    var leaves: std::vec<llvm::LLVMOpaqueType*> = {};
    scalar_leaves(l, &leaves);
    if (leaves.len == 1 && int_bits(*leaves.at(0)) == 128) {
        // an i128 inside: one i128 piece (two registers, or the stack whole), as clang has it
        put(&r.pieces, *leaves.at(0));
        return r;
    }
    // the eightbytes the fields cover (an @align struct's padding past them is passed as nothing)
    val data = this.natural_size(t);
    val n = (data + 7) / 8;
    for (i) in 0..n {
        val e = ebs[@cast<usize>(i)];
        var bytes = data - i * 8;
        if (bytes > 8) {
            bytes = 8;
        }
        if (e.cls == 3) {
            put(&r.pieces, llvm::LLVMFP128TypeInContext(this.ctx));
            return r; // both eightbytes
        }
        if (e.cls == 2) {
            if (e.doubles > 0) {
                put(&r.pieces, llvm::LLVMDoubleTypeInContext(this.ctx));
            } else if (e.halves > 0) {
                // as clang has it: a lone half, two halves with nothing at offset 4, else four lanes
                val h = llvm::LLVMHalfTypeInContext(this.ctx);
                if (e.far > 0) {
                    put(&r.pieces, llvm::LLVMVectorType(h, 4));
                } else if (e.halves >= 2) {
                    put(&r.pieces, llvm::LLVMVectorType(h, 2));
                } else {
                    put(&r.pieces, h);
                }
            } else if (e.far > 0) {
                // (a float in the eightbyte's upper half; a C union's floats overlapping at 0 are one)
                put(&r.pieces, llvm::LLVMVectorType(llvm::LLVMFloatTypeInContext(this.ctx), 2));
            } else {
                put(&r.pieces, llvm::LLVMFloatTypeInContext(this.ctx));
            }
        } else {
            put(&r.pieces, llvm::LLVMIntTypeInContext(this.ctx, @cast<u32>(bytes * 8)));
        }
    }
    return r;
}

// an integer type's width, 0 for any other type
fn int_bits(l: llvm::LLVMOpaqueType*) -> u32 {
    if (llvm::LLVMGetTypeKind(l) != llvm::LLVMIntegerTypeKind) {
        return 0;
    }
    return llvm::LLVMGetIntTypeWidth(l);
}

// AAPCS64's aggregates: an HFA (one to four of the same float type, nested or not) in FP registers;
// up to 16 bytes in one or two x registers (a pair as an i128 when it's 16-byte aligned); anything
// bigger by a pointer to a copy, or returned through x8
attach fn aapcs_part(this: lg&, t: u32, size: u64, ret: bool) -> abi_part {
    val l = this.lt(t);
    var leaves: std::vec<llvm::LLVMOpaqueType*> = {};
    this.c_leaves(t, &leaves);
    if (leaves.len >= 1 && leaves.len <= 4) {
        val e = *leaves.at(0);
        val ek = llvm::LLVMGetTypeKind(e);
        var same = ek == llvm::LLVMHalfTypeKind || ek == llvm::LLVMFloatTypeKind || ek == llvm::LLVMDoubleTypeKind || ek == llvm::LLVMFP128TypeKind;
        for (x) in leaves.items() {
            if (x != e) {
                same = false;
            }
        }
        // and no padding: an @align struct of one float is no HFA
        same = same && this.size_of(e) * @cast<u64>(leaves.len) == size;
        if (same) {
            // as clang has it: a param is an array of them, a result the aggregate itself
            var cty = llvm::LLVMArrayType2(e, @cast<u64>(leaves.len));
            if (ret) {
                // the aggregate itself, but a C union's blob as its floats (which LLVM puts in s/d registers)
                cty = l;
                var lls: std::vec<llvm::LLVMOpaqueType*> = {};
                scalar_leaves(l, &lls);
                if (lls.len != leaves.len || *lls.at(0) != e) {
                    cty = struct_ty(this.ctx, &leaves, false);
                }
            }
            return { how: pass::COERCE, ty: t, cty: cty, hfa: true };
        }
    }
    if (size > 16) {
        return { how: pass::MEMORY, ty: t };
    }
    // the i128 pair, as clang has it: a param goes by the alignment without the struct's own @align,
    // a result by the one with it; Apple's arm64 by the one with it both ways
    var al = this.natural_align(t);
    if (ret || this.cc == callconv::DARWIN64) {
        al = this.align_of(l);
    }
    var cty = llvm::LLVMInt64TypeInContext(this.ctx);
    if (al == 16) {
        cty = llvm::LLVMIntTypeInContext(this.ctx, 128);
    } else if (size > 8) {
        cty = llvm::LLVMArrayType2(cty, 2);
    } else if (ret) {
        cty = llvm::LLVMIntTypeInContext(this.ctx, @cast<u32>(size * 8));
    }
    return { how: pass::COERCE, ty: t, cty: cty };
}

// the scalars aggregate t is made of as AAPCS64 counts them: a C union's members overlap, so one of
// a single float type is as many of it as fill its size (the union itself, no float, when they
// differ); it stops past 5 (more than an HFA can have)
attach fn c_leaves(this: lg&, t: u32, out: std::vec<llvm::LLVMOpaqueType*>&) -> void {
    if (this.c_union(t)) {
        var e: llvm::LLVMOpaqueType* = null;
        var mixed = false;
        for (i) in 0..this.member_count(t) {
            val mt = this.member_ty(t, @cast<u32>(i));
            if (this.is_void(mt)) {
                continue;
            }
            var ms: std::vec<llvm::LLVMOpaqueType*> = {};
            this.c_leaves(mt, &ms);
            for (x) in ms.items() {
                if (e == null) {
                    e = x;
                } else if (e != x) {
                    mixed = true;
                }
            }
        }
        val size = this.size_of(this.lt(t));
        if (e == null || mixed || size % this.size_of(e) != 0) {
            put(out, this.lt(t));
            return;
        }
        for (j) in 0..size / this.size_of(e) {
            if (out.len > 4) {
                return;
            }
            put(out, e);
        }
        return;
    }
    match (*this.c.t.get(t)) {
        .STRUCT(s) => {
            if (!this.is_union(t) && this.overlay(t).0 == 0 && this.over_align(t) == 0) {
                for (i) in 0..this.member_count(t) {
                    val mt = this.member_ty(t, @cast<u32>(i));
                    if (out.len > 4) {
                        return;
                    }
                    if (!this.is_void(mt)) {
                        this.c_leaves(mt, out);
                    }
                }
                return;
            }
        },
        .ARRAY(x, n) => {
            for (j) in 0..n {
                if (out.len > 4) {
                    return;
                }
                this.c_leaves(x, out);
            }
            return;
        },
        default => {},
    }
    scalar_leaves(this.lt(t), out);
}

// the scalars l is made of, in order; it stops past 5 (more than an HFA can have)
fn scalar_leaves(l: llvm::LLVMOpaqueType*, out: std::vec<llvm::LLVMOpaqueType*>&) -> void {
    val k = llvm::LLVMGetTypeKind(l);
    if (k == llvm::LLVMStructTypeKind) {
        for (i) in 0..llvm::LLVMCountStructElementTypes(l) {
            if (out.len > 4) {
                return;
            }
            scalar_leaves(llvm::LLVMStructGetTypeAtIndex(l, i), out);
        }
    } else if (k == llvm::LLVMArrayTypeKind) {
        val e = llvm::LLVMGetElementType(l);
        for (i) in 0..llvm::LLVMGetArrayLength2(l) {
            if (out.len > 4) {
                return;
            }
            scalar_leaves(e, out);
        }
    } else {
        put(out, l);
    }
}

// memory for a COERCE value: room and alignment for both its Volt type and the type it crosses as
attach fn coerce_slot(this: lg&, p: abi_part&) -> llvm::LLVMOpaqueValue* {
    val l = this.lt(p.ty);
    var t = p.cty;
    if (this.size_of(l) > this.size_of(t)) {
        t = l;
    }
    val a = this.alloca(t);
    var al = this.align_of(l);
    if (this.align_of(p.cty) > al) {
        al = this.align_of(p.cty);
    }
    llvm::LLVMSetAlignment(a, al);
    return a;
}

// the INTEGER registers a PIECES value needs (an i128 two), and its SSE pieces
fn int_pieces(p: abi_part&) -> (u32, u32) {
    var ints: u32 = 0;
    var sses: u32 = 0;
    for (x) in p.pieces.items() {
        if (llvm::LLVMGetTypeKind(x) == llvm::LLVMIntegerTypeKind) {
            ints += (llvm::LLVMGetIntTypeWidth(x) + 63) / 64;
        } else {
            sses += 1;
        }
    }
    return (ints, sses);
}

// a function's calling convention from its Volt signature
attach fn sig(this: lg&, params: std::vec<u32>&, ret: u32, va: bool) -> abi_fn {
    var a: abi_fn = { ret: this.part(ret, true), va: va };
    // the argument registers left: 6 INTEGER (one fewer with an sret pointer) and 8 SSE; a PIECES param
    // that doesn't fit whole goes by memory instead
    var ints: u32 = 6;
    var sses: u32 = 8;
    if (a.ret.how == pass::MEMORY) {
        ints -= 1;
    }
    for (p) in params.items() {
        var x = this.part(p, false);
        if (x.how == pass::PIECES) {
            val (ni, ns) = int_pieces(&x);
            if (ni <= ints && ns <= sses) {
                ints -= ni;
                sses -= ns;
            } else {
                x = { how: pass::MEMORY, ty: p };
            }
        } else if (x.how == pass::DIRECT) {
            val k = llvm::LLVMGetTypeKind(this.lt(p));
            if (k == llvm::LLVMIntegerTypeKind || k == llvm::LLVMPointerTypeKind) {
                // an i128 takes two, or goes on the stack whole and leaves the last one free
                var need: u32 = 1;
                if (int_bits(this.lt(p)) == 128) {
                    need = 2;
                }
                if (need <= ints) {
                    ints -= need;
                }
            } else if (sses > 0) {
                sses -= 1;
            }
        }
        put(&a.params, move x);
    }
    // the LLVM function type: an sret pointer first, then each param's lowered form
    var ps: std::vec<llvm::LLVMOpaqueType*> = {};
    if (a.ret.how == pass::MEMORY) {
        put(&ps, this.ptrt());
    }
    for (x&) in a.params.items() {
        this.param_types(x, &ps);
    }
    var rt = this.voidt();
    if (a.ret.how == pass::DIRECT) {
        rt = this.lt(ret);
    } else if (a.ret.how == pass::PIECES) {
        rt = this.pieces_ty(&a.ret);
    } else if (a.ret.how == pass::COERCE) {
        rt = a.ret.cty;
    }
    var v: i32 = 0;
    if (va) {
        v = 1;
    }
    a.ty = llvm::LLVMFunctionType(rt, ps.ptr, @cast<u32>(ps.len), v);
    return a;
}

// the LLVM param types x lowers to, appended to ps
attach fn param_types(this: lg&, x: abi_part&, ps: std::vec<llvm::LLVMOpaqueType*>&) -> void {
    if (x.how == pass::DIRECT) {
        put(ps, this.lt(x.ty));
    } else if (x.how == pass::PIECES) {
        for (p) in x.pieces.items() {
            put(ps, p);
        }
    } else if (x.how == pass::COERCE) {
        put(ps, x.cty);
    } else if (x.how == pass::MEMORY) {
        put(ps, this.ptrt());
    }
}

// one piece, or a pair of them as a struct (a returned PIECES value)
attach fn pieces_ty(this: lg&, x: abi_part&) -> llvm::LLVMOpaqueType* {
    if (x.pieces.len == 1) {
        return *x.pieces.at(0);
    }
    return struct_ty(this.ctx, &x.pieces, false);
}

attach fn attr(this: lg&, name: str) -> llvm::LLVMOpaqueAttributeRef* {
    val k = llvm::LLVMGetEnumAttributeKindForName(this.z(name), name.len);
    return llvm::LLVMCreateEnumAttribute(this.ctx, k, 0);
}

attach fn type_attr(this: lg&, name: str, t: llvm::LLVMOpaqueType*) -> llvm::LLVMOpaqueAttributeRef* {
    val k = llvm::LLVMGetEnumAttributeKindForName(this.z(name), name.len);
    return llvm::LLVMCreateTypeAttribute(this.ctx, k, t);
}

// the ABI's attributes (sret, byval, zeroext/signext, alignstack) on a function, or on a call when
// `call` is set
attach fn abi_attrs(this: lg&, a: abi_fn&, f: llvm::LLVMOpaqueValue*, call: bool) -> void {
    var idx: u32 = 1;
    if (a.ret.how == pass::MEMORY) {
        add_attr(f, call, 1, this.type_attr("sret", this.lt(a.ret.ty)));
        idx = 2;
    } else if (a.ret.how == pass::DIRECT && a.ret.ext != 0) {
        if (a.ret.ext == 1) {
            add_attr(f, call, 0, this.attr("zeroext"));
        } else {
            add_attr(f, call, 0, this.attr("signext"));
        }
    }
    for (x&) in a.params.items() {
        if (x.how == pass::DIRECT) {
            if (x.ext == 1) {
                add_attr(f, call, idx, this.attr("zeroext"));
            } else if (x.ext == 2) {
                add_attr(f, call, idx, this.attr("signext"));
            }
            idx += 1;
        } else if (x.how == pass::PIECES) {
            idx += @cast<u32>(x.pieces.len);
        } else if (x.how == pass::COERCE) {
            if (x.hfa && this.cc == callconv::AAPCS64) {
                // an HFA that ends up on the stack takes whole 8-byte slots, 16 for f128s (Apple's
                // packs them)
                var al: u64 = 8;
                if (this.align_of(llvm::LLVMGetElementType(x.cty)) > 8) {
                    al = 16;
                }
                add_attr(f, call, idx, llvm::LLVMCreateEnumAttribute(this.ctx, llvm::LLVMGetEnumAttributeKindForName("alignstack", 10), al));
            }
            idx += 1;
        } else if (x.how == pass::MEMORY) {
            // SysV and WebAssembly copy it (byval); elsewhere the pointer is to the caller's copy
            if (this.cc == callconv::SYSV || this.cc == callconv::WASM) {
                add_attr(f, call, idx, this.type_attr("byval", this.lt(x.ty)));
                val al = llvm::LLVMCreateEnumAttribute(this.ctx, llvm::LLVMGetEnumAttributeKindForName("align", 5), @cast<u64>(this.align_of(this.lt(x.ty))));
                add_attr(f, call, idx, al);
            }
            idx += 1;
        }
    }
}

fn add_attr(f: llvm::LLVMOpaqueValue*, call: bool, i: u32, at: llvm::LLVMOpaqueAttributeRef*) -> void {
    if (call) {
        llvm::LLVMAddCallSiteAttribute(f, i, at);
    } else {
        llvm::LLVMAddAttributeAtIndex(f, i, at);
    }
}

// ---------- functions, globals, constants ----------

// the symbol a function is linked under
attach fn symbol(this: lg&, f: ir_fn&) -> str {
    if (f.real_name) {
        return f.real_name;
    }
    if (f.prelude) {
        val a = this.aliases.get(f.name);
        if (a) {
            return *a;
        }
    }
    return f.name;
}

// fn i's lowered signature, made once and cached
attach fn fn_abi(this: lg&, i: u32) -> abi_fn {
    val have = this.abis.get(i);
    if (have) {
        return copy *have;
    }
    val f = this.c.ir.fn_at(i);
    // every libc function the prelude binds takes and gives size_t where Volt says usize, and size_t
    // is the pointer's width, as the C backend's prelude declares it: on a 32-bit target a usize
    // crosses as a u32 (which std/bare.volt's memcpy, memcmp and memset take)
    val narrow = f.prelude && this.aliases.get(f.name) != null && llvm::LLVMPointerSize(this.td) == 4;
    var ps: std::vec<u32> = {};
    for (p) in f.params.items() {
        put(&ps, size_t_as(f.locals.at(@cast<usize>(p)).ty, narrow));
    }
    val a = this.sig(&ps, size_t_as(f.ret, narrow), f.c_varargs);
    this.abis.put(i, copy a);
    return a;
}

// type t as a libc size_t crosses: u32 for a usize when narrow (a 32-bit target)
fn size_t_as(t: u32, narrow: bool) -> u32 {
    if (narrow && t == USIZE) {
        return U32;
    }
    return t;
}

// does a value of type t cross to C by value in a way only C knows: a header struct cimport marked
// (c_opaque), or a struct or array holding one
attach fn c_opaque(this: lg&, t: u32) -> bool {
    if (!this.c.c_opaque_any) {
        return false;
    }
    val have = this.opaques.get(t);
    if (have) {
        return *have;
    }
    var out = false;
    match (*this.c.t.get(t)) {
        .STRUCT(s) => {
            out = this.c.opaque_struct(s);
            if (!out && !this.c.header_struct(s)) {
                for (i) in 0..this.member_count(t) {
                    out = out || this.c_opaque(this.member_ty(t, @cast<u32>(i)));
                }
            }
        },
        .ARRAY(x, n) => { out = this.c_opaque(x); },
        default => {},
    }
    this.opaques.put(t, out);
    return out;
}

// is t a struct (a C shim takes one by pointer: cimport's by_value_struct)?
attach fn is_struct(this: lg&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => { return true; },
        default => { return false; },
    }
}

// the first of a signature's param types and result that only C can pass by value (c_opaque)
attach fn opaque_in(this: lg&, ps: std::vec<u32>&, r: u32) -> u32? {
    if (!this.c.c_opaque_any) {
        return null;
    }
    if (this.c_opaque(r)) {
        return r;
    }
    for (p) in ps.items() {
        if (this.c_opaque(p)) {
            return p;
        }
    }
    return null;
}

// ...of fn i's
attach fn opaque_fn(this: lg&, i: u32) -> u32? {
    if (!this.c.c_opaque_any) {
        return null;
    }
    val f = this.c.ir.fn_at(i);
    var ps: std::vec<u32> = {};
    for (p) in f.params.items() {
        put(&ps, f.locals.at(@cast<usize>(p)).ty);
    }
    return this.opaque_in(&ps, f.ret);
}

// the program can't go through this backend: why (the first reason found), and where in the source
// (main.volt's llvm_falls_back builds it through C instead)
attach fn cant(this: lg&, why: std::string) -> void {
    if (this.err.len() > 0) {
        return;
    }
    this.err = move why;
    if (this.at_line > 0) {
        this.err.append(fmt2(" ({}:{})", S(this.c.files.at(@cast<usize>(this.at_file)).name), unum(@cast<u64>(this.at_line))).as_str());
    }
}

// a C header's function, as a pointer: the runtime's C unit includes the headers and exports
// `void *volt_c_NAME = (void *)NAME;` (a static inline one has no symbol of its own)
attach fn header_fn(this: lg&, i: u32) -> llvm::LLVMOpaqueValue* {
    return this.header_ptr(this.symbol(this.c.ir.fn_at(i)));
}

// header fn i's C shim (cimport's shim: volt_cs_NAME, its structs by pointer), as header_fn's
// pointer; none written (a type it can't spell), the program goes through C
attach fn shim_fn(this: lg&, i: u32, bad: u32) -> llvm::LLVMOpaqueValue* {
    val sym = this.symbol(this.c.ir.fn_at(i));
    if (this.c.c_kept.get(sym) != null) {
        this.cant(fmt2("the C function '{}' takes or gives {} by value, which only C knows how to pass, and its header is kept out of Volt's C (another standard's), where no shim can reach it", S(sym), this.c.ty_name(bad)));
    } else if (this.c.c_shims.get(sym) == null) {
        this.cant(fmt2("the C function '{}' takes or gives {} by value, which only C knows how to pass, and voltc can't write the C shim that would pass it", S(sym), this.c.ty_name(bad)));
    }
    return this.header_ptr(this.c.intern(fmt("volt_cs_{}", S(sym))));
}

attach fn header_ptr(this: lg&, sym: str) -> llvm::LLVMOpaqueValue* {
    var n = S("volt_c_");
    n.append(sym);
    val name = this.z(n.as_str());
    var g = llvm::LLVMGetNamedGlobal(this.m, name);
    if (g == null) {
        g = llvm::LLVMAddGlobal(this.m, this.ptrt(), name);
        if (this.c.c_kept.get(sym) == null) {
            put(&this.hdr, sym); // (a header kept out of Volt's C has its own unit's pointer)
        }
    }
    val l = llvm::LLVMBuildLoad2(this.b, this.ptrt(), g, "");
    return l;
}

// fn i as an LLVM function, declared on first use with its ABI and attributes; a static fn with a
// body gets internal linkage
attach fn decl_fn(this: lg&, i: u32) -> llvm::LLVMOpaqueValue* {
    val have = this.fns.get(i);
    if (have) {
        return *have;
    }
    val f = this.c.ir.fn_at(i);
    val a = this.fn_abi(i);
    val name = this.z(this.symbol(f));
    var fv = llvm::LLVMGetNamedFunction(this.m, name);
    val fresh = fv == null;
    if (!fresh && (f.body != null || llvm::LLVMIsDeclaration(fv) == 0) && llvm::LLVMGlobalGetValueType(fv) != a.ty) {
        // two Volt fns bound to one C name with different signatures, one of them defined: the body
        // would read its params as the other's types, or calls would pass them so (T-0423's memcpy)
        @panic("voltc: a function's definition and another declaration of its C name disagree on its signature");
    }
    if (fresh) {
        fv = llvm::LLVMAddFunction(this.m, name, a.ty);
        if (f.link == linkage::STATIC && f.body != null && !f.prelude) {
            llvm::LLVMSetLinkage(fv, llvm::LLVMInternalLinkage);
        }
        this.abi_attrs(&a, fv ?? @panic("fn"), false);
    }
    // the attributes, also when the definition comes after the compiler declared it (rt_fn:
    // volt_panic, volt_bounds, memcpy... that std/bare.volt defines): without them those could
    // unwind (a reference to ARM's C++ unwinder), and bare metal's memcpy could call itself
    if (fresh || f.body != null) {
        if (f.noreturn || f.ret == NEVER) {
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("noreturn"));
        }
        if (f.body == null && is_builtin_math(this.symbol(f))) {
            // libm's sqrt, floor...: touching no memory (Volt never reads errno), so LLVM makes
            // them instructions
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, llvm::LLVMCreateEnumAttribute(this.ctx, llvm::LLVMGetEnumAttributeKindForName("memory", 6), 0));
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("nounwind"));
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("willreturn"));
        }
        if (f.body != null) {
            // Volt code never unwinds (a panic ends the program), as the C backend's C, which clang
            // marks nounwind: calls need no unwind paths, and LLVM moves code around them freely
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("nounwind"));
        }
        if (this.c.opts.target != null) {
            // bare metal has no C library: loops stay loops, not calls to strlen or memcpy (which
            // std/bare.volt's memcpy and the like would turn into calls to themselves)
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, llvm::LLVMCreateStringAttribute(this.ctx, "no-builtins", 11, "", 0));
        } else {
            // schedule for current chips, as clang does by default (on x86-64, not for the first ones)
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, llvm::LLVMCreateStringAttribute(this.ctx, "tune-cpu", 8, "generic", 7));
        }
        if (this.c.opts.line_info) {
            // --profiler and debug builds: bolt hot's sampler and debuggers walk the stack by frame pointers
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, llvm::LLVMCreateStringAttribute(this.ctx, "frame-pointer", 13, "all", 3));
        }
        val at = f.attrs;
        if (at.is_inline) {
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("alwaysinline"));
        }
        if (at.noinline) {
            llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("noinline"));
        }
        if (at.opt) {
            if (at.opt == "0") {
                llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("optnone"));
                llvm::LLVMAddAttributeAtIndex(fv, 4294967295, this.attr("noinline"));
            }
        }
        if (at.section) {
            llvm::LLVMSetSection(fv, this.z(at.section));
        }
        if (at.align) {
            llvm::LLVMSetAlignment(fv, @cast<u32>(lg_uint(at.align)));
        }
    }
    val v = fv ?? @panic("fn");
    this.fns.put(i, v);
    return v;
}

// the decimal digits in s as a number (anything else is skipped)
fn lg_uint(s: str) -> u64 {
    var v: u64 = 0;
    for (b) in s {
        if (b >= '0' && b <= '9') {
            v = v * 10 + @cast<u64>(b - '0');
        }
    }
    return v;
}

// the prelude's C declarations bound to libc symbols: `int volt_printf(...) VOLT_SYM("printf");`
attach fn read_aliases(this: lg&) -> void {
    val p = PRELUDE_H;
    var i: usize = 0;
    while (i < p.len) {
        var e = i;
        while (e < p.len && p[e] != '\n') {
            e += 1;
        }
        val line = p[i..e];
        i = e + 1;
        val at = lg_find(line, "VOLT_SYM(\"") ?? continue;
        val v = lg_find(line, "volt_") ?? continue;
        var ne = v;
        while (ne < line.len && line[ne] != '(') {
            ne += 1;
        }
        var q = at + 10;
        var qe = q;
        while (qe < line.len && line[qe] != '"') {
            qe += 1;
        }
        this.aliases.put(line[v..ne], line[q..qe]);
    }
}

// where `what` first occurs in s
fn lg_find(s: str, what: str) -> usize? {
    if (what.len > s.len) {
        return null;
    }
    for (i) in 0..s.len - what.len + 1 {
        if (s[i..i + what.len] == what) {
            return i;
        }
    }
    return null;
}

// a function to call, and how its args and result cross the call
struct callee {
    f: llvm::LLVMOpaqueValue*;
    abi: abi_fn;
}

// a runtime function (volt_panic, volt_out, ...): the prelude's C helpers, some variadic
attach fn rt_fn(this: lg&, name: str, args: std::vec<u32>&, ret: u32) -> callee {
    // args holds the argument types; volt_out and volt_dprintf are variadic after two fixed args
    var fixed = args.len;
    if (name == "volt_out" || name == "volt_dprintf") {
        fixed = 2;
    }
    var ps: std::vec<u32> = {};
    for (k) in 0..fixed {
        put(&ps, *args.at(k));
    }
    val a = this.sig(&ps, ret, fixed < args.len || name == "volt_out" || name == "volt_dprintf");
    var sym = name;
    val al = this.aliases.get(name);
    if (al) {
        sym = *al;
    }
    val zn = this.z(sym);
    var fv = llvm::LLVMGetNamedFunction(this.m, zn);
    if (fv == null) {
        fv = llvm::LLVMAddFunction(this.m, zn, a.ty);
        this.abi_attrs(&a, fv ?? @panic("rt"), false);
    }
    return { f: fv ?? @panic("rt"), abi: move a };
}

// global g as an LLVM global, defined here unless a header or another unit owns it. An initializer
// that isn't constant leaves it zeroed and queues it in ctors, to be set at startup
attach fn decl_global(this: lg&, g: u32) -> llvm::LLVMOpaqueValue* {
    val have = this.globals.get(g);
    if (have) {
        return *have;
    }
    val gl = this.c.ir.globals.at(@cast<usize>(g));
    var t = this.lt(gl.ty);
    var init: llvm::LLVMOpaqueValue* = null;
    val defined = !gl.header && gl.link != linkage::EXTERNAL;
    var by_ctor = false;
    if (defined) {
        if (gl.init) {
            init = this.cval(gl.init, gl.ty);
            if (init == null) {
                put(&this.ctors, g);
                by_ctor = true;
            }
        }
        if (init == null) {
            init = llvm::LLVMConstNull(t);
        }
        // a constant aggregate is a packed struct (see cval): the global takes that type
        t = llvm::LLVMTypeOf(init);
    }
    val name = this.z(gl.name);
    var v = llvm::LLVMGetNamedGlobal(this.m, name);
    if (v == null) {
        v = llvm::LLVMAddGlobal(this.m, t, name);
        val gv = v ?? @panic("global");
        if (gl.tls && this.c.opts.target == null) { // bare metal has one thread: a plain global
            llvm::LLVMSetThreadLocal(gv, 1);
        }
        if (defined) {
            llvm::LLVMSetInitializer(gv, init);
            llvm::LLVMSetAlignment(gv, this.align_of(this.lt(gl.ty)));
            // a val set by a constant never changes (the checker refuses writes, even through
            // this&): read-only data, in flash on bare metal rather than RAM
            if (!gl.mutable && !gl.tls && gl.init != null && !by_ctor) {
                llvm::LLVMSetGlobalConstant(gv, 1);
            }
            if (gl.link == linkage::STATIC) {
                llvm::LLVMSetLinkage(gv, llvm::LLVMInternalLinkage);
            }
            if (gl.section) {
                llvm::LLVMSetSection(gv, this.z(gl.section));
            }
        }
    }
    val r = v ?? @panic("global");
    this.globals.put(g, r);
    return r;
}

// a constant byte array (NUL-terminated) for a literal
attach fn lit_bytes(this: lg&, s: str) -> llvm::LLVMOpaqueValue* {
    val have = this.bytes.get(s);
    if (have) {
        return *have;
    }
    val init = llvm::LLVMConstStringInContext2(this.ctx, @cast<cstr>(s.ptr), s.len, 0);
    val g = llvm::LLVMAddGlobal(this.m, llvm::LLVMTypeOf(init), ".str");
    llvm::LLVMSetInitializer(g, init);
    llvm::LLVMSetGlobalConstant(g, 1);
    llvm::LLVMSetLinkage(g, llvm::LLVMPrivateLinkage);
    llvm::LLVMSetUnnamedAddress(g, llvm::LLVMGlobalUnnamedAddr);
    llvm::LLVMSetAlignment(g, 1);
    this.bytes.put(s, g);
    return g;
}

// a constant str: { pointer to the bytes, length }
attach fn str_const(this: lg&, s: str) -> llvm::LLVMOpaqueValue* {
    var vals: std::vec<llvm::LLVMOpaqueValue*> = {};
    put(&vals, this.lit_bytes(s));
    put(&vals, this.usizec(@cast<u64>(s.len)));
    return llvm::LLVMConstNamedStruct(this.lt(STR), vals.ptr, 2);
}

// an integer (or a float/pointer holding one) constant of type t
attach fn int_const(this: lg&, v: i128, t: u32) -> llvm::LLVMOpaqueValue* {
    val l = this.lt(t);
    val k = llvm::LLVMGetTypeKind(l);
    if (k == llvm::LLVMIntegerTypeKind) {
        if (llvm::LLVMGetIntTypeWidth(l) > 64) {
            var words: u64[2];
            val u = @cast<u128>(v);
            words[0] = @cast<u64>(u & 18446744073709551615);
            words[1] = @cast<u64>(u >> 64);
            return llvm::LLVMConstIntOfArbitraryPrecision(l, 2, &words[0]);
        }
        // exactly the type's bits: LLVM takes the u64 as is (without truncating it), so an i32's -1
        // passed as 0xFFFFFFFFFFFFFFFF would be a corrupt constant that folds wrongly
        val w = llvm::LLVMGetIntTypeWidth(l);
        var bits = @cast<u64>(@cast<u128>(v) & 18446744073709551615);
        if (w < 64) {
            bits &= (@cast<u64>(1) << @cast<u64>(w)) - 1;
        }
        return llvm::LLVMConstInt(l, bits, 0);
    }
    if (k == llvm::LLVMPointerTypeKind) {
        if (v == 0) {
            return llvm::LLVMConstNull(l);
        }
        return llvm::LLVMConstIntToPtr(llvm::LLVMConstInt(this.i64t(), @cast<u64>(v), 0), l);
    }
    if (k == llvm::LLVMFP128TypeKind) {
        return this.quad_const(std::softfloat::i128_to_f128(v), t); // exactly, past a double's 53 bits
    }
    return llvm::LLVMConstReal(l, @cast<f64>(v));
}

// an f128 constant of type t from its binary128 bits: an i128 constant bitcast, which LLVM folds
attach fn quad_const(this: lg&, q: u128, t: u32) -> llvm::LLVMOpaqueValue* {
    return llvm::LLVMConstBitCast(this.int_const(@cast<i128>(q), int_id(int_ty::U128)), this.lt(t));
}

// n as a constant of type t, when it is one (global initializers); null otherwise. Aggregates are
// packed structs with explicit padding at C's offsets, so any mix of member constants fits.
attach fn cval(this: lg&, n: u32, t: u32) -> llvm::LLVMOpaqueValue* {
    val nt = this.c.ir.ty_of(n);
    match (this.c.ir.at(n).kind) {
        .INT(v) => { return this.int_const(v, t); },
        .FLOAT(x) => { return llvm::LLVMConstReal(this.lt(t), x); },
        .QUAD(q) => { return this.quad_const(q, t); },
        .BOOL(b) => {
            var v: u64 = 0;
            if (b) {
                v = 1;
            }
            return llvm::LLVMConstInt(this.i8t(), v, 0);
        },
        .STR(s) => { return this.str_const(s); },
        .CSTR(s) => { return this.lit_bytes(s); },
        .NULLPTR => { return llvm::LLVMConstNull(this.lt(t)); },
        .ZERO => { return llvm::LLVMConstNull(this.lt(t)); },
        .FN(i) => { return this.decl_fn(i); },
        .GLOBAL(g) => {
            return null; // a copy of another global's value: at run time
        },
        .ADDR(p) => { return this.caddr(p); },
        .CONV(x) => {
            // an int converted at compile time, or a conversion that changes no LLVM type
            match (this.c.ir.at(x).kind) {
                .INT(v) => { return this.int_const(v, t); },
                default => {},
            }
            if (this.lt(nt) == this.lt(this.c.ir.ty_of(x))) {
                return this.cval(x, t);
            }
            return null;
        },
        .AGG(inits&) => {
            if (this.is_void(t)) {
                return null;
            }
            var vals: std::vec<llvm::LLVMOpaqueValue*> = {};
            var offs: std::vec<u64> = {};
            for (fi&) in inits.items() {
                val mt = this.member_ty(t, fi.field);
                if (this.is_void(mt)) {
                    continue;
                }
                val v = this.cval(fi.value, mt) ?? return null;
                put(&vals, v);
                put(&offs, this.offset_of(t, fi.field));
            }
            return this.packed(&vals, &offs, this.size_of(this.lt(t)));
        },
        .ARRAY_LIT(xs&) => {
            var et = VOID;
            match (*this.c.t.get(t)) {
                .ARRAY(x, k) => { et = x; },
                .VECTOR(x, k) => { et = x; },
                default => { return null; },
            }
            val es = this.size_of(this.lt(et));
            var vals: std::vec<llvm::LLVMOpaqueValue*> = {};
            var offs: std::vec<u64> = {};
            for (i) in 0..xs.len {
                val v = this.cval(*xs.at(i), et) ?? return null;
                put(&vals, v);
                put(&offs, @cast<u64>(i) * es);
            }
            return this.packed(&vals, &offs, this.size_of(this.lt(t)));
        },
        default => { return null; },
    }
}

// the address of a global place, as a constant
attach fn caddr(this: lg&, p: u32) -> llvm::LLVMOpaqueValue* {
    match (this.c.ir.at(p).kind) {
        .GLOBAL(g) => { return this.decl_global(g); },
        .FIELD(b, i) => {
            val base = this.caddr(b) ?? return null;
            val off = this.offset_of(this.c.ir.ty_of(b), i);
            var idx: std::vec<llvm::LLVMOpaqueValue*> = {};
            put(&idx, this.usizec(off));
            return llvm::LLVMConstGEP2(this.i8t(), base, idx.ptr, 1);
        },
        .INDEX(b, i) => {
            val base = this.caddr(b) ?? return null;
            var at: i128 = 0;
            match (this.c.ir.at(i).kind) {
                .INT(v) => { at = v; },
                default => { return null; },
            }
            val es = this.size_of(this.lt(this.c.ir.ty_of(p)));
            var idx: std::vec<llvm::LLVMOpaqueValue*> = {};
            put(&idx, this.usizec(@cast<u64>(at) * es));
            return llvm::LLVMConstGEP2(this.i8t(), base, idx.ptr, 1);
        },
        default => { return null; },
    }
}

// a packed struct of these constants at these offsets, padded to `size`
attach fn packed(this: lg&, vals: std::vec<llvm::LLVMOpaqueValue*>&, offs: std::vec<u64>&, size: u64) -> llvm::LLVMOpaqueValue* {
    var out: std::vec<llvm::LLVMOpaqueValue*> = {};
    var at: u64 = 0;
    for (i) in 0..vals.len {
        val o = *offs.at(i);
        if (o > at) {
            put(&out, llvm::LLVMConstNull(llvm::LLVMArrayType2(this.i8t(), o - at)));
        }
        val v = *vals.at(i);
        put(&out, v);
        at = o + llvm::LLVMStoreSizeOfType(this.td, llvm::LLVMTypeOf(v));
    }
    if (size > at) {
        put(&out, llvm::LLVMConstNull(llvm::LLVMArrayType2(this.i8t(), size - at)));
    }
    return llvm::LLVMConstStructInContext(this.ctx, out.ptr, @cast<u32>(out.len), 1);
}

// ---------- memory ----------

// a stack slot, made in the entry block
attach fn alloca(this: lg&, t: llvm::LLVMOpaqueType*) -> llvm::LLVMOpaqueValue* {
    val a = llvm::LLVMBuildAlloca(this.eb, t, "");
    llvm::LLVMSetAlignment(a, this.align_of(t));
    return a;
}

// a void value is null: loading one gives null and storing null does nothing
attach fn load(this: lg&, t: u32, p: llvm::LLVMOpaqueValue*) -> llvm::LLVMOpaqueValue* {
    if (this.is_void(t)) {
        return null;
    }
    val l = this.lt(t);
    val v = llvm::LLVMBuildLoad2(this.b, l, p, "");
    llvm::LLVMSetAlignment(v, this.align_of(l));
    return v;
}

attach fn store(this: lg&, v: llvm::LLVMOpaqueValue*, p: llvm::LLVMOpaqueValue*) -> void {
    if (v == null) {
        return;
    }
    // an aggregate's zero value is a memset, and a copy of one read from memory a memcpy: LLVM's
    // instruction selection breaks down on a big one loaded or stored whole (var buf: u8[65536];
    // var b = buf;)
    val t = llvm::LLVMTypeOf(v);
    val k = llvm::LLVMGetTypeKind(t);
    if (k == llvm::LLVMArrayTypeKind || k == llvm::LLVMStructTypeKind) {
        if (llvm::LLVMIsNull(v) != 0) {
            llvm::LLVMBuildMemSet(this.b, p, llvm::LLVMConstInt(this.i8t(), 0, 0), this.i64c(this.size_of(t)), this.align_of(t));
            return;
        }
        if (llvm::LLVMIsALoadInst(v) != null) {
            this.copy_loaded(v, p, t);
            return;
        }
    }
    val s = llvm::LLVMBuildStore(this.b, v, p);
    llvm::LLVMSetAlignment(s, this.align_of(t));
}

// store the aggregate that load ld read, as a memcpy from where it read it. Memory may have changed
// since the load (a call built after it), so unless the load is the last thing built, its bytes are
// first copied to a temporary right where the load is. The load goes if nothing else uses it.
attach fn copy_loaded(this: lg&, ld: llvm::LLVMOpaqueValue*, p: llvm::LLVMOpaqueValue*, t: llvm::LLVMOpaqueType*) -> void {
    var src = llvm::LLVMGetOperand(ld, 0);
    var src_align = llvm::LLVMGetAlignment(ld);
    val size = this.i64c(this.size_of(t));
    if (llvm::LLVMGetLastInstruction(llvm::LLVMGetInsertBlock(this.b)) != ld) {
        val tmp = this.alloca(t);
        val at = llvm::LLVMCreateBuilderInContext(this.ctx);
        val next = llvm::LLVMGetNextInstruction(ld);
        if (next != null) {
            llvm::LLVMPositionBuilderBefore(at, next);
        } else {
            llvm::LLVMPositionBuilderAtEnd(at, llvm::LLVMGetInstructionParent(ld));
        }
        llvm::LLVMBuildMemCpy(at, tmp, this.align_of(t), src, src_align, size);
        llvm::LLVMDisposeBuilder(at);
        src = tmp;
        src_align = this.align_of(t);
    }
    llvm::LLVMBuildMemCpy(this.b, p, this.align_of(t), src, src_align, size);
    if (llvm::LLVMGetFirstUse(ld) == null) {
        llvm::LLVMInstructionEraseFromParent(ld);
    }
}

// a value put in memory: its address
attach fn spill(this: lg&, v: llvm::LLVMOpaqueValue*, t: u32) -> llvm::LLVMOpaqueValue* {
    val a = this.alloca(this.lt(t));
    this.store(v, a);
    return a;
}

// p advanced by off bytes
attach fn byte_gep(this: lg&, p: llvm::LLVMOpaqueValue*, off: u64) -> llvm::LLVMOpaqueValue* {
    if (off == 0) {
        return p;
    }
    var idx: std::vec<llvm::LLVMOpaqueValue*> = {};
    put(&idx, this.usizec(off));
    return this.inbounds_gep(this.i8t(), p, &idx);
}

// an element or member address inside the object p points into: inbounds and nuw, which tells
// LLVM's alias analysis and loop passes the address stays in that object (an index past the end
// is undefined anyway: release builds don't check it, debug builds stop first)
attach fn inbounds_gep(this: lg&, ty: llvm::LLVMOpaqueType*, p: llvm::LLVMOpaqueValue*, idx: std::vec<llvm::LLVMOpaqueValue*>&) -> llvm::LLVMOpaqueValue* {
    val flags = @cast<u32>(llvm::LLVMGEPFlagInBounds) | @cast<u32>(llvm::LLVMGEPFlagNUW);
    return llvm::LLVMBuildGEPWithNoWrapFlags(this.b, ty, p, idx.ptr, @cast<u32>(idx.len), "", flags);
}

// the address of member i of the aggregate at p
attach fn field_ptr(this: lg&, agg: u32, p: llvm::LLVMOpaqueValue*, i: u32) -> llvm::LLVMOpaqueValue* {
    val off = this.overlay_offset(agg, i);
    if (off) {
        return this.byte_gep(p, off);
    }
    return llvm::LLVMBuildStructGEP2(this.b, this.lt(agg), p, this.elem(agg, i), "");
}

// ---------- control flow ----------

attach fn block(this: lg&) -> llvm::LLVMOpaqueBasicBlock* {
    return llvm::LLVMAppendBasicBlockInContext(this.ctx, this.f, "");
}

// has the current block ended (it has a terminator)?
attach fn done(this: lg&) -> bool {
    return llvm::LLVMGetBasicBlockTerminator(llvm::LLVMGetInsertBlock(this.b)) != null;
}

// branch to bb, unless the current block already ended
attach fn goto_(this: lg&, bb: llvm::LLVMOpaqueBasicBlock*) -> void {
    if (!this.done()) {
        llvm::LLVMBuildBr(this.b, bb);
    }
}

attach fn at_block(this: lg&, bb: llvm::LLVMOpaqueBasicBlock*) -> void {
    llvm::LLVMPositionBuilderAtEnd(this.b, bb);
}

// after a jump: later code (unreachable unless a label follows) goes in a fresh block
attach fn dead(this: lg&) -> void {
    this.at_block(this.block());
}

// the block for IR label l, made on first mention
attach fn label_bb(this: lg&, l: u32) -> llvm::LLVMOpaqueBasicBlock* {
    val have = this.labels.get(l);
    if (have) {
        return *have;
    }
    val bb = this.block();
    this.labels.put(l, bb);
    return bb;
}

// a bool (i8), int or pointer as an i1 for a branch: nonzero is true
attach fn truth(this: lg&, v: llvm::LLVMOpaqueValue*) -> llvm::LLVMOpaqueValue* {
    val t = llvm::LLVMTypeOf(v);
    if (t == this.i1t()) {
        return v;
    }
    return llvm::LLVMBuildICmp(this.b, llvm::LLVMIntNE, v, llvm::LLVMConstNull(t), "");
}

attach fn from_i1(this: lg&, v: llvm::LLVMOpaqueValue*) -> llvm::LLVMOpaqueValue* {
    return llvm::LLVMBuildZExt(this.b, v, this.i8t(), "");
}

// branch on node c; nothing when c diverged (no value, or the block already ended)
attach fn cond_br(this: lg&, c: u32, yes: llvm::LLVMOpaqueBasicBlock*, no: llvm::LLVMOpaqueBasicBlock*) -> void {
    val v = this.rv(c);
    if (v == null || this.done()) {
        return;
    }
    llvm::LLVMBuildCondBr(this.b, this.truth(v), yes, no);
}

// ---------- conversions ----------

attach fn kind(this: lg&, t: u32) -> i32 {
    return llvm::LLVMGetTypeKind(this.lt(t));
}

attach fn is_vector(this: lg&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .VECTOR(x, n) => { return true; },
        default => { return false; },
    }
}

// does vector t have signed int lanes?
attach fn signed_lanes(this: lg&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .VECTOR(x, n) => { return this.int_signed(x); },
        default => { return false; },
    }
}

// is t a vector of floats
attach fn fp_lanes(this: lg&, t: u32) -> bool {
    match (*this.c.t.get(t)) {
        .VECTOR(x, n) => { return this.is_fp(this.kind(x)); },
        default => { return false; },
    }
}

// is t a single LLVM value (not a struct or array)?
attach fn scalar(this: lg&, t: u32) -> bool {
    if (this.is_void(t)) {
        return false;
    }
    val k = this.kind(t);
    return k != llvm::LLVMStructTypeKind && k != llvm::LLVMArrayTypeKind;
}

attach fn is_fp(this: lg&, k: i32) -> bool {
    return k == llvm::LLVMHalfTypeKind || k == llvm::LLVMFloatTypeKind || k == llvm::LLVMDoubleTypeKind || k == llvm::LLVMFP128TypeKind;
}

// a scalar converted the way a C cast does it
attach fn convert(this: lg&, v: llvm::LLVMOpaqueValue*, from: u32, to: u32) -> llvm::LLVMOpaqueValue* {
    val fl = llvm::LLVMTypeOf(v);
    val tl = this.lt(to);
    if (to == BOOL && from != BOOL) {
        val fk = llvm::LLVMGetTypeKind(fl);
        if (this.is_fp(fk)) {
            return this.from_i1(llvm::LLVMBuildFCmp(this.b, llvm::LLVMRealUNE, v, llvm::LLVMConstNull(fl), ""));
        }
        return this.from_i1(this.truth(v));
    }
    if (fl == tl) {
        return v;
    }
    val fk = llvm::LLVMGetTypeKind(fl);
    val tk = llvm::LLVMGetTypeKind(tl);
    if (fk == llvm::LLVMIntegerTypeKind && tk == llvm::LLVMIntegerTypeKind) {
        val fw = llvm::LLVMGetIntTypeWidth(fl);
        val tw = llvm::LLVMGetIntTypeWidth(tl);
        if (tw < fw) {
            return llvm::LLVMBuildTrunc(this.b, v, tl, "");
        }
        if (this.int_signed(from)) {
            return llvm::LLVMBuildSExt(this.b, v, tl, "");
        }
        return llvm::LLVMBuildZExt(this.b, v, tl, "");
    }
    if (fk == llvm::LLVMIntegerTypeKind && this.is_fp(tk)) {
        if (this.int_signed(from)) {
            return llvm::LLVMBuildSIToFP(this.b, v, tl, "");
        }
        return llvm::LLVMBuildUIToFP(this.b, v, tl, "");
    }
    if (this.is_fp(fk) && tk == llvm::LLVMIntegerTypeKind) {
        if (this.int_signed(to)) {
            return llvm::LLVMBuildFPToSI(this.b, v, tl, "");
        }
        return llvm::LLVMBuildFPToUI(this.b, v, tl, "");
    }
    if (this.is_fp(fk) && this.is_fp(tk)) {
        if (this.size_of(tl) > this.size_of(fl)) {
            return llvm::LLVMBuildFPExt(this.b, v, tl, "");
        }
        return llvm::LLVMBuildFPTrunc(this.b, v, tl, "");
    }
    if (fk == llvm::LLVMPointerTypeKind && tk == llvm::LLVMIntegerTypeKind) {
        return llvm::LLVMBuildPtrToInt(this.b, v, tl, "");
    }
    if (fk == llvm::LLVMIntegerTypeKind && tk == llvm::LLVMPointerTypeKind) {
        return llvm::LLVMBuildIntToPtr(this.b, v, tl, "");
    }
    return this.reinterpret(v, from, to);
}

// the same bytes read as another type
attach fn reinterpret(this: lg&, v: llvm::LLVMOpaqueValue*, from: u32, to: u32) -> llvm::LLVMOpaqueValue* {
    var big = this.lt(from);
    if (this.size_of(this.lt(to)) > this.size_of(big)) {
        big = this.lt(to);
    }
    val a = this.alloca(big);
    this.store(v, a);
    return this.load(to, a);
}

// a value of type `from` where one of type `to` is wanted (C would convert it itself)
attach fn coerce(this: lg&, v: llvm::LLVMOpaqueValue*, from: u32, to: u32) -> llvm::LLVMOpaqueValue* {
    if (v == null || this.is_void(to) || from == NEVER) {
        return v;
    }
    if (llvm::LLVMTypeOf(v) == this.lt(to) && !(to == BOOL && from != BOOL)) {
        return v;
    }
    if (this.scalar(from) && this.scalar(to)) {
        return this.convert(v, from, to);
    }
    return this.reinterpret(v, from, to);
}

// node n's value as type t
attach fn rv_as(this: lg&, n: u32, t: u32) -> llvm::LLVMOpaqueValue* {
    return this.coerce(this.rv(n), this.c.ir.ty_of(n), t);
}

// ---------- places ----------

attach fn is_place(this: lg&, n: u32) -> bool {
    match (this.c.ir.at(n).kind) {
        .LOCAL(x) => { return true; },
        .GLOBAL(x) => { return true; },
        .FIELD(b, i) => { return true; },
        .DEREF(p) => { return true; },
        .INDEX(b, i) => { return true; },
        default => { return false; },
    }
}

// the address of a place; anything else is put in a temporary first
attach fn addr(this: lg&, n: u32) -> llvm::LLVMOpaqueValue* {
    val t = this.c.ir.ty_of(n);
    match (this.c.ir.at(n).kind) {
        .LOCAL(id) => { return *this.locals.at(@cast<usize>(id)); },
        .GLOBAL(g) => { return this.decl_global(g); },
        .DEREF(p) => { return this.rv(p); },
        .FIELD(b, i) => {
            val bt = this.c.ir.ty_of(b);
            val base = this.addr(b);
            if (this.is_union(bt) && i > 0) {
                return this.field_ptr(bt, base, 1);
            }
            return this.field_ptr(bt, base, i);
        },
        .INDEX(b, i) => {
            val bt = this.c.ir.ty_of(b);
            val ix = this.index_val(i);
            var idx: std::vec<llvm::LLVMOpaqueValue*> = {};
            match (*this.c.t.get(bt)) {
                .ARRAY(x, k) => {
                    put(&idx, this.usizec(0));
                    put(&idx, ix);
                    return this.inbounds_gep(this.lt(bt), this.addr(b), &idx);
                },
                .CSTR => {
                    put(&idx, ix);
                    return this.inbounds_gep(this.i8t(), this.rv(b), &idx);
                },
                .VECTOR(x, k) => {
                    // a lane: the vector's address stepped by lanes (its lanes are laid out in order)
                    put(&idx, ix);
                    return this.inbounds_gep(this.lt(x), this.addr(b), &idx);
                },
                default => {
                    put(&idx, ix);
                    return this.inbounds_gep(this.lt(t), this.rv(b), &idx);
                },
            }
        },
        default => {
            val v = this.rv(n);
            if (this.is_void(t) || v == null) {
                return this.alloca(this.i8t());
            }
            return this.spill(v, t);
        },
    }
}

// an index as a pointer-wide integer (what LLVM's address arithmetic is on the target)
attach fn index_val(this: lg&, i: u32) -> llvm::LLVMOpaqueValue* {
    return this.coerce(this.rv(i), this.c.ir.ty_of(i), ISIZE);
}

// ---------- values ----------

// node n's value; null when it has none (void, or it diverged)
attach fn rv(this: lg&, n: u32) -> llvm::LLVMOpaqueValue* {
    val t = this.c.ir.ty_of(n);
    match (this.c.ir.at(n).kind) {
        .INT(v) => { return this.int_const(v, t); },
        .FLOAT(x) => { return llvm::LLVMConstReal(this.lt(t), x); },
        .QUAD(q) => { return this.quad_const(q, t); },
        .BOOL(x) => {
            var v: u64 = 0;
            if (x) {
                v = 1;
            }
            return llvm::LLVMConstInt(this.i8t(), v, 0);
        },
        .STR(s) => { return this.str_const(s); },
        .CSTR(s) => { return this.lit_bytes(s); },
        .NULLPTR => { return llvm::LLVMConstNull(this.lt(t)); },
        .ZERO => {
            if (this.is_void(t)) {
                return null;
            }
            return llvm::LLVMConstNull(this.lt(t));
        },
        .LOCAL(id) => { return this.load(t, this.addr(n)); },
        .GLOBAL(g) => { return this.load(t, this.addr(n)); },
        .FIELD(b, i) => { return this.load(t, this.addr(n)); },
        .DEREF(p) => { return this.load(t, this.addr(n)); },
        .VLOAD(p) => {
            val v = this.load(t, this.rv(p));
            llvm::LLVMSetVolatile(v, 1);
            return v;
        },
        .VSTORE(p, x) => {
            val vt = this.c.ir.ty_of(x);
            val st = llvm::LLVMBuildStore(this.b, this.rv_as(x, vt), this.rv(p));
            llvm::LLVMSetAlignment(st, this.align_of(this.lt(vt)));
            llvm::LLVMSetVolatile(st, 1);
            return null;
        },
        .INDEX(b, i) => { return this.load(t, this.addr(n)); },
        .FN(i) => {
            val bad = this.opaque_fn(i);
            if (bad) {
                // C may call it through the pointer
                var name = this.c.ir.fn_at(i).about;
                if (name.len == 0) {
                    name = this.c.ir.fn_at(i).name;
                }
                this.cant(fmt2("the fn '{}' takes or gives {} by value, which only C knows how to pass, and is used as a function pointer", S(name), this.c.ty_name(bad)));
            }
            if (this.c.ir.fn_at(i).from_header) {
                return this.header_fn(i);
            }
            return this.decl_fn(i);
        },
        .RT(name) => {
            var none: std::vec<u32> = {};
            return this.rt_fn(name, &none, VOID).f;
        },
        .ADDR(p) => { return this.addr(p); },
        .UNARY(op, x) => {
            val v = this.rv(x);
            match (op) {
                .NOT => { return llvm::LLVMBuildXor(this.b, v, llvm::LLVMConstInt(this.i8t(), 1, 0), ""); },
                .BITNOT => { return llvm::LLVMBuildNot(this.b, v, ""); },
                .NEG => {
                    if (this.is_fp(this.kind(t)) || this.fp_lanes(t)) {
                        return llvm::LLVMBuildFNeg(this.b, v, "");
                    }
                    return llvm::LLVMBuildNeg(this.b, this.coerce(v, this.c.ir.ty_of(x), t), "");
                },
            }
        },
        .BINARY(op, a, b) => { return this.binary(op, a, b, t); },
        .CHECKED(op, a, b, loc) => { return this.checked(op, a, b, loc, t); },
        .CONV(x) => {
            val v = this.rv(x);
            if (v == null) {
                return null;
            }
            return this.convert(v, this.c.ir.ty_of(x), t);
        },
        .BITCAST(x) => {
            val v = this.rv(x);
            val xt = this.c.ir.ty_of(x);
            if (this.scalar(t) && this.scalar(xt) && this.is_fp(this.kind(t)) == this.is_fp(this.kind(xt))) {
                return this.convert(v, xt, t);
            }
            return this.reinterpret(v, xt, t);
        },
        .CALL(f, args&) => { return this.call(f, args, t); },
        .AGG(inits&) => { return this.agg(inits, t); },
        .ARRAY_LIT(xs&) => {
            var et = VOID;
            var lanes = false;
            match (*this.c.t.get(t)) {
                .ARRAY(x, k) => { et = x; },
                .VECTOR(x, k) => {
                    et = x;
                    lanes = true;
                },
                default => {},
            }
            var r = llvm::LLVMConstNull(this.lt(t));
            if (lanes) {
                for (i) in 0..xs.len {
                    val v = this.rv_as(*xs.at(i), et);
                    if (v != null) {
                        r = llvm::LLVMBuildInsertElement(this.b, r, v, this.i64c(@cast<u64>(i)), "");
                    }
                }
                return r;
            }
            for (i) in 0..xs.len {
                val v = this.rv_as(*xs.at(i), et);
                if (v != null) {
                    r = llvm::LLVMBuildInsertValue(this.b, r, v, @cast<u32>(i), "");
                }
            }
            return r;
        },
        .SEQ(stmts&, v) => {
            for (s) in stmts.items() {
                this.stmt(s);
            }
            if (v) {
                return this.rv(v);
            }
            return null;
        },
        .COND(c, a, b) => {
            // each arm stores into one slot, read back where they join (no phi)
            var slot: llvm::LLVMOpaqueValue* = null;
            if (!this.is_void(t)) {
                slot = this.alloca(this.lt(t));
            }
            val yes = this.block();
            val no = this.block();
            val end = this.block();
            this.cond_br(c, yes, no);
            this.at_block(yes);
            val av = this.rv_as(a, t);
            if (slot != null && av != null) {
                this.store(av, slot);
            }
            this.goto_(end);
            this.at_block(no);
            val bv = this.rv_as(b, t);
            if (slot != null && bv != null) {
                this.store(bv, slot);
            }
            this.goto_(end);
            this.at_block(end);
            if (slot == null) {
                return null;
            }
            return this.load(t, slot);
        },
        .SIZEOF(x) => { return this.usizec(this.size_of(this.lt(x))); },
        .ALIGNOF(x) => { return this.usizec(@cast<u64>(this.align_of(this.lt(x)))); },
        .OFFSETOF(x, i) => { return this.usizec(this.offset_of(x, i)); },
        default => {
            this.stmt(n);
            return null;
        },
    }
}

// an aggregate of type t from its field inits; members not given are zero
attach fn agg(this: lg&, inits: std::vec<field_init>&, t: u32) -> llvm::LLVMOpaqueValue* {
    if (this.is_void(t)) {
        return null;
    }
    if (this.is_union(t) || this.c_union(t) || this.overlay(t).0 > 0) {
        // payloads share memory: build it there
        val a = this.alloca(this.lt(t));
        this.store(llvm::LLVMConstNull(this.lt(t)), a);
        for (fi&) in inits.items() {
            val mt = this.member_ty(t, fi.field);
            val v = this.rv_as(fi.value, mt);
            if (this.is_void(mt) || v == null) {
                continue;
            }
            this.store(v, this.field_ptr(t, a, fi.field));
        }
        return this.load(t, a);
    }
    var r = llvm::LLVMConstNull(this.lt(t));
    for (fi&) in inits.items() {
        val mt = this.member_ty(t, fi.field);
        val v = this.rv_as(fi.value, mt);
        if (this.is_void(mt) || v == null) {
            continue;
        }
        r = llvm::LLVMBuildInsertValue(this.b, r, v, this.elem(t, fi.field), "");
    }
    return r;
}

attach fn is_ptr_ty(this: lg&, t: u32) -> bool {
    return !this.is_void(t) && this.kind(t) == llvm::LLVMPointerTypeKind;
}

// what a pointer steps over: T for T* and T&, a byte otherwise
attach fn pointee(this: lg&, t: u32) -> llvm::LLVMOpaqueType* {
    match (*this.c.t.get(t)) {
        .PTR(x) => {
            if (!this.is_void(x)) {
                return this.lt(x);
            }
        },
        .REF(x) => {
            if (!this.is_void(x)) {
                return this.lt(x);
            }
        },
        default => {},
    }
    return this.i8t();
}

// a BINARY node, converted to t; ints wrap (plain add/sub/mul) and signedness picks div, rem, shr, compares
attach fn binary(this: lg&, op: binop_ir, a: u32, b: u32, t: u32) -> llvm::LLVMOpaqueValue* {
    if (op == binop_ir::AND || op == binop_ir::OR) {
        // && and ||: the left side goes in a slot, and the right side runs (and overwrites it) only when the
        // left doesn't decide the result
        val slot = this.alloca(this.i8t());
        val av = this.rv(a);
        this.store(av, slot);
        val more = this.block();
        val end = this.block();
        if (!this.done()) {
            if (op == binop_ir::AND) {
                llvm::LLVMBuildCondBr(this.b, this.truth(av), more, end);
            } else {
                llvm::LLVMBuildCondBr(this.b, this.truth(av), end, more);
            }
        }
        this.at_block(more);
        this.store(this.rv(b), slot);
        this.goto_(end);
        this.at_block(end);
        return this.load(BOOL, slot);
    }
    val at = this.c.ir.ty_of(a);
    val bt = this.c.ir.ty_of(b);
    var av = this.rv(a);
    var bv = this.rv(b);
    if (av == null || bv == null) {
        return null;
    }
    val cmp = op == binop_ir::EQ || op == binop_ir::NE || op == binop_ir::LT || op == binop_ir::GT || op == binop_ir::LE || op == binop_ir::GE;
    if (this.is_vector(at)) {
        if (cmp) {
            // == when every lane is equal, != when any isn't (a NaN lane: unordered, so not equal)
            var m: llvm::LLVMOpaqueValue* = null;
            if (this.fp_lanes(at)) {
                var pred = llvm::LLVMRealOEQ;
                if (op == binop_ir::NE) {
                    pred = llvm::LLVMRealUNE;
                }
                m = llvm::LLVMBuildFCmp(this.b, pred, av, bv, "");
            } else {
                var pred = llvm::LLVMIntEQ;
                if (op == binop_ir::NE) {
                    pred = llvm::LLVMIntNE;
                }
                m = llvm::LLVMBuildICmp(this.b, pred, av, bv, "");
            }
            var name = "llvm.vector.reduce.and";
            if (op == binop_ir::NE) {
                name = "llvm.vector.reduce.or";
            }
            val id = llvm::LLVMLookupIntrinsicID(this.z(name), name.len);
            var tys: std::vec<llvm::LLVMOpaqueType*> = {};
            put(&tys, llvm::LLVMTypeOf(m));
            val fv = llvm::LLVMGetIntrinsicDeclaration(this.m, id, tys.ptr, 1);
            val fty = llvm::LLVMIntrinsicGetType(this.ctx, id, tys.ptr, 1);
            var args: std::vec<llvm::LLVMOpaqueValue*> = {};
            put(&args, m);
            return this.from_i1(llvm::LLVMBuildCall2(this.b, fty, fv, args.ptr, 1, ""));
        }
        // lane by lane: + - * / on float lanes, + - * & | ^ << >> on int lanes (the checker allows no
        // more, and keeps every shift amount under the width)
        if (this.fp_lanes(at)) {
            match (op) {
                .ADD => { return llvm::LLVMBuildFAdd(this.b, av, bv, ""); },
                .SUB => { return llvm::LLVMBuildFSub(this.b, av, bv, ""); },
                .MUL => { return llvm::LLVMBuildFMul(this.b, av, bv, ""); },
                default => { return llvm::LLVMBuildFDiv(this.b, av, bv, ""); },
            }
        }
        match (op) {
            .ADD => { return llvm::LLVMBuildAdd(this.b, av, bv, ""); },
            .SUB => { return llvm::LLVMBuildSub(this.b, av, bv, ""); },
            .MUL => { return llvm::LLVMBuildMul(this.b, av, bv, ""); },
            .BITAND => { return llvm::LLVMBuildAnd(this.b, av, bv, ""); },
            .BITOR => { return llvm::LLVMBuildOr(this.b, av, bv, ""); },
            .SHL => { return llvm::LLVMBuildShl(this.b, av, bv, ""); },
            .SHR => {
                if (this.signed_lanes(at)) {
                    return llvm::LLVMBuildAShr(this.b, av, bv, "");
                }
                return llvm::LLVMBuildLShr(this.b, av, bv, "");
            },
            default => { return llvm::LLVMBuildXor(this.b, av, bv, ""); },
        }
    }
    // pointers: p + n and p - n step by elements, p - q counts them, comparisons are unsigned
    if (this.is_ptr_ty(at)) {
        if (cmp) {
            if (!this.is_ptr_ty(bt)) {
                bv = this.coerce(bv, bt, at);
            }
            return this.from_i1(llvm::LLVMBuildICmp(this.b, this.int_pred(op, false), av, bv, ""));
        }
        val el = this.pointee(at);
        if (this.is_ptr_ty(bt)) {
            val wide = this.int_lt(int_ty::ISIZE);
            val d = llvm::LLVMBuildSub(this.b, llvm::LLVMBuildPtrToInt(this.b, av, wide, ""), llvm::LLVMBuildPtrToInt(this.b, bv, wide, ""), "");
            val q = llvm::LLVMBuildExactSDiv(this.b, d, this.usizec(this.size_of(el)), "");
            return this.convert(q, ISIZE, t);
        }
        var n = this.coerce(bv, bt, ISIZE);
        if (op == binop_ir::SUB) {
            n = llvm::LLVMBuildNeg(this.b, n, "");
        }
        var idx: std::vec<llvm::LLVMOpaqueValue*> = {};
        put(&idx, n);
        return llvm::LLVMBuildGEP2(this.b, el, av, idx.ptr, 1, "");
    }
    val ak = this.kind(at);
    if (this.is_fp(ak)) {
        if (bt != at) {
            bv = this.coerce(bv, bt, at);
        }
        if (cmp) {
            return this.from_i1(llvm::LLVMBuildFCmp(this.b, this.real_pred(op), av, bv, ""));
        }
        var r: llvm::LLVMOpaqueValue* = null;
        match (op) {
            .ADD => { r = llvm::LLVMBuildFAdd(this.b, av, bv, ""); },
            .SUB => { r = llvm::LLVMBuildFSub(this.b, av, bv, ""); },
            .MUL => { r = llvm::LLVMBuildFMul(this.b, av, bv, ""); },
            .DIV => { r = llvm::LLVMBuildFDiv(this.b, av, bv, ""); },
            default => { r = llvm::LLVMBuildFRem(this.b, av, bv, ""); },
        }
        return this.coerce(r, at, t);
    }
    // integers (and bools, enum tags, error codes): the right side in the left's type
    if (llvm::LLVMTypeOf(bv) != llvm::LLVMTypeOf(av)) {
        if (this.is_ptr_ty(bt)) {
            av = this.coerce(av, at, bt);
        } else {
            bv = this.coerce(bv, bt, at);
        }
    }
    val sg = this.int_signed(at);
    if (cmp) {
        return this.from_i1(llvm::LLVMBuildICmp(this.b, this.int_pred(op, sg), av, bv, ""));
    }
    var r: llvm::LLVMOpaqueValue* = null;
    match (op) {
        .ADD => { r = llvm::LLVMBuildAdd(this.b, av, bv, ""); },
        .SUB => { r = llvm::LLVMBuildSub(this.b, av, bv, ""); },
        .MUL => { r = llvm::LLVMBuildMul(this.b, av, bv, ""); },
        .DIV => {
            if (sg) {
                r = llvm::LLVMBuildSDiv(this.b, av, bv, "");
            } else {
                r = llvm::LLVMBuildUDiv(this.b, av, bv, "");
            }
        },
        .REM => {
            if (sg) {
                r = llvm::LLVMBuildSRem(this.b, av, bv, "");
            } else {
                r = llvm::LLVMBuildURem(this.b, av, bv, "");
            }
        },
        .BITAND => { r = llvm::LLVMBuildAnd(this.b, av, bv, ""); },
        .BITOR => { r = llvm::LLVMBuildOr(this.b, av, bv, ""); },
        .BITXOR => { r = llvm::LLVMBuildXor(this.b, av, bv, ""); },
        .SHL => { r = llvm::LLVMBuildShl(this.b, av, bv, ""); },
        .SHR => {
            if (sg) {
                r = llvm::LLVMBuildAShr(this.b, av, bv, "");
            } else {
                r = llvm::LLVMBuildLShr(this.b, av, bv, "");
            }
        },
        default => { return null; },
    }
    return this.coerce(r, at, t);
}

// the LLVM predicate for a comparison op
attach fn int_pred(this: lg&, op: binop_ir, sg: bool) -> i32 {
    match (op) {
        .EQ => { return llvm::LLVMIntEQ; },
        .NE => { return llvm::LLVMIntNE; },
        .LT => {
            if (sg) {
                return llvm::LLVMIntSLT;
            }
            return llvm::LLVMIntULT;
        },
        .GT => {
            if (sg) {
                return llvm::LLVMIntSGT;
            }
            return llvm::LLVMIntUGT;
        },
        .LE => {
            if (sg) {
                return llvm::LLVMIntSLE;
            }
            return llvm::LLVMIntULE;
        },
        default => {
            if (sg) {
                return llvm::LLVMIntSGE;
            }
            return llvm::LLVMIntUGE;
        },
    }
}

attach fn real_pred(this: lg&, op: binop_ir) -> i32 {
    match (op) {
        .EQ => { return llvm::LLVMRealOEQ; },
        .NE => { return llvm::LLVMRealUNE; },
        .LT => { return llvm::LLVMRealOLT; },
        .GT => { return llvm::LLVMRealOGT; },
        .LE => { return llvm::LLVMRealOLE; },
        default => { return llvm::LLVMRealOGE; },
    }
}

// a + b, a - b, a * b that panic on overflow
attach fn checked(this: lg&, op: binop_ir, a: u32, b: u32, loc: str, t: u32) -> llvm::LLVMOpaqueValue* {
    val av = this.rv_as(a, t);
    val bv = this.rv_as(b, t);
    var name = S("llvm.");
    if (this.int_signed(t)) {
        name.push('s');
    } else {
        name.push('u');
    }
    match (op) {
        .SUB => { name.append("sub"); },
        .MUL => { name.append("mul"); },
        default => { name.append("add"); },
    }
    name.append(".with.overflow");
    val id = llvm::LLVMLookupIntrinsicID(this.z(name.as_str()), name.len());
    var tys: std::vec<llvm::LLVMOpaqueType*> = {};
    put(&tys, this.lt(t));
    val fv = llvm::LLVMGetIntrinsicDeclaration(this.m, id, tys.ptr, 1);
    val fty = llvm::LLVMIntrinsicGetType(this.ctx, id, tys.ptr, 1);
    var args: std::vec<llvm::LLVMOpaqueValue*> = {};
    put(&args, av);
    put(&args, bv);
    val r = llvm::LLVMBuildCall2(this.b, fty, fv, args.ptr, 2, "");
    val ov = llvm::LLVMBuildExtractValue(this.b, r, 1, "");
    val bad = this.block();
    val ok = this.block();
    llvm::LLVMBuildCondBr(this.b, ov, bad, ok);
    this.at_block(bad);
    this.panic("integer overflow", loc);
    this.at_block(ok);
    return llvm::LLVMBuildExtractValue(this.b, r, 0, "");
}

// a call to volt_panic(msg, loc), which ends the block
attach fn panic(this: lg&, msg: str, loc: str) -> void {
    var ats: std::vec<u32> = {};
    put(&ats, CSTR);
    put(&ats, CSTR);
    val r = this.rt_fn("volt_panic", &ats, NEVER);
    var args: std::vec<llvm::LLVMOpaqueValue*> = {};
    put(&args, this.lit_bytes(msg));
    put(&args, this.lit_bytes(loc));
    llvm::LLVMBuildCall2(this.b, r.abi.ty, r.f, args.ptr, 2, "");
    llvm::LLVMBuildUnreachable(this.b);
}

// ---------- calls ----------

// a call of node f with these args; the result comes back per the ABI (sret slot, pieces or direct)
attach fn call(this: lg&, f: u32, args: std::vec<u32>&, t: u32) -> llvm::LLVMOpaqueValue* {
    var target: llvm::LLVMOpaqueValue* = null;
    var a: abi_fn = { ret: { how: pass::NONE } };
    var ptys: std::vec<u32> = {}; // the fixed params' types (args are converted to them)
    var ats: std::vec<u32> = {};
    for (x) in args.items() {
        put(&ats, this.c.ir.ty_of(x));
    }
    // a call of a header fn's C shim: the struct result's slot, and the structs passed by pointer
    var shim = false;
    var shim_slot: llvm::LLVMOpaqueValue* = null;
    match (this.c.ir.at(f).kind) {
        .FN(i) => {
            val fi = this.c.ir.fn_at(i);
            val bad = this.opaque_fn(i);
            if (bad != null && fi.from_header) {
                // C passes a struct here its own way: its shim takes them all by pointer, the
                // result's first (an sret pointer, as the ABI passes one)
                shim = true;
                target = this.shim_fn(i, bad ?? 0);
                if (this.is_struct(fi.ret)) {
                    shim_slot = this.alloca(this.lt(fi.ret));
                    put(&ptys, VOIDPTR);
                }
                for (p) in fi.params.items() {
                    val pt = fi.locals.at(@cast<usize>(p)).ty;
                    if (this.is_struct(pt)) {
                        put(&ptys, VOIDPTR);
                    } else {
                        put(&ptys, pt);
                    }
                }
                var rt = fi.ret;
                if (shim_slot != null) {
                    rt = VOID;
                }
                a = this.sig(&ptys, rt, false);
            } else {
                if (bad != null && fi.body == null && !fi.prelude) {
                    this.cant(fmt2("the C function '{}' takes or gives {} by value, which only C knows how to pass, and isn't a header's (voltc writes a C shim for a header's function only)", S(this.symbol(fi)), this.c.ty_name(bad ?? 0)));
                }
                if (fi.from_header) {
                    target = this.header_fn(i);
                } else {
                    target = this.decl_fn(i);
                }
                a = this.fn_abi(i);
                for (p&) in a.params.items() {
                    put(&ptys, p.ty); // the ABI's: a libc size_t can be narrower than usize
                }
            }
        },
        .RT(name) => {
            val r = this.rt_fn(name, &ats, t);
            target = r.f;
            a = copy r.abi;
            for (k) in 0..a.params.len {
                put(&ptys, *ats.at(k));
            }
        },
        default => {
            val ft = this.c.ir.ty_of(f);
            match (*this.c.t.get(ft)) {
                .FN_PTR(ps, r, va) => {
                    ptys = copy ps;
                    val bad = this.opaque_in(&ptys, r);
                    if (bad) {
                        this.cant(fmt("a call through a C function pointer passes {} by value, which only C knows how to pass", this.c.ty_name(bad)));
                    }
                    a = this.sig(&ptys, r, va);
                },
                default => {
                    // a fn(...) value's fn slot: env first, then the call's own arguments
                    ptys = copy ats;
                    a = this.sig(&ptys, t, false);
                },
            }
            target = this.rv(f);
        },
    }
    // arguments: fixed ones by the ABI, variadic ones promoted as C does
    var vals: std::vec<llvm::LLVMOpaqueValue*> = {};
    var extra: std::vec<abi_part> = {}; // the variadic arguments' parts
    var ret_slot: llvm::LLVMOpaqueValue* = null;
    if (a.ret.how == pass::MEMORY) {
        ret_slot = this.alloca(this.lt(a.ret.ty));
        put(&vals, ret_slot ?? @panic("sret"));
    }
    var off: usize = 0;
    if (shim_slot != null) {
        put(&vals, shim_slot ?? @panic("shim"));
        off = 1;
    }
    for (k) in 0..args.len {
        val n = *args.at(k);
        if (k + off < a.params.len) {
            val p = a.params.at(k + off);
            if (shim && this.is_struct(*ats.at(k))) {
                // by a pointer to a copy
                put(&vals, this.spill(this.rv(n), *ats.at(k)));
                continue;
            }
            val v = this.rv_as(n, *ptys.at(k + off));
            this.pass_arg(p, v, &vals);
        } else {
            var at = *ats.at(k);
            if (this.is_void(at)) {
                this.rv(n);
                continue;
            }
            if (this.c_opaque(at)) {
                this.cant(fmt("a variadic call passes {} by value, which only C knows how to pass", this.c.ty_name(at)));
            }
            var v = this.rv(n);
            // default argument promotions
            val lk = this.kind(at);
            if (lk == llvm::LLVMFloatTypeKind || lk == llvm::LLVMHalfTypeKind) {
                v = this.convert(v, at, F64);
                at = F64;
            } else if (lk == llvm::LLVMIntegerTypeKind && llvm::LLVMGetIntTypeWidth(this.lt(at)) < 32) {
                if (this.int_signed(at)) {
                    v = this.convert(v, at, I32);
                } else {
                    v = llvm::LLVMBuildZExt(this.b, v, this.i32t(), "");
                }
                at = I32;
            }
            val p = this.part(at, false);
            this.pass_arg(&p, v, &vals);
            put(&extra, move p);
        }
    }
    val c = llvm::LLVMBuildCall2(this.b, a.ty, target, vals.ptr, @cast<u32>(vals.len), "");
    var all = copy a;
    for (x&) in extra.items() {
        put(&all.params, copy *x); // a variadic struct in memory is a byval copy too
    }
    this.abi_attrs(&all, c, true);
    if (shim_slot != null) {
        return this.load(t, shim_slot ?? @panic("shim"));
    }
    // a call that never returns ends the block
    if (t == NEVER) {
        llvm::LLVMBuildUnreachable(this.b);
        this.dead();
        return null;
    }
    if (a.ret.how == pass::MEMORY) {
        return this.load(t, ret_slot ?? @panic("sret"));
    }
    if (a.ret.how == pass::PIECES) {
        val slot = this.alloca(this.lt(t));
        this.store_pieces(&a.ret, c, slot);
        return this.load(t, slot);
    }
    if (a.ret.how == pass::COERCE) {
        val slot = this.coerce_slot(&a.ret);
        llvm::LLVMBuildStore(this.b, c, slot);
        return this.load(t, slot);
    }
    if (a.ret.how == pass::NONE) {
        return null;
    }
    return this.coerce(c, a.ret.ty, t); // (a libc size_t result widens to usize)
}

// one argument, the ABI's way
attach fn pass_arg(this: lg&, p: abi_part&, v: llvm::LLVMOpaqueValue*, vals: std::vec<llvm::LLVMOpaqueValue*>&) -> void {
    if (p.how == pass::NONE) {
        return;
    }
    if (p.how == pass::DIRECT) {
        put(vals, v);
        return;
    }
    if (p.how == pass::COERCE) {
        val slot = this.coerce_slot(p);
        this.store(v, slot);
        put(vals, llvm::LLVMBuildLoad2(this.b, p.cty, slot, ""));
        return;
    }
    val mem = this.spill(v, p.ty);
    if (p.how == pass::MEMORY) {
        put(vals, mem);
        return;
    }
    for (k) in 0..p.pieces.len {
        val pt = *p.pieces.at(k);
        val l = llvm::LLVMBuildLoad2(this.b, pt, this.byte_gep(mem, @cast<u64>(k) * 8), "");
        llvm::LLVMSetAlignment(l, 1);
        put(vals, l);
    }
}

// a returned PIECES value (one scalar or a pair) stored into memory
attach fn store_pieces(this: lg&, p: abi_part&, v: llvm::LLVMOpaqueValue*, mem: llvm::LLVMOpaqueValue*) -> void {
    if (p.pieces.len == 1) {
        val s = llvm::LLVMBuildStore(this.b, v, mem);
        llvm::LLVMSetAlignment(s, 1);
        return;
    }
    for (k) in 0..p.pieces.len {
        val x = llvm::LLVMBuildExtractValue(this.b, v, @cast<u32>(k), "");
        val s = llvm::LLVMBuildStore(this.b, x, this.byte_gep(mem, @cast<u64>(k) * 8));
        llvm::LLVMSetAlignment(s, 1);
    }
}

// ---------- statements ----------

// lowers statement n into the current block; code after a jump goes in a fresh block (dead)
attach fn stmt(this: lg&, n: u32) -> void {
    match (this.c.ir.at(n).kind) {
        .DECL(l, init) => {
            if (init) {
                val lt2 = this.c.ir.fn_at(this.fn_idx).locals.at(@cast<usize>(l)).ty;
                val v = this.rv_as(init, lt2);
                if (!this.is_void(lt2) && v != null) {
                    this.store(v, *this.locals.at(@cast<usize>(l)));
                }
            }
        },
        .ASSIGN(p, v) => {
            val pt = this.c.ir.ty_of(p);
            val x = this.rv_as(v, pt);
            if (this.is_void(pt) || x == null) {
                return;
            }
            this.store(x, this.addr(p));
        },
        .IF(c, a, b) => {
            val yes = this.block();
            val end = this.block();
            var no = end;
            if (b) {
                no = this.block();
            }
            this.cond_br(c, yes, no);
            this.at_block(yes);
            this.stmt(a);
            this.goto_(end);
            if (b) {
                this.at_block(no);
                this.stmt(b);
                this.goto_(end);
            }
            this.at_block(end);
        },
        .LOOP(body) => {
            val top = this.block();
            this.goto_(top);
            this.at_block(top);
            this.stmt(body);
            this.goto_(top);
            this.dead();
        },
        .LABEL(l) => {
            val bb = this.label_bb(l);
            this.goto_(bb);
            this.at_block(bb);
        },
        .GOTO(l) => {
            this.goto_(this.label_bb(l));
            this.dead();
        },
        .SWITCH(v, cases&, d) => {
            val x = this.rv(v);
            val end = this.block();
            var dflt = end;
            if (d) {
                dflt = this.block();
            }
            val vt = this.c.ir.ty_of(v);
            val sw = llvm::LLVMBuildSwitch(this.b, x, dflt, @cast<u32>(cases.len));
            for (c&) in cases.items() {
                val bb = this.block();
                llvm::LLVMAddCase(sw, this.int_const(c.value, vt), bb);
                this.at_block(bb);
                this.stmt(c.body);
                this.goto_(end);
            }
            if (d) {
                this.at_block(dflt);
                this.stmt(d);
                this.goto_(end);
            }
            this.at_block(end);
        },
        .RETURN(v) => {
            this.ret(v);
            this.dead();
        },
        .BLOCK(stmts&) => {
            for (s) in stmts.items() {
                this.stmt(s);
            }
        },
        .UNREACHABLE => {
            llvm::LLVMBuildUnreachable(this.b);
            this.dead();
        },
        .TRAP => {
            // llvm.trap is an instruction (ud2, udf, unimp), not a call
            val name = "llvm.trap";
            val id = llvm::LLVMLookupIntrinsicID(this.z(name), name.len);
            var tys: std::vec<llvm::LLVMOpaqueType*> = {};
            val fv = llvm::LLVMGetIntrinsicDeclaration(this.m, id, tys.ptr, 0);
            val fty = llvm::LLVMIntrinsicGetType(this.ctx, id, tys.ptr, 0);
            var args: std::vec<llvm::LLVMOpaqueValue*> = {};
            llvm::LLVMBuildCall2(this.b, fty, fv, args.ptr, 0, "");
            llvm::LLVMBuildUnreachable(this.b);
            this.dead();
        },
        .AT(f, l) => {
            this.at_file = f;
            this.at_line = l;
            this.di_at(f, l);
        },
        default => { this.rv(n); },
    }
}

// returns v from the current fn per its ABI: directly, through the sret slot, or as pieces
attach fn ret(this: lg&, v: u32?) -> void {
    val f = this.c.ir.fn_at(this.fn_idx);
    val a = &this.abi;
    var x: llvm::LLVMOpaqueValue* = null;
    if (v) {
        x = this.rv_as(v, f.ret);
    }
    if (this.done()) {
        return;
    }
    if (a.ret.how == pass::NONE || x == null) {
        if (a.ret.how == pass::NONE || a.ret.how == pass::MEMORY) {
            llvm::LLVMBuildRetVoid(this.b);
        } else {
            llvm::LLVMBuildUnreachable(this.b);
        }
        return;
    }
    if (a.ret.how == pass::DIRECT) {
        llvm::LLVMBuildRet(this.b, x);
    } else if (a.ret.how == pass::MEMORY) {
        this.store(x, this.sret);
        llvm::LLVMBuildRetVoid(this.b);
    } else if (a.ret.how == pass::COERCE) {
        val slot = this.coerce_slot(&a.ret);
        this.store(x, slot);
        llvm::LLVMBuildRet(this.b, llvm::LLVMBuildLoad2(this.b, a.ret.cty, slot, ""));
    } else {
        val mem = this.spill(x, f.ret);
        if (a.ret.pieces.len == 1) {
            val l = llvm::LLVMBuildLoad2(this.b, *a.ret.pieces.at(0), mem, "");
            llvm::LLVMSetAlignment(l, 1);
            llvm::LLVMBuildRet(this.b, l);
        } else {
            var r = llvm::LLVMGetUndef(this.pieces_ty(&a.ret));
            for (k) in 0..a.ret.pieces.len {
                val l = llvm::LLVMBuildLoad2(this.b, *a.ret.pieces.at(k), this.byte_gep(mem, @cast<u64>(k) * 8), "");
                llvm::LLVMSetAlignment(l, 1);
                r = llvm::LLVMBuildInsertValue(this.b, r, l, @cast<u32>(k), "");
            }
            llvm::LLVMBuildRet(this.b, r);
        }
    }
}

// ---------- functions ----------

// fn i's body; allocas go in their own first block, which branches to the code once it is done
attach fn fn_body(this: lg&, i: u32) -> void {
    this.fn_idx = i;
    this.f = this.decl_fn(i);
    this.abi = this.fn_abi(i);
    this.labels = {};
    this.locals = {};
    val f = this.c.ir.fn_at(i);
    val allocas = this.block();
    val start = this.block();
    llvm::LLVMPositionBuilderAtEnd(this.eb, allocas);
    this.at_block(start);
    this.di_fn(f);
    this.at_line = 0;
    if (f.origin) {
        val o = f.origin;
        this.at_file = o.file;
        this.at_line = @cast<u32>(this.c.line_col(o).line);
    }
    if (f.link == linkage::EXPORTED) {
        val bad = this.opaque_fn(i);
        if (bad) {
            this.cant(fmt2("the exported fn '{}' takes or gives {} by value, which only C knows how to pass", S(this.symbol(f)), this.c.ty_name(bad)));
        }
    }
    // one stack slot per local (a byte for void ones, so every local has an address)
    for (k) in 0..f.locals.len {
        val l = f.locals.at(k);
        if (this.is_void(l.ty)) {
            put(&this.locals, this.alloca(this.i8t()));
        } else {
            put(&this.locals, this.alloca(this.lt(l.ty)));
        }
    }
    // the parameters into their locals
    val a = &this.abi;
    var pi: u32 = 0;
    this.sret = null;
    if (a.ret.how == pass::MEMORY) {
        this.sret = llvm::LLVMGetParam(this.f, 0);
        pi = 1;
    }
    for (k) in 0..f.params.len {
        val li = @cast<usize>(*f.params.at(k));
        val p = a.params.at(k);
        if (p.how == pass::DIRECT) {
            this.store(llvm::LLVMGetParam(this.f, pi), *this.locals.at(li));
            pi += 1;
        } else if (p.how == pass::MEMORY) {
            *this.locals.at(li) = llvm::LLVMGetParam(this.f, pi);
            pi += 1;
        } else if (p.how == pass::COERCE) {
            val slot = this.coerce_slot(p);
            llvm::LLVMBuildStore(this.b, llvm::LLVMGetParam(this.f, pi), slot);
            *this.locals.at(li) = slot;
            pi += 1;
        } else if (p.how == pass::PIECES) {
            val mem = *this.locals.at(li);
            for (j) in 0..p.pieces.len {
                val s = llvm::LLVMBuildStore(this.b, llvm::LLVMGetParam(this.f, pi), this.byte_gep(mem, @cast<u64>(j) * 8));
                llvm::LLVMSetAlignment(s, 1);
                pi += 1;
            }
        }
    }
    this.di_locals(f, allocas);
    if (f.body) {
        this.stmt(f.body);
    }
    // falling off the end: return nothing, 0 from main, or it can't happen
    if (!this.done()) {
        if (a.ret.how == pass::NONE || a.ret.how == pass::MEMORY) {
            llvm::LLVMBuildRetVoid(this.b);
        } else if (f.name == "main" && f.link == linkage::EXPORTED) {
            llvm::LLVMBuildRet(this.b, llvm::LLVMConstInt(this.i32t(), 0, 0));
        } else {
            llvm::LLVMBuildUnreachable(this.b);
        }
    }
    llvm::LLVMPositionBuilderAtEnd(this.eb, allocas);
    llvm::LLVMBuildBr(this.eb, start);
    // blocks nothing jumps to still need an end
    var bb = llvm::LLVMGetFirstBasicBlock(this.f);
    while (bb != null) {
        val blk = bb ?? @panic("bb");
        if (llvm::LLVMGetBasicBlockTerminator(blk) == null) {
            this.at_block(blk);
            llvm::LLVMBuildUnreachable(this.b);
        }
        bb = llvm::LLVMGetNextBasicBlock(blk);
    }
    // what's built next (another fn, the constructor) isn't this fn's
    llvm::LLVMSetCurrentDebugLocation2(this.b, null);
    this.di_sp = null;
}

// ---------- debug info ----------

// the DWARF file for source file `file`
attach fn di_file_of(this: lg&, file: u32) -> llvm::LLVMOpaqueMetadata* {
    val have = this.di_files.get(file);
    if (have) {
        return *have;
    }
    var name = S("<generated>");
    if (@cast<usize>(file) < this.c.files.len) {
        name = S(this.c.files.at(@cast<usize>(file)).name);
    }
    val dir = std::process::cwd();
    val d = this.di ?? @panic("di");
    val m = llvm::LLVMDIBuilderCreateFile(d, this.z(name.as_str()), name.len(), this.z(dir.as_str()), dir.len()) ?? @panic("di file");
    this.di_files.put(file, m);
    return m;
}

// the debug info's compile unit, and the module flags debuggers look for
attach fn di_start(this: lg&) -> void {
    val d = llvm::LLVMCreateDIBuilder(this.m) ?? @panic("di builder");
    this.di = d;
    val file = this.di_file_of(0);
    llvm::LLVMDIBuilderCreateCompileUnit(d, llvm::LLVMDWARFSourceLanguageC, file, "voltc", 5, @cast<i32>(this.c.opts.release), "", 0, 0, "", 0, llvm::LLVMDWARFEmissionFull, 0, 0, 0, "", 0, "", 0);
    val i32t = this.i32t();
    llvm::LLVMAddModuleFlag(this.m, llvm::LLVMModuleFlagBehaviorWarning, "Debug Info Version", 18, llvm::LLVMValueAsMetadata(llvm::LLVMConstInt(i32t, @cast<u64>(llvm::LLVMDebugMetadataVersion()), 0)));
    llvm::LLVMAddModuleFlag(this.m, llvm::LLVMModuleFlagBehaviorWarning, "Dwarf Version", 13, llvm::LLVMValueAsMetadata(llvm::LLVMConstInt(i32t, 5, 0)));
}

// fn f's subprogram (its Volt name, the line it's declared on), and its first location
attach fn di_fn(this: lg&, f: ir_fn&) -> void {
    val d = this.di ?? return;
    var file: u32 = 0;
    var line: u32 = 0;
    if (f.origin) {
        val o = f.origin;
        file = o.file;
        line = @cast<u32>(this.c.line_col(o).line);
    }
    val df = this.di_file_of(file);
    val ty = llvm::LLVMDIBuilderCreateSubroutineType(d, df, null, 0, llvm::LLVMDIFlagZero);
    var name = f.about;
    if (name.len == 0) {
        name = f.name;
    }
    val sym = this.symbol(f);
    val local = @cast<i32>(f.link == linkage::STATIC);
    val sp = llvm::LLVMDIBuilderCreateFunction(d, df, this.z(name), name.len, this.z(sym), sym.len, df, line, ty, local, 1, line, llvm::LLVMDIFlagZero, @cast<i32>(this.c.opts.release));
    llvm::LLVMSetSubprogram(this.f, sp);
    this.di_sp = sp;
    this.di_file = file;
    llvm::LLVMSetCurrentDebugLocation2(this.b, llvm::LLVMDIBuilderCreateDebugLocation(this.ctx, line, 0, sp, null));
}

// the fn's named locals and parameters, for a debugger (temporaries, _name, aren't shown)
attach fn di_locals(this: lg&, f: ir_fn&, allocas: llvm::LLVMOpaqueBasicBlock*) -> void {
    val d = this.di ?? return;
    val sp = this.di_sp ?? return;
    val df = this.di_file_of(this.di_file);
    var line: u32 = 0;
    if (f.origin) {
        line = @cast<u32>(this.c.line_col(f.origin).line);
    }
    val loc = llvm::LLVMDIBuilderCreateDebugLocation(this.ctx, line, 0, sp, null);
    val expr = llvm::LLVMDIBuilderCreateExpression(d, null, 0);
    for (k) in 0..f.locals.len {
        val l = f.locals.at(k);
        if (l.name.len == 0 || l.name[0] == '_' || this.is_void(l.ty)) {
            continue;
        }
        val ty = this.di_type(l.ty);
        var arg: u32 = 0;
        for (p) in 0..f.params.len {
            if (@cast<usize>(*f.params.at(p)) == k) {
                arg = @cast<u32>(p) + 1;
            }
        }
        var v: llvm::LLVMOpaqueMetadata* = null;
        if (arg > 0) {
            v = llvm::LLVMDIBuilderCreateParameterVariable(d, sp, this.z(l.name), l.name.len, arg, df, line, ty, 1, llvm::LLVMDIFlagZero);
        } else {
            v = llvm::LLVMDIBuilderCreateAutoVariable(d, sp, this.z(l.name), l.name.len, df, line, ty, 1, llvm::LLVMDIFlagZero, 0);
        }
        llvm::LLVMDIBuilderInsertDeclareRecordAtEnd(d, *this.locals.at(k), v, expr, loc, allocas);
    }
}

// the debug type of Volt type t: what a debugger shows a variable of it as
attach fn di_type(this: lg&, t: u32) -> llvm::LLVMOpaqueMetadata* {
    val have = this.di_tys.get(t);
    if (have) {
        return *have;
    }
    val r = this.make_di_type(t);
    this.di_tys.put(t, r);
    return r;
}

attach fn make_di_type(this: lg&, t: u32) -> llvm::LLVMOpaqueMetadata* {
    val d = this.di ?? @panic("di");
    var name = this.c.ty_name(t);
    match (*this.c.t.get(t)) {
        .STRUCT(s) => {
            if (this.c.partial_struct(s)) {
                // a C struct only C can lay out (reached through pointers): its name, no layout
                return llvm::LLVMDIBuilderCreateForwardDecl(d, 19, this.z(name.as_str()), name.len(), this.di_file_of(0), this.di_file_of(0), 0, 0, 0, 0, "", 0);
            }
        },
        default => {},
    }
    val lty = this.lt(t);
    val bits = this.size_of(lty) * 8;
    match (*this.c.t.get(t)) {
        .BOOL => { return llvm::LLVMDIBuilderCreateBasicType(d, "bool", 4, 8, 2, llvm::LLVMDIFlagZero); },
        .INT(k) => {
            var enc: u32 = 7; // DW_ATE_unsigned
            if (k.signed()) {
                enc = 5; // DW_ATE_signed
            }
            return llvm::LLVMDIBuilderCreateBasicType(d, this.z(name.as_str()), name.len(), bits, enc, llvm::LLVMDIFlagZero);
        },
        .FLOAT(b) => { return llvm::LLVMDIBuilderCreateBasicType(d, this.z(name.as_str()), name.len(), bits, 4, llvm::LLVMDIFlagZero); },
        .ANYERR => { return llvm::LLVMDIBuilderCreateBasicType(d, "anyerror", 8, bits, 7, llvm::LLVMDIFlagZero); },
        .CSTR => {
            val ch = llvm::LLVMDIBuilderCreateBasicType(d, "char", 4, 8, 6, llvm::LLVMDIFlagZero);
            return llvm::LLVMDIBuilderCreatePointerType(d, ch, this.size_of(this.ptrt()) * 8, 0, 0, "cstr", 4);
        },
        .REF(x) => { return this.di_pointer(x, name.as_str()); },
        .PTR(x) => { return this.di_pointer(x, name.as_str()); },
        .VOIDPTR => { return llvm::LLVMDIBuilderCreatePointerType(d, null, this.size_of(this.ptrt()) * 8, 0, 0, "void*", 5); },
        .NULL => { return llvm::LLVMDIBuilderCreatePointerType(d, null, this.size_of(this.ptrt()) * 8, 0, 0, "null", 4); },
        .FN_PTR(ps, r, va) => { return llvm::LLVMDIBuilderCreatePointerType(d, null, this.size_of(this.ptrt()) * 8, 0, 0, this.z(name.as_str()), name.len()); },
        .ARRAY(x, n) => {
            var sub = llvm::LLVMDIBuilderGetOrCreateSubrange(d, 0, @cast<i64>(n));
            return llvm::LLVMDIBuilderCreateArrayType(d, bits, this.align_of(lty) * 8, this.di_type(x), &sub, 1);
        },
        .VECTOR(x, n) => {
            var sub = llvm::LLVMDIBuilderGetOrCreateSubrange(d, 0, @cast<i64>(n));
            return llvm::LLVMDIBuilderCreateVectorType(d, bits, this.align_of(lty) * 8, this.di_type(x), &sub, 1);
        },
        default => {},
    }
    // an aggregate: its members where the layout puts them; unions and tagged unions as a blob
    val df = this.di_file_of(0);
    var members: std::vec<llvm::LLVMOpaqueMetadata*> = {};
    val n = this.member_count(t);
    val plain = !this.is_union(t) && !this.c_union(t) && this.overlay(t).0 == 0 && llvm::LLVMGetTypeKind(lty) == llvm::LLVMStructTypeKind;
    if (plain) {
        this.di_busy.put(t, 1);
        for (i) in 0..n {
            val mt = this.member_ty(t, @cast<u32>(i));
            if (this.is_void(mt)) {
                continue;
            }
            var mn = this.di_member_name(t, @cast<u32>(i));
            val off = llvm::LLVMOffsetOfElement(this.td, lty, this.elem(t, @cast<u32>(i))) * 8;
            val mlt = this.lt(mt);
            put(&members, llvm::LLVMDIBuilderCreateMemberType(d, df, this.z(mn.as_str()), mn.len(), df, 0, this.size_of(mlt) * 8, this.align_of(mlt) * 8, off, llvm::LLVMDIFlagZero, this.di_type(mt)));
        }
        this.di_busy.remove(t);
    }
    var els: llvm::LLVMOpaqueMetadata** = null;
    if (members.len > 0) {
        els = members.ptr;
    }
    return llvm::LLVMDIBuilderCreateStructType(d, df, this.z(name.as_str()), name.len(), df, 0, bits, this.align_of(lty) * 8, llvm::LLVMDIFlagZero, null, els, @cast<u32>(members.len), 0, null, "", 0);
}

// a pointer to x; to an aggregate still being described, a pointer to its name
attach fn di_pointer(this: lg&, x: u32, name: str) -> llvm::LLVMOpaqueMetadata* {
    val d = this.di ?? @panic("di");
    var to: llvm::LLVMOpaqueMetadata* = null;
    if (this.di_busy.get(x) != null) {
        var xn = this.c.ty_name(x);
        to = llvm::LLVMDIBuilderCreateForwardDecl(d, 19, this.z(xn.as_str()), xn.len(), this.di_file_of(0), this.di_file_of(0), 0, 0, 0, 0, "", 0); // DW_TAG_structure_type
    } else if (!this.is_void(x)) {
        to = this.di_type(x);
    }
    return llvm::LLVMDIBuilderCreatePointerType(d, to, this.size_of(this.ptrt()) * 8, 0, 0, this.z(name), name.len);
}

// aggregate t's member i's name, as a debugger shows it
attach fn di_member_name(this: lg&, t: u32, i: u32) -> std::string {
    match (*this.c.t.get(t)) {
        .STRUCT(s) => {
            val fs = this.c.struct_fields(s, {}) catch |e| { return S("?"); };
            return S(fs.at(@cast<usize>(i)).name);
        },
        .CLOSURE(c) => { return S(this.c.ci(c).caps.at(@cast<usize>(i)).name); },
        .SLICE(x) => {
            if (i == 0) {
                return S("ptr");
            }
            return S("len");
        },
        .STR => {
            if (i == 0) {
                return S("ptr");
            }
            return S("len");
        },
        default => {},
    }
    var n = S("f");
    n.append_uint(@cast<u64>(i));
    return n;
}

// a statement on line `line` of source file `file` starts here
attach fn di_at(this: lg&, file: u32, line: u32) -> void {
    val d = this.di ?? return;
    val sp = this.di_sp ?? return;
    var scope = sp;
    if (file != this.di_file) {
        // code from another file inside this fn (a template's body): a scope in that file
        scope = llvm::LLVMDIBuilderCreateLexicalBlockFile(d, sp, this.di_file_of(file), 0) ?? sp;
    }
    llvm::LLVMSetCurrentDebugLocation2(this.b, llvm::LLVMDIBuilderCreateDebugLocation(this.ctx, line, 0, scope, null));
}

// globals whose initial value isn't a constant: set before main by a constructor
attach fn ctor(this: lg&) -> void {
    if (this.ctors.len == 0) {
        return;
    }
    var none: std::vec<llvm::LLVMOpaqueType*> = {};
    val fty = llvm::LLVMFunctionType(this.voidt(), none.ptr, 0, 0);
    this.f = llvm::LLVMAddFunction(this.m, "volt_init_globals", fty);
    llvm::LLVMSetLinkage(this.f, llvm::LLVMInternalLinkage);
    val allocas = this.block();
    val start = this.block();
    llvm::LLVMPositionBuilderAtEnd(this.eb, allocas);
    this.at_block(start);
    this.locals = {};
    this.labels = {};
    for (g) in this.ctors.items() {
        val gl = this.c.ir.globals.at(@cast<usize>(g));
        this.store(this.rv_as(gl.init ?? 0, gl.ty), this.decl_global(g));
    }
    llvm::LLVMBuildRetVoid(this.b);
    llvm::LLVMBuildBr(this.eb, start);
    // llvm.global_ctors = [{ i32 65535, ptr @volt_init_globals, ptr null }]
    var et: std::vec<llvm::LLVMOpaqueType*> = {};
    put(&et, this.i32t());
    put(&et, this.ptrt());
    put(&et, this.ptrt());
    val st = struct_ty(this.ctx, &et, false);
    var fields: std::vec<llvm::LLVMOpaqueValue*> = {};
    put(&fields, llvm::LLVMConstInt(this.i32t(), 65535, 0));
    put(&fields, this.f);
    put(&fields, llvm::LLVMConstNull(this.ptrt()));
    var entries: std::vec<llvm::LLVMOpaqueValue*> = {};
    put(&entries, llvm::LLVMConstNamedStruct(st, fields.ptr, 3));
    val arr = llvm::LLVMConstArray2(st, entries.ptr, 1);
    val g = llvm::LLVMAddGlobal(this.m, llvm::LLVMTypeOf(arr), "llvm.global_ctors");
    llvm::LLVMSetInitializer(g, arr);
    llvm::LLVMSetLinkage(g, llvm::LLVMAppendingLinkage);
}

// globals that must stay in the object even unused (package guards): llvm.used
attach fn keep_used(this: lg&) -> void {
    var kept: std::vec<llvm::LLVMOpaqueValue*> = {};
    for (i) in 0..this.c.ir.globals.len {
        val gl = this.c.ir.globals.at(i);
        if (gl.keep && !gl.header && gl.link != linkage::EXTERNAL) {
            put(&kept, this.decl_global(@cast<u32>(i)));
        }
    }
    if (kept.len == 0) {
        return;
    }
    val arr = llvm::LLVMConstArray2(this.ptrt(), kept.ptr, @cast<u64>(kept.len));
    val g = llvm::LLVMAddGlobal(this.m, llvm::LLVMTypeOf(arr), "llvm.used");
    llvm::LLVMSetInitializer(g, arr);
    llvm::LLVMSetLinkage(g, llvm::LLVMAppendingLinkage);
    llvm::LLVMSetSection(g, "llvm.metadata");
}

// ---------- the module ----------

// the program as an LLVM module, with a target machine for the host (for emit-llvm, $VOLT_TRIPLE's
// instead, to see how another host's code lowers) or --target; an error message, or ""
attach fn llvm_build(this: checker&, g: lg&) -> std::string {
    var level = llvm::LLVMCodeGenLevelNone;
    if (this.opts.release) {
        level = llvm::LLVMCodeGenLevelDefault;
    }
    var bare: target_info? = null;
    if (this.opts.target) {
        bare = find_target(this.opts.target);
    }
    var triple = S("");
    if (bare) {
        if (bare.arch == "wasm32") {
            llvm::LLVMInitializeWebAssemblyTargetInfo();
            llvm::LLVMInitializeWebAssemblyTarget();
            llvm::LLVMInitializeWebAssemblyTargetMC();
            llvm::LLVMInitializeWebAssemblyAsmPrinter();
            g.cc = callconv::WASM;
        } else if (bare.arch == "aarch64") {
            llvm::LLVMInitializeAArch64TargetInfo();
            llvm::LLVMInitializeAArch64Target();
            llvm::LLVMInitializeAArch64TargetMC();
            llvm::LLVMInitializeAArch64AsmPrinter();
            llvm::LLVMInitializeAArch64AsmParser();
            g.cc = callconv::AAPCS64;
        } else if (bare.arch == "arm") {
            llvm::LLVMInitializeARMTargetInfo();
            llvm::LLVMInitializeARMTarget();
            llvm::LLVMInitializeARMTargetMC();
            llvm::LLVMInitializeARMAsmPrinter();
            llvm::LLVMInitializeARMAsmParser();
        } else {
            llvm::LLVMInitializeRISCVTargetInfo();
            llvm::LLVMInitializeRISCVTarget();
            llvm::LLVMInitializeRISCVTargetMC();
            llvm::LLVMInitializeRISCVAsmPrinter();
            llvm::LLVMInitializeRISCVAsmParser();
        }
        triple.append(bare.triple);
    } else {
        if (this.opts.triple) {
            triple.append(this.opts.triple);
        } else {
            val host = llvm::LLVMGetDefaultTargetTriple();
            triple.append(c_text(host));
            llvm::LLVMDisposeMessage(host);
        }
        val ts = triple.as_str();
        if (ts.starts_with("x86_64")) {
            llvm::LLVMInitializeX86TargetInfo();
            llvm::LLVMInitializeX86Target();
            llvm::LLVMInitializeX86TargetMC();
            llvm::LLVMInitializeX86AsmPrinter();
            if (ts.contains("windows") || ts.contains("mingw") || ts.contains("cygwin") || ts.contains("win32")) {
                g.cc = callconv::WIN64;
            }
        } else if ((ts.starts_with("aarch64") || ts.starts_with("arm64")) && !ts.contains("windows")) {
            llvm::LLVMInitializeAArch64TargetInfo();
            llvm::LLVMInitializeAArch64Target();
            llvm::LLVMInitializeAArch64TargetMC();
            llvm::LLVMInitializeAArch64AsmPrinter();
            g.cc = callconv::AAPCS64;
            if (ts.contains("apple") || ts.contains("darwin")) {
                g.cc = callconv::DARWIN64;
            }
        } else {
            return fmt("the LLVM backend builds for x86-64 and aarch64 hosts but Windows on ARM (for now), not {}; use --backend c", copy triple);
        }
    }
    var target: llvm::LLVMTarget* = null;
    var err: cstr? = null;
    if (llvm::LLVMGetTargetFromTriple(triple.c_str(), &target, &err) != 0) {
        return fmt("LLVM has no target for {}", copy triple);
    }
    if (bare) {
        // bare metal: absolute addresses (no loader relocates it); RISC-V 64 code anywhere in memory
        var cpu = S(bare.cpu);
        var feats = S(bare.features);
        var model = llvm::LLVMCodeModelDefault;
        if (bare.arch == "riscv64") {
            model = llvm::LLVMCodeModelMedium;
        }
        g.tm = llvm::LLVMCreateTargetMachine(target, triple.c_str(), cpu.c_str(), feats.c_str(), level, llvm::LLVMRelocStatic, model);
    } else {
        // clang's default CPUs: the first x86-64, any armv8-a, Apple's M1
        var cpu = S("x86-64");
        if (g.cc == callconv::DARWIN64) {
            cpu = S("apple-m1");
        } else if (g.cc == callconv::AAPCS64) {
            cpu = S("generic");
        }
        g.tm = llvm::LLVMCreateTargetMachine(target, triple.c_str(), cpu.c_str(), "", level, llvm::LLVMRelocPIC, llvm::LLVMCodeModelDefault);
    }
    g.ctx = llvm::LLVMContextCreate();
    g.m = llvm::LLVMModuleCreateWithNameInContext("volt", g.ctx);
    llvm::LLVMSetTarget(g.m, triple.c_str());
    g.td = llvm::LLVMCreateTargetDataLayout(g.tm);
    llvm::LLVMSetModuleDataLayout(g.m, g.td);
    g.b = llvm::LLVMCreateBuilderInContext(g.ctx);
    g.eb = llvm::LLVMCreateBuilderInContext(g.ctx);
    g.read_aliases();
    if (this.opts.line_info) {
        // the IR marks each statement's line: DWARF line tables, so a debugger steps through Volt
        g.di_start();
    }
    // the bodies the program reaches, as the C backend writes (and so the C++ wrappers compiled)
    val live = reachable(this);
    for (b) in this.ir.bodies.items() {
        val f = this.ir.fn_at(b);
        if (f.body != null && f.used && f.link != linkage::EXTERNAL && live.get(b) != null) {
            g.fn_body(b);
        }
    }
    for (i) in 0..this.ir.globals.len {
        val gl = this.ir.globals.at(i);
        if (!gl.header && gl.link != linkage::EXTERNAL) {
            g.decl_global(@cast<u32>(i));
        }
    }
    g.ctor();
    g.keep_used();
    var wasm = false;
    var wasi = false;
    if (bare) {
        wasm = bare.arch == "wasm32";
        wasi = bare.name == "wasm32-wasi";
    }
    if (wasm) {
        // WebAssembly has no start code to assemble: its start and hooks are functions
        g.wasm_runtime(wasi);
    } else if (bare) {
        // the start code, and the hooks the program leaves to the defaults
        var taken: std::vec<str> = {};
        for (n) in START_WEAK {
            if (defines(g.m, n)) {
                put(&taken, n);
            }
        }
        var start = start_asm(bare, &taken);
        start.append(hook_defaults_asm(bare, !defines(g.m, "volt_exit"), !defines(g.m, "volt_console_write")).as_str());
        llvm::LLVMSetModuleInlineAsm2(g.m, start.c_str(), start.len());
    }
    if (g.err.len() > 0) {
        this.llvm_cant_lower = true;
        return copy g.err;
    }
    if (g.di) {
        llvm::LLVMDIBuilderFinalize(g.di);
    }
    var msg: cstr? = null;
    if (llvm::LLVMVerifyModule(g.m, llvm::LLVMReturnStatusAction, &msg) != 0) {
        var out = S("the LLVM backend made an invalid module (this is a voltc bug):\n");
        out.append(c_text(msg));
        return out;
    }
    if (this.opts.release) {
        val po = llvm::LLVMCreatePassBuilderOptions();
        llvm::LLVMRunPasses(g.m, "default<O2>", g.tm, po);
        llvm::LLVMDisposePassBuilderOptions(po);
    } else if (bare) {
        // a debug build has all of std's code in it; on bare metal what the program doesn't reach
        // must go, since much of it calls the OS
        val po = llvm::LLVMCreatePassBuilderOptions();
        llvm::LLVMRunPasses(g.m, "globaldce", g.tm, po);
        llvm::LLVMDisposePassBuilderOptions(po);
    }
    return S("");
}

// the function named `name` of type fty, declared if the module has none
attach fn fn_named(this: lg&, name: str, fty: llvm::LLVMOpaqueType*) -> llvm::LLVMOpaqueValue* {
    val have = llvm::LLVMGetNamedFunction(this.m, this.z(name));
    if (have) {
        return have;
    }
    return llvm::LLVMAddFunction(this.m, this.z(name), fty);
}

// a function the WebAssembly host gives: imported from module `from` under `name`
attach fn wasm_import(this: lg&, sym: str, from: str, name: str, fty: llvm::LLVMOpaqueType*) -> llvm::LLVMOpaqueValue* {
    val f = this.fn_named(sym, fty);
    llvm::LLVMAddAttributeAtIndex(f, 4294967295, llvm::LLVMCreateStringAttribute(this.ctx, "wasm-import-module", 18, this.z(from), @cast<u32>(from.len)));
    llvm::LLVMAddAttributeAtIndex(f, 4294967295, llvm::LLVMCreateStringAttribute(this.ctx, "wasm-import-name", 16, this.z(name), @cast<u32>(name.len)));
    return f;
}

// a body for function f (which has none yet), the builder in it
attach fn body_of(this: lg&, f: llvm::LLVMOpaqueValue*) -> void {
    llvm::LLVMSetLinkage(f, llvm::LLVMExternalLinkage);
    llvm::LLVMPositionBuilderAtEnd(this.b, llvm::LLVMAppendBasicBlockInContext(this.ctx, f, ""));
}

// WebAssembly's start and hooks, as functions where a board's are start code: _start runs the
// constructors and main, then exits with main's result; the heap starts at wasm-ld's __heap_base and
// ends where the memory does, growing it a 64 KiB page at a time when it needs more; the console and
// exit are the host's (a page's env.volt_console_write and env.volt_exit, or WASI's fd_write and
// proc_exit), unless the program defines volt_console_write or volt_exit itself
attach fn wasm_runtime(this: lg&, wasi: bool) -> void {
    val (i32, ptr, vt) = (this.i32t(), this.ptrt(), this.voidt());
    var pn: llvm::LLVMOpaqueType*[2] = { ptr, i32 };
    var one: llvm::LLVMOpaqueType*[1] = { i32 };
    val write_ty = llvm::LLVMFunctionType(vt, &pn[0], 2, 0);
    val exit_ty = llvm::LLVMFunctionType(vt, &one[0], 1, 0);
    var write = this.fn_named("volt_console_write", write_ty);
    var exit = this.fn_named("volt_exit", exit_ty);
    if (llvm::LLVMIsDeclaration(write) != 0) {
        if (wasi) {
            // fd_write(stdout, one iovec { p, n }, 1, &written)
            var fp: llvm::LLVMOpaqueType*[4] = { i32, ptr, i32, ptr };
            val fd_write = this.wasm_import("volt_wasi_fd_write", "wasi_snapshot_preview1", "fd_write", llvm::LLVMFunctionType(i32, &fp[0], 4, 0));
            this.body_of(write);
            var parts: llvm::LLVMOpaqueType*[2] = { ptr, i32 };
            val iov_ty = llvm::LLVMStructTypeInContext(this.ctx, &parts[0], 2, 0);
            val iov = llvm::LLVMBuildAlloca(this.b, iov_ty, "");
            val written = llvm::LLVMBuildAlloca(this.b, i32, "");
            llvm::LLVMBuildStore(this.b, llvm::LLVMGetParam(write, 0), llvm::LLVMBuildStructGEP2(this.b, iov_ty, iov, 0, ""));
            llvm::LLVMBuildStore(this.b, llvm::LLVMGetParam(write, 1), llvm::LLVMBuildStructGEP2(this.b, iov_ty, iov, 1, ""));
            var args: llvm::LLVMOpaqueValue*[4] = { llvm::LLVMConstInt(i32, 1, 0), iov, llvm::LLVMConstInt(i32, 1, 0), written };
            llvm::LLVMBuildCall2(this.b, llvm::LLVMGlobalGetValueType(fd_write), fd_write, &args[0], 4, "");
            llvm::LLVMBuildRetVoid(this.b);
        } else {
            write = this.wasm_import("volt_console_write", "env", "volt_console_write", write_ty);
        }
    }
    if (llvm::LLVMIsDeclaration(exit) != 0) {
        if (wasi) {
            val proc_exit = this.wasm_import("volt_wasi_proc_exit", "wasi_snapshot_preview1", "proc_exit", exit_ty);
            this.body_of(exit);
            var args: llvm::LLVMOpaqueValue*[1] = { llvm::LLVMGetParam(exit, 0) };
            llvm::LLVMBuildCall2(this.b, exit_ty, proc_exit, &args[0], 1, "");
            llvm::LLVMBuildUnreachable(this.b);
        } else {
            exit = this.wasm_import("volt_exit", "env", "volt_exit", exit_ty);
        }
    }
    // the hooks std/bare.volt calls
    val hook_write = this.fn_named("volt_hook_console_write", write_ty);
    if (llvm::LLVMIsDeclaration(hook_write) != 0) {
        this.body_of(hook_write);
        var args: llvm::LLVMOpaqueValue*[2] = { llvm::LLVMGetParam(hook_write, 0), llvm::LLVMGetParam(hook_write, 1) };
        llvm::LLVMBuildCall2(this.b, write_ty, write, &args[0], 2, "");
        llvm::LLVMBuildRetVoid(this.b);
    }
    val hook_exit = this.fn_named("volt_hook_exit", exit_ty);
    if (llvm::LLVMIsDeclaration(hook_exit) != 0) {
        this.body_of(hook_exit);
        var args: llvm::LLVMOpaqueValue*[1] = { llvm::LLVMGetParam(hook_exit, 0) };
        llvm::LLVMBuildCall2(this.b, exit_ty, exit, &args[0], 1, "");
        llvm::LLVMBuildUnreachable(this.b);
    }
    // the heap: from __heap_base to the memory's end, which grows
    var heap_base = llvm::LLVMGetNamedGlobal(this.m, "__heap_base");
    if (heap_base == null) {
        heap_base = llvm::LLVMAddGlobal(this.m, this.i8t(), "__heap_base");
    }
    val noargs = llvm::LLVMFunctionType(ptr, null, 0, 0);
    val start = this.fn_named("volt_heap_start", noargs);
    if (llvm::LLVMIsDeclaration(start) != 0) {
        this.body_of(start);
        llvm::LLVMBuildRet(this.b, heap_base ?? @panic("__heap_base"));
    }
    val size = this.fn_named("llvm.wasm.memory.size.i32", llvm::LLVMFunctionType(i32, &one[0], 1, 0));
    var two: llvm::LLVMOpaqueType*[2] = { i32, i32 };
    val grow = this.fn_named("llvm.wasm.memory.grow.i32", llvm::LLVMFunctionType(i32, &two[0], 2, 0));
    val end = this.fn_named("volt_heap_end", noargs);
    if (llvm::LLVMIsDeclaration(end) != 0) {
        this.body_of(end);
        var args: llvm::LLVMOpaqueValue*[1] = { llvm::LLVMConstInt(i32, 0, 0) };
        val pages = llvm::LLVMBuildCall2(this.b, llvm::LLVMGlobalGetValueType(size), size, &args[0], 1, "");
        val bytes = llvm::LLVMBuildShl(this.b, pages, llvm::LLVMConstInt(i32, 16, 0), "");
        llvm::LLVMBuildRet(this.b, llvm::LLVMBuildIntToPtr(this.b, bytes, ptr, ""));
    }
    val more = this.fn_named("volt_heap_grow", llvm::LLVMFunctionType(ptr, &one[0], 1, 0));
    if (llvm::LLVMIsDeclaration(more) != 0) {
        this.body_of(more);
        // the pages that hold `more` bytes past the end; the end after (unchanged when it can't grow)
        val n = llvm::LLVMBuildLShr(this.b, llvm::LLVMBuildAdd(this.b, llvm::LLVMGetParam(more, 0), llvm::LLVMConstInt(i32, 65535, 0), ""), llvm::LLVMConstInt(i32, 16, 0), "");
        var gargs: llvm::LLVMOpaqueValue*[2] = { llvm::LLVMConstInt(i32, 0, 0), n };
        llvm::LLVMBuildCall2(this.b, llvm::LLVMGlobalGetValueType(grow), grow, &gargs[0], 2, "");
        val r = llvm::LLVMBuildCall2(this.b, noargs, end, null, 0, "");
        llvm::LLVMBuildRet(this.b, r);
    }
    // the arguments a board's start code would keep: none
    val arg_names: str[2] = { "volt_argc", "volt_argv" };
    for (name) in arg_names {
        val gv = llvm::LLVMGetNamedGlobal(this.m, this.z(name));
        if (gv) {
            if (llvm::LLVMGetInitializer(gv) == null) {
                llvm::LLVMSetInitializer(gv, llvm::LLVMConstNull(llvm::LLVMGlobalGetValueType(gv)));
            }
        }
    }
    // _start: the constructors (wasm-ld makes __wasm_call_ctors), main, then its result as the exit
    val vfn = llvm::LLVMFunctionType(vt, null, 0, 0);
    val ctors = this.fn_named("__wasm_call_ctors", vfn);
    val main = this.fn_named("main", llvm::LLVMFunctionType(i32, null, 0, 0));
    val st = this.fn_named("_start", vfn);
    this.body_of(st);
    llvm::LLVMBuildCall2(this.b, vfn, ctors, null, 0, "");
    // (main takes argc and argv where a C runtime gives them: none here)
    val main_ty = llvm::LLVMGlobalGetValueType(main);
    var margs: std::vec<llvm::LLVMOpaqueValue*> = {};
    for (k) in 0..llvm::LLVMCountParams(main) {
        put(&margs, llvm::LLVMConstNull(llvm::LLVMTypeOf(llvm::LLVMGetParam(main, k))));
    }
    val code = llvm::LLVMBuildCall2(this.b, main_ty, main, margs.ptr, @cast<u32>(margs.len), "");
    var eargs: llvm::LLVMOpaqueValue*[1] = { code };
    llvm::LLVMBuildCall2(this.b, exit_ty, exit, &eargs[0], 1, "");
    llvm::LLVMBuildUnreachable(this.b);
}

// does module m define the function named `name` (not just declare it)?
fn defines(m: llvm::LLVMOpaqueModule*, name: str) -> bool {
    var n = S(name);
    val f = llvm::LLVMGetNamedFunction(m, n.c_str()) ?? return false;
    return llvm::LLVMIsDeclaration(f) == 0;
}

// a C string LLVM made, as a str
fn c_text(s: cstr?) -> str {
    val p = s ?? "";
    return @cast<str>(@slice(@cast<u8*>(p), strlen(p)));
}

// the program's LLVM IR as text (out), or an error message (the result)
attach fn llvm_ir(this: checker&, out: std::string&) -> std::string {
    var g: lg = { c: this };
    val e = this.llvm_build(&g);
    if (e.len() > 0) {
        return e;
    }
    val s = llvm::LLVMPrintModuleToString(g.m);
    out.append(c_text(s));
    llvm::LLVMDisposeMessage(s);
    return S("");
}

// the program as an object file at `path`; an error message, or "". `hdr` gets the C header
// functions it calls (llvm_runtime_c exports pointers to them)
attach fn llvm_object(this: checker&, path: str, hdr: std::vec<str>&) -> std::string {
    var g: lg = { c: this };
    val e = this.llvm_build(&g);
    if (e.len() > 0) {
        return e;
    }
    var err: cstr? = null;
    var p = S(path);
    if (llvm::LLVMTargetMachineEmitToFile(g.tm, g.m, p.c_str(), llvm::LLVMObjectFile, &err) != 0) {
        return fmt("LLVM couldn't write the object file: {}", S(c_text(err)));
    }
    *hdr = copy g.hdr;
    return S("");
}

// the program as a module for a JIT (vm.volt): built as for an object file (the C header functions'
// pointers it reads, g.hdr, are a C unit's: vm_native), and its globals' initializer an external
// function named `init` for the JIT's user to call (nothing runs llvm.global_ctors there)
attach fn llvm_jit_module(this: checker&, g: lg&, init: str) -> std::string {
    val e = this.llvm_build(g);
    if (e.len() > 0) {
        return e;
    }
    val ctors = llvm::LLVMGetNamedGlobal(g.m, "llvm.global_ctors");
    if (ctors) {
        llvm::LLVMDeleteGlobal(ctors);
    }
    val f = llvm::LLVMGetNamedFunction(g.m, "volt_init_globals");
    if (f) {
        var n = S(init);
        llvm::LLVMSetValueName2(f, n.c_str(), n.len());
        llvm::LLVMSetLinkage(f, llvm::LLVMExternalLinkage);
    }
    return S("");
}

// the runtime as a C unit for an LLVM-built program (or, with `runtime` off, a library): the
// prelude's helpers as weak definitions, so any mix of LLVM and C-backend units links
fn llvm_runtime_c(chk: checker&, hdr: std::vec<str>&, runtime: bool) -> std::string {
    var out = S("#define VOLT_RT_LINKAGE __attribute__((weak))\n");
    if (!chk.opts.release) {
        out.append("#define VOLT_DEBUG_ALLOC 1\n");
    }
    out.append(PRELUDE_H);
    if (runtime) {
        out.append(RUNTIME_H);
    }
    for (inc&) in chk.c_includes.items() {
        out.append(*inc);
        out.push('\n');
    }
    for (h) in hdr.items() {
        out.append("__attribute__((weak)) void *volt_c_");
        out.append(h);
        out.append(" = (void *)");
        out.append(h);
        out.append(";\n");
    }
    return out;
}

// the libm functions LLVM can make instructions once they're known not to touch memory (cgen's list)
fn is_builtin_math(sym: str) -> bool {
    for (m) in BUILTIN_MATH {
        if (m == sym) {
            return true;
        }
    }
    return false;
}
