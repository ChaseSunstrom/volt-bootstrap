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

// a clang program (clang, clang++) for libclang's headers and precompiled modules: NAME from PATH,
// except on macOS, where PATH's is Apple's clang and voltc's libclang is another LLVM's (Homebrew's):
// that LLVM's, beside the library's real file (LLVM/lib/libclang.dylib → LLVM/bin/NAME)
fn libclang_tool(name: str) -> std::string {
    comptime if (@cfg("os", "macos")) {
        var info: dl_info = {};
        if (dladdr(@cast<void*>(clang::clang_getClangVersion), &info) != 0 && info.fname != null) {
            val lib = real_file(c_text(info.fname)) ?? return S(name);
            var at = lib.len();
            while (at > 0 && lib.as_str()[at - 1] != '/') {
                at -= 1;
            }
            var tool = S(lib.as_str()[0..at]);
            tool.append("../bin/");
            tool.append(name);
            if (std::fs::exists(tool.as_str())) {
                return tool;
            }
        }
    }
    return S(name);
}

// where libclang's own headers (stddef.h, stdarg.h...) are: $VOLT_CLANG_RESOURCE_DIR, else what
// libclang's clang says with -print-resource-dir (libclang doesn't always find them from where it's
// installed)
fn clang_resource_dir() -> std::string? {
    val env = std::process::env("VOLT_CLANG_RESOURCE_DIR");
    if (env) {
        return S(env);
    }
    val clang = libclang_tool("clang");
    val argv: str[2] = { clang.as_str(), "-print-resource-dir" };
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
    return out;
}

// macOS: the SDK the system's C and C++ headers are in ($SDKROOT, else what `xcrun --show-sdk-path`
// says): a libclang that isn't Xcode's own (Homebrew's) doesn't find them by itself
fn clang_sysroot() -> std::string? {
    if (std::process::os() != "macos") {
        return null;
    }
    val env = std::process::env("SDKROOT");
    if (env) {
        return S(env);
    }
    val argv: str[2] = { "xcrun", "--show-sdk-path" };
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
    return out;
}

// Windows: libclang's own target is MSVC's, with MSVC's headers, but the program's C and C++ are
// compiled by MinGW's gcc or llvm-mingw's clang (libstdc++ or libc++, the GNU ABI), so libclang
// parses for that compiler's target, with its include directories; found once a process each
var c_view: std::vec<std::string> = {};
var cxx_view: std::vec<std::string> = {};

// what libclang adds to see what $CC (or, cxx, $CXX) sees: --target=its triple, its C++ library's
// directories ahead of libclang's own headers and its C library's after them (its own builtin
// headers are libclang's to give), the defaults off. Empty when the compiler doesn't answer
fn compiler_view(cxx: bool) -> std::vec<std::string> {
    var view: std::vec<std::string> = {};
    var argv: std::vec<str> = {};
    var lang = "c";
    if (cxx) {
        cxx_command(&argv);
        lang = "c++";
    } else {
        c_command(&argv);
    }
    var ask = copy argv;
    put(&ask, "-dumpmachine");
    val m = std::process::capture(ask.items(), "") catch |e| {
        return view;
    };
    if (m.code != 0) {
        return view;
    }
    put(&view, fmt("--target={}", S(m.out.as_str().trim())));
    put(&view, S("-nostdlibinc"));
    put(&view, S("-nostdinc++"));
    // `cc -E -v -x c -` on no input lists the directories between these lines, one a line
    var list = copy argv;
    put(&list, "-E");
    put(&list, "-v");
    put(&list, "-x");
    put(&list, lang);
    put(&list, "-");
    val r = std::process::capture(list.items(), "") catch |e| {
        return view;
    };
    var inside = false;
    val lines = r.err.as_str().lines();
    for (line) in lines.items() {
        val l = line.trim();
        if (starts_with(l, "#include <...> search starts here")) {
            inside = true;
        } else if (starts_with(l, "End of search list")) {
            inside = false;
        } else if (inside) {
            // MinGW's gcc names its C library's directories through its own
            // (.../lib/gcc/T/V/../../../../include): ".." taken out first, so only gcc's own are left out
            var dir = std::path::normalize(l);
            for (k) in 0..dir.len() {
                if (*dir.bytes.at(k) == '\\') {
                    *dir.bytes.at(k) = '/';
                }
            }
            val d = dir.as_str();
            if (contains(d, "/c++")) {
                put(&view, S("-isystem"));
                put(&view, copy dir);
            } else if (!contains(d, "/lib/gcc/") && !contains(d, "/lib/clang/")) {
                put(&view, S("-idirafter"));
                put(&view, copy dir);
            }
        }
    }
    return view;
}

// `text` parsed as the file `name`, with args (-x c++, -std=..., -I...); declarations only
fn clang_parse(name: str, text: str, args: std::vec<str>&) -> clang_tu {
    // CXTranslationUnit_SkipFunctionBodies: the declarations are all that's read
    return clang_parse_opts(name, text, args, 64);
}

// clang_parse with these CXTranslationUnit options
fn clang_parse_opts(name: str, text: str, args: std::vec<str>&, opts: u32) -> clang_tu {
    var owned: std::vec<std::string> = {};
    val res = clang_resource_dir();
    if (res) {
        put(&owned, S("-resource-dir"));
        put(&owned, copy res);
    }
    val sdk = clang_sysroot();
    if (sdk) {
        put(&owned, S("-isysroot"));
        put(&owned, copy sdk);
    }
    comptime if (@cfg("os", "windows")) {
        var cxx = false;
        for (a&) in args.items() {
            cxx = cxx || *a == "c++";
        }
        if (cxx) {
            if (cxx_view.len == 0) {
                cxx_view = compiler_view(true);
            }
            for (v&) in cxx_view.items() {
                put(&owned, copy *v);
            }
        } else {
            if (c_view.len == 0) {
                c_view = compiler_view(false);
            }
            for (v&) in c_view.items() {
                put(&owned, copy *v);
            }
        }
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
    val tu = clang::clang_parseTranslationUnit(index, n.c_str(), argv.ptr, @cast<i32>(argv.len), &file, 1, opts);
    return { index: index, tu: tu };
}

// the unit again with its main file now this text: one made with a precompiled preamble
// (CXTranslationUnit_PrecompiledPreamble) reuses it while the leading #include lines stay the same;
// false when clang couldn't
attach fn reparse(this: clang_tu&, name: str, text: str) -> bool {
    var n = S(name);
    var t = S(text);
    var file: clang::CXUnsavedFile = { Filename: n.c_str(), Contents: t.c_str(), Length: @cast<u64>(t.len()) };
    return clang::clang_reparseTranslationUnit(this.tu, 1, &file, clang::clang_defaultReparseOptions(this.tu)) == 0;
}

// every error clang reported, each with its notes, one a line: in clang's words, with the place
// when it's in a header (not in main, the generated file). A declaration in main whose type is an
// expression that failed (a probe's __decltype(call)) has an error of its own after the call's,
// saying it has no type: not the user's, so left out
attach fn errors_text(this: clang_tu&, main: str) -> std::string? {
    if (this.tu == null) {
        return S("libclang couldn't parse it");
    }
    var out: std::string = {};
    val n = clang::clang_getNumDiagnostics(this.tu);
    for (i) in 0..n {
        val d = clang::clang_getDiagnostic(this.tu, i);
        if (clang::clang_getDiagnosticSeverity(d) >= 3 && !(out.len() > 0 && no_type_after(d, main))) {
            put_diag_line(&out, d, main);
            val notes = clang::clang_getChildDiagnostics(d);
            for (j) in 0..clang::clang_getNumDiagnosticsInSet(notes) {
                val note = clang::clang_getDiagnosticInSet(notes, j);
                put_diag_line(&out, note, main);
                clang::clang_disposeDiagnostic(note);
            }
        }
        clang::clang_disposeDiagnostic(d);
    }
    if (out.len() == 0) {
        return null;
    }
    return out;
}

// the lines of the main file clang's errors are at, or were instantiated from (a note's)
attach fn error_lines(this: clang_tu&, main: str) -> std::vec<u32> {
    var out: std::vec<u32> = {};
    if (this.tu == null) {
        return out;
    }
    val n = clang::clang_getNumDiagnostics(this.tu);
    for (i) in 0..n {
        val d = clang::clang_getDiagnostic(this.tu, i);
        if (clang::clang_getDiagnosticSeverity(d) >= 3) {
            put_main_line(&out, d, main);
            val notes = clang::clang_getChildDiagnostics(d);
            for (j) in 0..clang::clang_getNumDiagnosticsInSet(notes) {
                val note = clang::clang_getDiagnosticInSet(notes, j);
                put_main_line(&out, note, main);
                clang::clang_disposeDiagnostic(note);
            }
        }
        clang::clang_disposeDiagnostic(d);
    }
    return out;
}

fn put_main_line(out: std::vec<u32>&, d: clang::CXDiagnostic, main: str) -> void {
    var f: clang::CXFile = null;
    var line: u32 = 0;
    clang::clang_getExpansionLocation(clang::clang_getDiagnosticLocation(d), &f, &line, null, null);
    if (f != null && ends_with(cx_str(clang::clang_getFileName(f)).as_str(), main)) {
        put(out, line);
    }
}

// one diagnostic as a line of out: "file:line:col: note: what", or "what" in the main file
// is d clang saying a declaration in main has no type (what follows an error in its type)?
fn no_type_after(d: clang::CXDiagnostic, main: str) -> bool {
    val what = cx_str(clang::clang_getDiagnosticSpelling(d));
    if (what.as_str() != "a type specifier is required for all declarations") {
        return false;
    }
    val place = cx_str(clang::clang_formatDiagnostic(d, clang::clang_defaultDiagnosticDisplayOptions()));
    return starts_with(place.as_str(), main);
}

fn put_diag_line(out: std::string&, d: clang::CXDiagnostic, main: str) -> void {
    var line = cx_str(clang::clang_formatDiagnostic(d, clang::clang_defaultDiagnosticDisplayOptions()));
    val text = line.as_str();
    if (starts_with(text, main)) {
        // past "main:line:col: " and "error: "
        var colons: u32 = 0;
        var at: usize = 0;
        while (at < text.len && colons < 3) {
            if (text[at] == ':') {
                colons += 1;
            }
            at += 1;
        }
        var rest = text[at..text.len];
        while (rest.len > 0 && rest[0] == ' ') {
            rest = rest[1..rest.len];
        }
        if (starts_with(rest, "error: ")) {
            rest = rest[7..rest.len];
        }
        line = S(rest);
    }
    if (out.len() > 0) {
        out.push('\n');
    }
    out.append(line.as_str());
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
            return msg;
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
    return out;
}

fn cursor_name(c: clang::CXCursor) -> std::string {
    return cx_str(clang::clang_getCursorSpelling(c));
}

// a declaration's unified symbol resolution: the same for it across parses and redeclarations
fn cursor_usr(c: clang::CXCursor) -> std::string {
    return cx_str(clang::clang_getCursorUSR(c));
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
    return out;
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

// where in its file a cursor starts (its expansion's byte offset)
fn cursor_offset(c: clang::CXCursor) -> u32 {
    var off: u32 = 0;
    clang::clang_getExpansionLocation(clang::clang_getCursorLocation(c), null, null, null, &off);
    return off;
}

// whether a parameter has a default argument: a = outside every ( ) [ ] { } and template < > of its
// own tokens (a template's own = is outside its extent). ponytail: raw tokens, so a default a macro
// supplies (f(int x DEF), #define DEF = 3) is invisible, and a comparison < directly in a template
// list (Foo<1 < 2> x = {}) counts as an opener and hides the default; a real parser would fix both.
// A < opens a template list only at the top
// or inside another; in parentheses it is a comparison (decltype(1 < 2)).
fn cursor_has_default(c: clang::CXCursor) -> bool {
    val tu = clang::clang_Cursor_getTranslationUnit(c);
    var toks: clang::CXToken* = null;
    var n: u32 = 0;
    clang::clang_tokenize(tu, clang::clang_getCursorExtent(c), &toks, &n);
    var open: std::string = {}; // the brackets still open, one char each
    var found = false;
    for (i) in 0..@cast<usize>(n) {
        if (found) {
            continue;
        }
        val t = cx_str(clang::clang_getTokenSpelling(tu, toks[i]));
        val s = t.as_str();
        var top: u8 = 0;
        if (open.len() > 0) {
            top = open.as_str()[open.len() - 1];
        }
        if (s == "(" || s == "[" || s == "{" || (s == "<" && (open.len() == 0 || top == '<'))) {
            open.push(s[0]);
        } else if (s == ")" || s == "]" || s == "}") {
            // a close drops any unclosed < above its opener, then the opener
            while (open.len() > 0 && open.as_str()[open.len() - 1] == '<') {
                open.pop();
            }
            if (open.len() > 0) {
                open.pop();
            }
        } else if ((s == ">" || s == ">>" || s == ">=" || s == ">>=") && top == '<') {
            open.pop();
            if (s.len > 1 && s[1] == '>' && open.len() > 0 && open.as_str()[open.len() - 1] == '<') {
                open.pop();
            }
            // the lexer joins a closing > with the = after it (vector<int>= {}): that = counts
            if (s[s.len - 1] == '=' && open.len() == 0) {
                found = true;
            }
        } else if (s == "=" && open.len() == 0) {
            found = true;
        }
    }
    if (toks != null) {
        clang::clang_disposeTokens(tu, toks, n);
    }
    return found;
}

// the direct children of c
fn children(c: clang::CXCursor) -> std::vec<clang::CXCursor> {
    var out: std::vec<clang::CXCursor> = {};
    clang::clang_visitChildren(c, volt_clang_collect, @cast<void*>(&out));
    return out;
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

// the size and alignment of record type rt's field `name` (0s when it has none)
fn field_layout(rt: clang::CXType, name: str) -> (i64, i64) {
    for (c&) in children(clang::clang_getTypeDeclaration(rt)).items() {
        val k = clang::clang_getCursorKind(*c);
        if (k == clang::CXCursor_FieldDecl && cursor_name(*c).as_str() == name) {
            val t = clang::clang_getCursorType(*c);
            return (clang::clang_Type_getSizeOf(t), clang::clang_Type_getAlignOf(t));
        }
        // an anonymous struct or union member: its fields are the outer one's
        if ((k == clang::CXCursor_StructDecl || k == clang::CXCursor_UnionDecl) && clang::clang_Cursor_isAnonymousRecordDecl(*c) != 0) {
            val got = field_layout(clang::clang_getCursorType(*c), name);
            if (got.0 > 0) {
                return got;
            }
        }
    }
    return (0, 0);
}

// padding fields for bytes [from, to): the widest naturally aligned unsigned ints that fit, none wider
// than the struct's alignment `most` (a run of u64s as one array), named @pad0, @pad1... A field
// can't be named that in Volt, and C never sees them: struct literals leave them out (zero), and C's
// own struct has its members there
attach fn pad_fields(this: checker&, from: u64, to: u64, most: u64, n: u32&, span: span, out: std::vec<field>&) -> void {
    val sizes: u64[3] = { 8, 4, 2 };
    var at = from;
    while (at < to) {
        var size: u64 = 1;
        for (s) in sizes {
            if (size == 1 && s <= most && at % s == 0 && at + s <= to) {
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
