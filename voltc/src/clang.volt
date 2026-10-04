// libclang, for what only a C or C++ compiler knows: where the fields of a C struct Volt can only
// partly read are (C import), and C++ declarations (use cpp, in cppimport.volt). Headers are parsed
// from text (their #include lines) with the preprocessor flags from --cc.
use { "clang-c/Index.h" } as clang;
use std::mem;

// a parsed translation unit; delete frees it
struct clang_tu {
    index: void*;
    tu: clang::CXTranslationUnitImpl*;
}

attach fn delete(this: clang_tu&) -> void {
    if (this.tu != null) {
        clang::clang_disposeTranslationUnit(this.tu);
    }
    clang::clang_disposeIndex(this.index);
}

// where libclang's own headers (stddef.h, stdarg.h...) are: $VOLT_CLANG_RESOURCE_DIR, else what
// `clang -print-resource-dir` says (libclang doesn't always find them from where it's installed)
fn clang_resource_dir() -> std::string? {
    val env = std::process::env("VOLT_CLANG_RESOURCE_DIR");
    if (env) {
        return S(env);
    }
    val argv: str[2] = { "clang", "-print-resource-dir" };
    val r = std::process::capture(argv[0..2], "") catch |e| {
        return null;
    };
    if (r.code != 0) {
        return null;
    }
    var out = copy r.out;
    while (out.len() > 0 && (*out.bytes.at(out.len() - 1) == '\n' || *out.bytes.at(out.len() - 1) == ' ')) {
        out.bytes.pop();
    }
    return move out;
}

// `text` parsed as the file `name`, with args (-x c++, -std=..., -I...); declarations only
fn clang_parse(name: str, text: str, args: std::vec<str>&) -> clang_tu {
    var owned: std::vec<std::string> = {};
    val res = clang_resource_dir();
    if (res) {
        put(&owned, S("-resource-dir"));
        put(&owned, copy res);
    }
    for (a&) in args.items() {
        put(&owned, S(*a));
    }
    var argv: std::vec<cstr?> = {};
    for (o&) in owned.items() {
        put(&argv, o.c_str());
    }
    var n = S(name);
    var t = S(text);
    var file: clang::CXUnsavedFile = { Filename: n.c_str(), Contents: t.c_str(), Length: @cast<u64>(t.len()) };
    val index = clang::clang_createIndex(0, 0);
    // CXTranslationUnit_SkipFunctionBodies: the declarations are all that's read
    val tu = clang::clang_parseTranslationUnit(index, n.c_str(), argv.ptr, @cast<i32>(argv.len), &file, 1, 64);
    return { index: index, tu: tu };
}

// the first error clang reported (with its place), if any
attach fn first_error(this: clang_tu&) -> std::string? {
    if (this.tu == null) {
        return S("libclang couldn't parse the headers");
    }
    val n = clang::clang_getNumDiagnostics(this.tu);
    for (i) in 0..n {
        val d = clang::clang_getDiagnostic(this.tu, i);
        val sev = clang::clang_getDiagnosticSeverity(d);
        if (sev >= 3) {
            val msg = cx_str(clang::clang_formatDiagnostic(d, clang::clang_defaultDiagnosticDisplayOptions()));
            clang::clang_disposeDiagnostic(d);
            return move msg;
        }
        clang::clang_disposeDiagnostic(d);
    }
    return null;
}

attach fn root(this: clang_tu&) -> clang::CXCursor {
    return clang::clang_getTranslationUnitCursor(this.tu);
}

// a CXString's text (and the CXString freed)
fn cx_str(s: clang::CXString) -> std::string {
    var out: std::string = {};
    val c = clang::clang_getCString(s);
    if (c) {
        out = S(@cast<str>(@slice(@cast<u8*>(c), strlen(c))));
    }
    clang::clang_disposeString(s);
    return move out;
}

fn cursor_name(c: clang::CXCursor) -> std::string {
    return cx_str(clang::clang_getCursorSpelling(c));
}

fn type_spelling(t: clang::CXType) -> std::string {
    return cx_str(clang::clang_getTypeSpelling(t));
}

// the visitor behind children: collects each child into the vec `data` points to
extern "C" fn volt_clang_collect(c: clang::CXCursor, parent: clang::CXCursor, data: void*) -> i32 {
    val out = @cast<std::vec<clang::CXCursor>*>(data);
    put(&*out, c);
    return 1; // CXChildVisit_Continue
}

// the visitor behind included_files: the name of each file the main file includes itself (its
// inclusion stack is one deep) into the vec `data` points to
extern "C" fn volt_clang_inclusion(f: clang::CXFile, stack: clang::CXSourceLocation*, n: u32, data: void*) -> void {
    if (n != 1) {
        return;
    }
    val out = @cast<std::vec<std::string>*>(data);
    put(&*out, cx_str(clang::clang_getFileName(f)));
}

// the files the translation unit's main file includes itself (its #include lines)
attach fn included_files(this: clang_tu&) -> std::vec<std::string> {
    var out: std::vec<std::string> = {};
    if (this.tu != null) {
        clang::clang_getInclusions(this.tu, volt_clang_inclusion, @cast<void*>(&out));
    }
    return move out;
}

// the file a cursor is in (empty for none)
fn cursor_file(c: clang::CXCursor) -> std::string {
    var f: clang::CXFile = null;
    clang::clang_getExpansionLocation(clang::clang_getCursorLocation(c), &f, null, null, null);
    if (f == null) {
        return {};
    }
    return cx_str(clang::clang_getFileName(f));
}

// the direct children of c
fn children(c: clang::CXCursor) -> std::vec<clang::CXCursor> {
    var out: std::vec<clang::CXCursor> = {};
    clang::clang_visitChildren(c, volt_clang_collect, @cast<void*>(&out));
    return move out;
}

// ---------- C struct layouts ----------

// the record type a C name means in tu: a typedef's (canonical) type, or `struct tag`'s definition
attach fn record_type(this: clang_tu&, c_name: str) -> clang::CXType? {
    val is_tag = starts_with(c_name, "struct ") || starts_with(c_name, "union ");
    var want = c_name;
    if (starts_with(c_name, "struct ")) {
        want = c_name[7..c_name.len];
    } else if (starts_with(c_name, "union ")) {
        want = c_name[6..c_name.len];
    }
    for (c&) in children(this.root()).items() {
        val k = clang::clang_getCursorKind(*c);
        val name = cursor_name(*c);
        if (name.as_str() != want) {
            continue;
        }
        if (!is_tag && k == clang::CXCursor_TypedefDecl) {
            return clang::clang_getCanonicalType(clang::clang_getTypedefDeclUnderlyingType(*c));
        }
        if (is_tag && (k == clang::CXCursor_StructDecl || k == clang::CXCursor_UnionDecl) && clang::clang_isCursorDefinition(*c) != 0) {
            return clang::clang_getCursorType(*c);
        }
    }
    return null;
}

// the size of record type rt's field `name` (0 when it has none)
fn field_size(rt: clang::CXType, name: str) -> i64 {
    for (c&) in children(clang::clang_getTypeDeclaration(rt)).items() {
        val k = clang::clang_getCursorKind(*c);
        if (k == clang::CXCursor_FieldDecl && cursor_name(*c).as_str() == name) {
            return clang::clang_Type_getSizeOf(clang::clang_getCursorType(*c));
        }
        // an anonymous struct or union member: its fields are the outer one's
        if ((k == clang::CXCursor_StructDecl || k == clang::CXCursor_UnionDecl) && clang::clang_Cursor_isAnonymousRecordDecl(*c) != 0) {
            val size = field_size(clang::clang_getCursorType(*c), name);
            if (size > 0) {
                return size;
            }
        }
    }
    return 0;
}

// padding fields for bytes [from, to): the widest naturally aligned unsigned ints that fit (a run of
// u64s as one array), named @pad0, @pad1... A field can't be named that in Volt, and C never sees
// them: struct literals leave them out (zero), and C's own struct has its members there
attach fn pad_fields(this: checker&, from: u64, to: u64, n: u32&, span: span, out: std::vec<field>&) -> void {
    val sizes: u64[3] = { 8, 4, 2 };
    var at = from;
    while (at < to) {
        var size: u64 = 1;
        for (s) in sizes {
            if (size == 1 && at % s == 0 && at + s <= to) {
                size = s;
            }
        }
        var count: u64 = 1;
        if (size == 8) {
            count = (to - at) / 8;
        }
        put(out, this.pad_field(n, size, count, span));
        at += size * count;
    }
}

// padding field @padN: count unsigned ints of `size` bytes
attach fn pad_field(this: checker&, n: u32&, size: u64, count: u64, span: span) -> field {
    var name = S("@pad");
    name.append_uint(@cast<u64>(*n));
    *n += 1;
    var elem = S("u");
    elem.append_uint(size * 8);
    var segs: std::vec<path_seg> = {};
    put(&segs, { name: this.intern(move elem), args: null });
    var t: ty = { kind: type_kind::PATH({ segs: move segs, span: span }), span: span };
    if (count > 1) {
        val len: expr = { kind: expr_kind::INT(@cast<u128>(count)), span: span };
        t = { kind: type_kind::ARRAY(bx(move t), bx(move len)), span: span };
    }
    return { name: this.intern(move name), ty: move t, fallback: null, vis: vis::PUBLIC, span: span };
}
