// The language server (`voltc lsp`, the self-hosted voltc) in a scripted session over stdio:
// initialize, diagnostics as the text changes, hover, go to definition, references, document
// symbols, completion (after `.`, after `::`, and plain) and signature help, then shutdown.
mod common;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// the program the session edits (0-based lines are what LSP counts)
const PROGRAM: &str = "use std::io;

struct point {
    x: i32;
    y: i32;
}

attach fn sum(this: point&) -> i32 {
    return this.x + this.y;
}

fn add(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> void {
    val p: point = { x: 1, y: 2 };
    val total = add(p.x, p.sum());
    std::println(\"{}\", total + missing);
}
";

struct Server {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next_id: u64,
    /// the messages the last request skipped on its way to its response
    skipped: Vec<String>,
    dir: PathBuf,
}

impl Server {
    fn start() -> Server {
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("lsp-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // bolt on PATH: the server asks it for a package's dependencies
        let bolt_dir = Path::new(env!("CARGO_BIN_EXE_bolt")).parent().unwrap().to_path_buf();
        let path = std::env::join_paths(std::iter::once(bolt_dir).chain(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()))).unwrap();
        // started the way VS Code's client starts it: with --stdio
        let mut child = Command::new(common::voltc())
            .args(["lsp", "--stdio"])
            .env("VOLT_STD", Path::new(ROOT).join("std"))
            .env("PATH", path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Server { child, input, output, next_id: 1, skipped: Vec::new(), dir }
    }

    fn send(&mut self, msg: &str) {
        write!(self.input, "Content-Length: {}\r\n\r\n{msg}", msg.len()).unwrap();
        self.input.flush().unwrap();
    }

    /// the next message the server sends
    fn recv(&mut self) -> String {
        let mut len = 0;
        loop {
            let mut line = String::new();
            assert!(self.output.read_line(&mut line).unwrap() > 0, "the server closed its output");
            let line = line.trim_end();
            if line.is_empty() {
                break;
            }
            if let Some(n) = line.strip_prefix("Content-Length: ") {
                len = n.parse().unwrap();
            }
        }
        let mut body = vec![0; len];
        self.output.read_exact(&mut body).unwrap();
        String::from_utf8(body).unwrap()
    }

    /// a request's response (notifications in between are skipped)
    fn request(&mut self, method: &str, params: &str) -> String {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\",\"params\":{params}}}"));
        self.skipped.clear();
        loop {
            let m = self.recv();
            // a response has a result or an error; a request or notification has a method (which a
            // result can also spell: the semantic token legend has "method")
            if m.contains(&format!("\"id\":{id}")) && (m.contains("\"result\"") || m.contains("\"error\"")) {
                return m;
            }
            self.skipped.push(m);
        }
    }

    fn notify(&mut self, method: &str, params: &str) {
        self.send(&format!("{{\"jsonrpc\":\"2.0\",\"method\":\"{method}\",\"params\":{params}}}"));
    }

    /// the next publishDiagnostics notification
    fn diagnostics(&mut self) -> String {
        loop {
            let m = self.recv();
            if m.contains("textDocument/publishDiagnostics") {
                return m;
            }
        }
    }

    /// the next publishDiagnostics for the document at uri (skipping others still on their way)
    fn diagnostics_for(&mut self, uri: &str) -> String {
        loop {
            let m = self.diagnostics();
            if m.contains(&format!("\"uri\":\"{uri}\"")) {
                return m;
            }
        }
    }
}

/// a JSON string literal
fn js(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

#[test]
fn scripted_session() {
    let mut s = Server::start();
    let uri = format!("file://{}/main.volt", s.dir.display());
    let doc = format!("{{\"uri\":\"{uri}\"}}");
    let at = |line: u32, ch: u32| format!("{{\"textDocument\":{doc},\"position\":{{\"line\":{line},\"character\":{ch}}}}}");

    let init = s.request("initialize", &format!("{{\"processId\":null,\"rootUri\":\"file://{}\",\"capabilities\":{{}}}}", s.dir.display()));
    for cap in ["\"hoverProvider\":true", "\"definitionProvider\":true", "\"referencesProvider\":true", "\"documentSymbolProvider\":true", "\"completionProvider\"", "\"signatureHelpProvider\"", "\"textDocumentSync\""] {
        assert!(init.contains(cap), "initialize lacks {cap}: {init}");
    }
    s.notify("initialized", "{}");

    // a URI ending in a cut-off %-escape is read as it is
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"file://{}/odd%1\",\"languageId\":\"volt\",\"version\":1,\"text\":\"fn main() -> void {{}}\\n\"}}}}", s.dir.display()));
    let d = s.diagnostics();
    assert!(d.contains("odd%1") && d.contains("\"diagnostics\":[]"), "{d}");

    // test blocks are checked like the rest (kept as plain fns, each its own)
    let turi = format!("file://{}/tests.volt", s.dir.display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{turi}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js("fn main() -> void {}\ntest \"one\" {\n    val x = nope;\n}\ntest \"two\" {\n}\n")));
    let d = s.diagnostics_for(&turi);
    assert!(d.contains("unknown name 'nope'") && !d.contains("defined"), "{d}");

    // an error where `missing` is (line 18, from character 31)
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(PROGRAM)));
    let d = s.diagnostics();
    assert!(d.contains("unknown name 'missing'") && d.contains("\"start\":{\"line\":18,\"character\":31}") && d.contains("\"severity\":1"), "{d}");

    // fixed: no diagnostics
    // (with operators attached after main, which completion after `p.` leaves out: they're used as
    // operators, not called by name)
    let fixed = PROGRAM.replace("total + missing", "total") + "\nattach operator +(this: point, o: point) -> point {\n    return o;\n}\n\nattach operator *(k: i32, this: point) -> point {\n    return this;\n}\n";
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"version\":2}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&fixed)));
    let d = s.diagnostics();
    assert!(d.contains("\"diagnostics\":[]"), "{d}");

    // hover: a local's type, a fn's signature
    let h = s.request("textDocument/hover", &at(18, 23));
    assert!(h.contains("total: i32"), "hover total: {h}");
    let h = s.request("textDocument/hover", &at(17, 20));
    assert!(h.contains("p: point"), "hover p: {h}");
    let h = s.request("textDocument/hover", &at(17, 16));
    assert!(h.contains("fn add(a: i32, b: i32) -> i32"), "hover add: {h}");

    // definition: a fn, a method, a field
    let def = s.request("textDocument/definition", &at(17, 16));
    assert!(def.contains(&uri) && def.contains("\"start\":{\"line\":11,\"character\":3}"), "definition add: {def}");
    let def = s.request("textDocument/definition", &at(17, 29));
    assert!(def.contains("\"start\":{\"line\":7,"), "definition sum: {def}");
    let def = s.request("textDocument/definition", &at(17, 22));
    assert!(def.contains("\"start\":{\"line\":3,\"character\":4}"), "definition x: {def}");

    // a type name, and a field named in a struct literal
    let h = s.request("textDocument/hover", &at(16, 12));
    assert!(h.contains("struct point"), "hover point: {h}");
    let def = s.request("textDocument/definition", &at(16, 12));
    assert!(def.contains("\"start\":{\"line\":2,\"character\":7}"), "definition point: {def}");
    let h = s.request("textDocument/hover", &at(16, 21));
    assert!(h.contains("x: i32"), "hover literal x: {h}");
    let def = s.request("textDocument/definition", &at(16, 21));
    assert!(def.contains("\"start\":{\"line\":3,\"character\":4}"), "definition literal x: {def}");

    // references to add: its declaration and the call
    let refs = s.request("textDocument/references", &format!("{{\"textDocument\":{doc},\"position\":{{\"line\":11,\"character\":4}},\"context\":{{\"includeDeclaration\":true}}}}"));
    assert!(refs.contains("\"line\":11") && refs.contains("\"line\":17"), "references: {refs}");

    // the file's symbols
    let sym = s.request("textDocument/documentSymbol", &doc_param(&doc));
    for name in ["\"point\"", "\"sum\"", "\"add\"", "\"main\""] {
        assert!(sym.contains(name), "symbols lack {name}: {sym}");
    }

    // completion while typing (the text doesn't parse): members after `p.`, a namespace's names
    // after `std::`, and names in scope
    let typing = fixed.replace("    std::println(\"{}\", total);\n", "    p.\n    std::pr\n    to\n");
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"version\":3}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&typing)));
    let c = s.request("textDocument/completion", &at(18, 6));
    for item in ["\"label\":\"x\"", "\"label\":\"y\"", "\"label\":\"sum\""] {
        assert!(c.contains(item), "completion after p. lacks {item}: {c}");
    }
    assert!(!c.contains("operator"), "completion after p. lists operator fns: {c}");
    let c = s.request("textDocument/completion", &at(19, 11));
    assert!(c.contains("\"label\":\"println\""), "completion after std:: lacks println: {c}");
    let c = s.request("textDocument/completion", &at(20, 6));
    for item in ["\"label\":\"total\"", "\"label\":\"add\"", "\"label\":\"return\""] {
        assert!(c.contains(item), "plain completion lacks {item}: {c}");
    }

    // signature help inside add(...), at its second argument
    let sig_text = fixed.replace("    std::println(\"{}\", total);\n", "    add(1, \n");
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"version\":4}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&sig_text)));
    let h = s.request("textDocument/signatureHelp", &at(18, 11));
    assert!(h.contains("fn add(a: i32, b: i32) -> i32") && h.contains("\"activeParameter\":1"), "signature help: {h}");

    // a bolt package's dependencies come from `bolt metadata`: app uses geo (a path dependency),
    // and a file of geo's library is checked as part of package geo
    let geo = s.dir.join("geo");
    let app = s.dir.join("app");
    std::fs::create_dir_all(geo.join("lib")).unwrap();
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(geo.join("bolt.toml"), "[package]\nname = \"geo\"\nversion = \"0.1.0\"\n").unwrap();
    let shapes = "// areas\npublic fn area(w: i32, h: i32) -> i32 {\n    return w * h;\n}\n";
    std::fs::write(geo.join("lib/shapes.volt"), shapes).unwrap();
    // an unreadable file in a library is left out; it doesn't take the server down
    let locked = geo.join("lib/locked.volt");
    std::fs::write(&locked, "fn locked() -> void {}\n").unwrap();
    std::fs::set_permissions(&locked, std::os::unix::fs::PermissionsExt::from_mode(0o000)).unwrap();
    std::fs::write(app.join("bolt.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\ngeo = { path = \"../geo\" }\n").unwrap();
    let main = "use std::io;\n\nfn main() -> void {\n    std::println(\"{}\", geo::area(2, 3));\n}\n";
    std::fs::write(app.join("src/main.volt"), main).unwrap();
    let app_uri = format!("file://{}", app.join("src/main.volt").display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{app_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(main)));
    let d = s.diagnostics_for(&app_uri);
    assert!(d.contains("\"diagnostics\":[]"), "app using geo: {d}");
    let h = s.request("textDocument/hover", &format!("{{\"textDocument\":{{\"uri\":\"{app_uri}\"}},\"position\":{{\"line\":3,\"character\":29}}}}"));
    assert!(h.contains("fn area(w: i32, h: i32) -> i32"), "hover geo::area: {h}");
    let geo_uri = format!("file://{}", geo.join("lib/shapes.volt").display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{geo_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(shapes)));
    let d = s.diagnostics_for(&geo_uri);
    assert!(d.contains("\"diagnostics\":[]"), "geo's own file: {d}");

    inline_features(&mut s);

    let r = s.request("shutdown", "null");
    assert!(r.contains("\"result\":null"), "{r}");
    s.notify("exit", "null");
    let st = s.child.wait().unwrap();
    assert!(st.success(), "the server exited with {st}");
    let _ = std::fs::remove_dir_all(&s.dir);
}

/// what the server shows inline (lsp_inline.volt), on a program of its own
const INLINE: &str = "use std::io;

trait shape {
    fn area(this) -> f64;
}

struct circle {
    r: f64;
}

enum color {
    RED,
    GREEN: i32,
}

attach shape -> circle {
    fn area(this) -> f64 {
        return 3.0 * this.r * this.r;
    }
}

attach fn grow(this: circle&, by: f64) -> void {
    this.r += by;
}

<T: shape>
fn report(s: T&, scale: f64) -> f64 {
    return s.area() * scale;
}

fn main() -> void {
    var c: circle = { r: 1.0 };
    val k = color::GREEN(2);
    val doubled = report(&c, 2.0);
    c.grow(1.0);
    std::println(\"{} {}\", doubled, @sizeof(circle));
}

fn first(x: u16?, c: circle) -> f64 {
    val wide: circle = { ..c, r: 2.0 };
    std::println(\"r {wide.r}\");
    if (val n = x) {
        return wide.r + @cast<f64>(n);
    }
    return c.r;
}

attach operator +(this: circle, other: circle) -> circle {
    return { r: this.r + other.r };
}

fn joined(c: circle, wide: circle) -> f64 {
    return (c + wide).r;
}
";

fn inline_features(s: &mut Server) {
    let uri = format!("file://{}/inline.volt", s.dir.display());
    let doc = format!("{{\"uri\":\"{uri}\"}}");
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(INLINE)));
    let d = s.diagnostics_for(&uri);
    assert!(d.contains("\"diagnostics\":[]"), "inline.volt: {d}");

    // semantic tokens: what each name is (the legend's order: lsp_inline.volt)
    let types = ["namespace", "type", "struct", "enum", "interface", "typeParameter", "parameter", "variable", "property", "enumMember", "function", "method", "macro"];
    let mods = ["declaration", "readonly", "defaultLibrary"];
    let r = s.request("textDocument/semanticTokens/full", &doc_param(&doc));
    let lines: Vec<&str> = INLINE.lines().collect();
    let (mut line, mut col, mut got) = (0usize, 0usize, Vec::new());
    for t in numbers(&r, "\"data\":[").chunks(5) {
        line += t[0];
        col = if t[0] == 0 { col + t[1] } else { t[1] };
        let ms: Vec<&str> = (0..mods.len()).filter(|b| t[4] >> b & 1 == 1).map(|b| mods[b]).collect();
        got.push(format!("{} {} {}", &lines[line][col..col + t[2]], types[t[3]], ms.join(" ")).trim_end().to_string());
    }
    for want in ["std namespace", "io namespace", "shape interface declaration", "shape interface", "circle struct declaration", "r property declaration", "GREEN enumMember declaration", "GREEN enumMember", "T typeParameter declaration", "T typeParameter", "report function declaration", "grow method declaration", "grow method", "s parameter declaration readonly", "c variable declaration", "k variable declaration readonly", "println function defaultLibrary", "@sizeof macro", "area method"] {
        assert!(got.iter().any(|g| g == want), "semantic tokens lack `{want}`: {got:?}");
    }

    // inlay hints: the types of locals that don't write one, the parameters arguments are for
    // (not for one-letter parameters, nor where the argument names it already)
    let range = "\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":60,\"character\":0}}";
    let h = s.request("textDocument/inlayHint", &format!("{{\"textDocument\":{doc},{range}}}"));
    for want in ["\"label\":\": color\"", "\"label\":\": f64\"", "\"label\":\"scale:\"", "\"label\":\"by:\""] {
        assert!(h.contains(want), "inlay hints lack {want}: {h}");
    }
    // an if's binding gets one; the hidden locals an if binding or a struct update is parsed into don't
    assert!(h.contains("\"label\":\": u16\""), "inlay hints lack the if binding's type: {h}");
    // nor an operator's operand
    for unwanted in ["\"label\":\": circle\"", "\"label\":\"s:\"", "\"label\":\": u16?\"", "\"label\":\"other:\""] {
        assert!(!h.contains(unwanted), "inlay hints have {unwanted}: {h}");
    }

    let at = |line: u32, ch: u32| format!("{{\"textDocument\":{doc},\"position\":{{\"line\":{line},\"character\":{ch}}}}}");
    // a local named in a format string is used where its name is written, inside the string
    let h = s.request("textDocument/documentHighlight", &at(39, 8));
    assert!(h.contains("\"start\":{\"line\":40,\"character\":21}"), "highlight of wide lacks its {{wide.r}}: {h}");
    // highlights: the field r where it's declared and everywhere it's used
    let h = s.request("textDocument/documentHighlight", &at(7, 5));
    for line in [7, 17, 22, 31] {
        assert!(h.contains(&format!("\"start\":{{\"line\":{line},")), "highlight of r lacks line {line}: {h}");
    }

    // rename: grow where it's declared and called; not a std fn, not to a keyword
    let r = s.request("textDocument/prepareRename", &at(21, 11));
    assert!(r.contains("\"placeholder\":\"grow\""), "prepareRename grow: {r}");
    let r = s.request("textDocument/rename", &format!("{{\"textDocument\":{doc},\"position\":{{\"line\":21,\"character\":11}},\"newName\":\"enlarge\"}}"));
    assert!(r.contains("\"newText\":\"enlarge\"") && r.contains("\"line\":21,") && r.contains("\"line\":34,"), "rename grow: {r}");
    let r = s.request("textDocument/prepareRename", &at(35, 10));
    let why = "'println' is declared in std, which a program's rename doesn't edit";
    assert!(r.contains("\"error\"") && r.contains(why), "prepareRename println: {r}");
    let r = s.request("textDocument/rename", &format!("{{\"textDocument\":{doc},\"position\":{{\"line\":35,\"character\":10}},\"newName\":\"shout\"}}"));
    assert!(r.contains("\"error\"") && r.contains(why), "rename println: {r}");
    let r = s.request("textDocument/rename", &format!("{{\"textDocument\":{doc},\"position\":{{\"line\":21,\"character\":11}},\"newName\":\"fn\"}}"));
    assert!(r.contains("\"error\"") && r.contains("isn't a name"), "rename to a keyword: {r}");

    // hover on a type: its fields, then what's attached to it, grouped by trait; a trait's attachers
    let h = s.request("textDocument/hover", &at(31, 12));
    assert!(h.contains("// size 8, align 8\\nstruct circle {\\n    r: f64; // offset 0, size 8\\n}\\n// shape\\nfn area(this) -> f64\\n// attached\\nattach operator +(this: circle, other: circle) -> circle\\nattach fn grow(this: circle&, by: f64) -> void"), "hover circle: {h}");
    let h = s.request("textDocument/hover", &at(2, 8));
    assert!(h.contains("// attached by\\ncircle"), "hover shape: {h}");

    // what comptime code became: hover on a generic call adds the instance it runs, and volt/expand
    // lists a line's
    let h = s.request("textDocument/hover", &at(33, 20));
    assert!(h.contains("expands to\\n```volt\\ncalls report<circle>(s: circle&, scale: f64) -> f64"), "hover report: {h}");
    let e = s.request("volt/expand", &format!("{{\"textDocument\":{doc},\"line\":33}}"));
    assert!(e.contains("\"text\":\"calls report<circle>(s: circle&, scale: f64) -> f64\"") && e.contains("\"start\":{\"line\":33,\"character\":18}"), "volt/expand: {e}");
    let e = s.request("volt/expand", &format!("{{\"textDocument\":{doc},\"line\":32}}"));
    assert!(e.contains("\"result\":[]"), "volt/expand of a line without comptime code: {e}");
    // the same from the command line: voltc expand FILE, and FILE:LINE for one line's
    let expand = |arg: &str| {
        let out = Command::new(common::voltc()).args(["expand", arg]).current_dir(ROOT).env("VOLT_STD", Path::new(ROOT).join("std")).output().unwrap();
        assert!(out.status.success(), "voltc expand {arg}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    let all = expand("tests/run/expand.volt");
    for want in [":6:22: attach eq -> point {}", ":13:5: attach fn get_x(this: point&) -> i32", ":30:13: 32 (usize)", ":34:13: = \"hi\" (str)", ":37:9: comptime match: 16, this arm", ":40:25: comptime for: 3 copies, i = 0, 1, 2", ":45:18: comptime if: true, this branch"] {
        assert!(all.contains(want), "voltc expand lacks {want}: {all}");
    }
    let one = expand("tests/run/expand.volt:32");
    assert!(one.contains(":32:21: calls twice<i64>(v: i64) -> i64") && !one.contains(":31:"), "voltc expand FILE:32: {one}");
    // a type built at compile time: its members, where it's built
    let built = expand("tests/run/comptime_types.volt:15");
    assert!(built.contains(":15:12: struct { x: std::vec<f32, std::mem::default_allocator>; y: "), "voltc expand of a built type: {built}");

    // code lenses: references above fns, attached fns and traits above types, attachers above a
    // trait, Run above main
    let l = s.request("textDocument/codeLens", &doc_param(&doc));
    for want in ["attached fns", "shape", "1 type attaches it", "1 reference", "volt.showLocations", "\"command\":\"volt.run\""] {
        assert!(l.contains(want), "code lenses lack {want}: {l}");
    }

    // quick fixes: diagnostics carry their fixes as data, and codeAction turns them into edits
    let fix_uri = format!("file://{}/fixes.volt", s.dir.display());
    let fix_src = "fn bump(r: i32&) -> void {\n    *r += 1;\n}\n\nfn main() -> void {\n    val x = 0;\n    bump(&x);\n    var y = 0;\n    y + 1;\n}\n";
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{fix_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(fix_src)));
    let d = s.diagnostics_for(&fix_uri);
    assert!(d.contains("\"fixes\":[") && d.contains("declare 'x' with var"), "fixes in diagnostics: {d}");
    let key = "\"diagnostics\":";
    let diags = &d[d.find(key).unwrap() + key.len()..d.len() - 2];
    let a = s.request("textDocument/codeAction", &format!("{{\"textDocument\":{{\"uri\":\"{fix_uri}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"context\":{{\"diagnostics\":{diags}}}}}"));
    assert!(a.contains("\"kind\":\"quickfix\"") && a.contains("\"newText\":\"var\"") && a.contains("\"start\":{\"line\":5,\"character\":4}"), "codeAction val -> var: {a}");

    // a closure parameter's type, the end of a long block; and nothing from an older check: when the
    // text no longer parses, tokens and hints say ContentModified and rename refuses
    let long_uri = format!("file://{}/long.volt", s.dir.display());
    let mut long_src = String::from("fn apply(f: fn(i32) -> i32, x: i32) -> i32 {\n    return f(x);\n}\n\nfn main() -> void {\n    val r0 = apply(|| (n) -> i32 { return n * 2; }, 3);\n");
    for i in 0..25 {
        long_src.push_str(&format!("    val v{i} = r0 + {i};\n"));
    }
    long_src.push_str("}\n");
    let long_doc = format!("{{\"uri\":\"{long_uri}\"}}");
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{long_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(&long_src)));
    let d = s.diagnostics_for(&long_uri);
    assert!(d.contains("\"diagnostics\":[]"), "long.volt: {d}");
    let h = s.request("textDocument/inlayHint", &format!("{{\"textDocument\":{long_doc},{range}}}"));
    assert!(h.contains("\"position\":{\"line\":5,\"character\":24},\"label\":\": i32\"") && h.contains("\"label\":\"fn main\""), "closure parameter and closing brace hints: {h}");
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{long_uri}\",\"version\":2}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&format!("\n\n{long_src}fn broken( {{\n"))));
    let t = s.request("textDocument/semanticTokens/full", &doc_param(&long_doc));
    assert!(t.contains("-32801"), "tokens for changed text: {t}");
    let r = s.request("textDocument/rename", &format!("{{\"textDocument\":{long_doc},\"position\":{{\"line\":2,\"character\":4}},\"newName\":\"run\"}}"));
    assert!(r.contains("\"error\"") && r.contains("fix them, then rename"), "rename on changed text: {r}");

    // folding: blocks (the closing brace stays in view)
    let f = s.request("textDocument/foldingRange", &doc_param(&doc));
    assert!(f.contains("\"startLine\":30,\"endLine\":35") && f.contains("\"startLine\":2,\"endLine\":3"), "folding: {f}");
}

/// the numbers in the JSON array that starts after `key`
fn numbers(json: &str, key: &str) -> Vec<usize> {
    let start = json.find(key).unwrap_or_else(|| panic!("no {key} in {json}")) + key.len();
    let end = start + json[start..].find(']').unwrap();
    json[start..end].split(',').filter(|x| !x.is_empty()).map(|x| x.trim().parse().unwrap()).collect()
}

fn doc_param(doc: &str) -> String {
    format!("{{\"textDocument\":{doc}}}")
}

#[test]
fn builtins_and_std_files() {
    // a std file opened in the editor is checked as std's own (its @intrinsic attributes are fine);
    // every builtin and attribute shows up after `@` with its signature, and on hover
    let mut s = Server::start();
    let init = s.request("initialize", &format!("{{\"processId\":null,\"rootUri\":\"file://{}\",\"capabilities\":{{}}}}", s.dir.display()));
    assert!(init.contains("\"@\""), "@ isn't a completion trigger: {init}");
    s.notify("initialized", "{}");
    let mem = Path::new(ROOT).join("std/mem.volt");
    let muri = format!("file://{}", mem.display());
    let text = std::fs::read_to_string(&mem).unwrap();
    assert!(text.contains("@intrinsic("), "std/mem.volt no longer has an @intrinsic to check");
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{muri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(&text)));
    let d = s.diagnostics_for(&muri);
    assert!(d.contains("\"diagnostics\":[]"), "std/mem.volt in the editor: {d}");

    // renaming from std's own file: a helper of std/path.volt, at its declaration and each use there
    // (and only those: a std doc's check doesn't load programs)
    let path = Path::new(ROOT).join("std/path.volt");
    let puri = format!("file://{}", path.display());
    let ptext = std::fs::read_to_string(&path).unwrap();
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{puri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(&ptext)));
    let _ = s.diagnostics_for(&puri);
    let decl = ptext.lines().position(|l| l.contains("fn last_sep(")).unwrap();
    let pos = format!("{{\"textDocument\":{{\"uri\":\"{puri}\"}},\"position\":{{\"line\":{decl},\"character\":12}}");
    let r = s.request("textDocument/prepareRename", &format!("{pos}}}"));
    assert!(r.contains("\"placeholder\":\"last_sep\""), "prepareRename last_sep in std: {r}");
    let r = s.request("textDocument/rename", &format!("{pos},\"newName\":\"last_slash\"}}"));
    let want: Vec<usize> = ptext.lines().enumerate().flat_map(|(i, l)| l.matches("last_sep").map(move |_| i)).collect();
    assert_eq!(r.matches("\"newText\":\"last_slash\"").count(), want.len(), "rename last_sep in std: {r}");
    for i in want {
        assert!(r.contains(&format!("\"line\":{i},")), "rename last_sep lacks line {i}: {r}");
    }
    assert_eq!(r.matches("file://").count(), 1, "rename last_sep edits another file: {r}");

    let uri = format!("file://{}/b.volt", s.dir.display());
    let doc = format!("{{\"uri\":\"{uri}\"}}");
    let at = |line: u32, ch: u32| format!("{{\"textDocument\":{doc},\"position\":{{\"line\":{line},\"character\":{ch}}}}}");
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js("fn main() -> void {\n    val n = @sizeof(i32);\n}\n")));
    let _ = s.diagnostics_for(&uri);
    let h = s.request("textDocument/hover", &at(1, 15));
    assert!(h.contains("@sizeof(T) -> usize") && h.contains("size in bytes"), "hover @sizeof: {h}");
    // while typing: the text after `@` doesn't parse yet
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"version\":2}},\"contentChanges\":[{{\"text\":{}}}]}}", js("fn main() -> void {\n    val n = @\n}\n")));
    let _ = s.diagnostics_for(&uri);
    let c = s.request("textDocument/completion", &at(1, 13));
    for item in ["\"label\":\"sizeof\"", "\"label\":\"typeinfo\"", "\"label\":\"cpp\"", "\"label\":\"inline\"", "\"label\":\"derive\"", "@sizeof(T) -> usize", "@derive("] {
        assert!(c.contains(item), "completion after @ lacks {item}: {c}");
    }
    // std's own: not offered in a program
    assert!(!c.contains("\"label\":\"intrinsic\""), "a program is offered @intrinsic: {c}");
}

/// hover tells what clangd tells for C++: a type's generics, size, alignment, each field's offset and
/// size and the padding between, a value's size, the doc comment; an imported C++ function's
/// declaration, and for a call worked out per use, the call clang chose
#[test]
fn hovers_show_layout_and_foreign_declarations() {
    let mut s = Server::start();
    s.request("initialize", &format!("{{\"processId\":null,\"rootUri\":\"file://{}\",\"capabilities\":{{}}}}", s.dir.display()));
    s.notify("initialized", "{}");
    std::fs::write(s.dir.join("geo.hpp"), "#pragma once\nnamespace geo {\ninline double scale(double x, int k) { return x * k; }\ntemplate <class... A>\nauto sum(A... a) { return (a + ... + 0); }\n}\n").unwrap();
    let src = "use std::io;
use { \"geo.hpp\" } as cpp;

// a point with a tag in front
struct tagged {
    tag: u8;
    x: f64;
    y: i32;
}

<T: type>
struct pair {
    a: T;
    b: T;
}

enum shade {
    DARK,
    LIGHT: i64,
}

fn main() -> void {
    val t: tagged = { tag: 1, x: 2.0, y: 3 };
    val p: pair<i16> = { a: 1, b: 2 };
    val k = shade::LIGHT(4);
    std::println(\"{} {} {}\", t.tag, p.a, cpp::geo::scale(1.5, 2) + cpp::geo::sum(1, 2.5));
}
// not abs's doc
use { \"stdlib.h\" } as libc;
fn other() -> i32 {
    return libc::abs(-3);
}
";
    let uri = format!("file://{}/hover.volt", s.dir.display());
    let doc = format!("{{\"uri\":\"{uri}\"}}");
    let at = |line: u32, ch: u32| format!("{{\"textDocument\":{doc},\"position\":{{\"line\":{line},\"character\":{ch}}}}}");
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(src)));
    let _ = s.diagnostics_for(&uri);
    let h = s.request("textDocument/hover", &at(22, 12));
    assert!(h.contains("// size 24, align 8\\nstruct tagged {\\n    tag: u8; // offset 0, size 1\\n    // 7 bytes padding\\n    x: f64; // offset 8, size 8\\n    y: i32; // offset 16, size 4\\n    // 4 bytes padding\\n}"), "hover tagged: {h}");
    assert!(h.contains("a point with a tag in front"), "hover tagged's doc: {h}");
    let h = s.request("textDocument/hover", &at(23, 12));
    assert!(h.contains("struct pair<T: type> {\\n    a: T;\\n    b: T;\\n}"), "hover pair: {h}");
    let h = s.request("textDocument/hover", &at(25, 37));
    assert!(h.contains("// size 4, align 2\\np: pair<i16>"), "hover p: {h}");
    let h = s.request("textDocument/hover", &at(24, 13));
    assert!(h.contains("enum shade {"), "hover shade: {h}");
    let h = s.request("textDocument/hover", &at(25, 52));
    assert!(h.contains("C++: double geo::scale(double x, int k)"), "hover scale: {h}");
    let h = s.request("textDocument/hover", &at(25, 78));
    assert!(h.contains("fn sum(a0: i32, a1: f64) -> f64") && h.contains("C++: geo::sum(int32_t, double) -> double, as clang resolves it"), "hover sum: {h}");
    let h = s.request("textDocument/hover", &at(30, 18));
    assert!(h.contains("abs") && !h.contains("not abs's doc"), "a C fn's hover has no doc of the use's: {h}");
    let _ = std::fs::remove_dir_all(&s.dir);
}

/// the program of generic_bodies_nothing_instantiates: a line's `[name]` marks a use of the global
/// `name` the index should have (in the generic bodies nothing instantiates too); the body's own
/// names (params, locals so far, generic params) named like globals aren't uses of them
const GENERICS: &str = "use std::io;

val LIMIT: i32 = 10;
var count: i32 = 0;

fn helper(x: i32) -> i32 {
    return x + 1;
}

struct cell {
    v: i32;
}

enum color {
    RED,
    BLUE,
}

namespace util {
    fn twice(x: i32) -> i32 {
        return x * 2;
    }
}

<T: type>
fn uses(a: T, b: cell) -> i32 { // [cell]
    val c: cell = b; // [cell]
    val k = color::RED; // [color] [RED]
    count += LIMIT; // [count] [LIMIT]
    return helper(util::twice(c.v)); // [helper] [twice]
}

<T: type>
fn shadows(helper: T, cell: i32) -> i32 {
    val before = LIMIT; // [LIMIT]
    val LIMIT = 3;
    val x = LIMIT + cell;
    {
        val count = 1;
        val y = count;
    }
    val z = count + x; // [count]
    return helper;
}

<count: type>
fn generic_named(x: count) -> i32 {
    return helper(1); // [helper]
}

<T: type>
fn binders(xs: i32[], r: i32!i32, o: i32?) -> i32 {
    for (helper) in xs {
        val a = helper;
    }
    match (o) {
        .VALUE(count) => { return count; },
        default => {},
    }
    val e = r catch |LIMIT| LIMIT;
    val g = || (cell: i32) -> i32 { return cell; };
    val off = @offsetof(cell, color); // [cell]
    val (helper, count) = (1, 2);
    return helper + count;
}

<T: type>
fn typed(cell: cell, other: cell) -> i32 { // [cell] [cell]
    return cell.v + other.v;
}

struct circle {
    r: f64;
}

enum shape {
    circle: circle,
    other,
}

<T: type>
fn area(s: shape) -> f64 {
    match (s) {
        circle(c) => { return c.r; },
        default => { return 0.0; },
    }
}

<T: type>
fn instanced(x: T) -> i32 {
    return helper(2); // [helper]
}

fn main() -> void {
    val c: cell = { v: 1 }; // [cell]
    val round: circle = { r: 1.0 };
    val n = instanced(c.v) + helper(0) + LIMIT + count; // [helper] [LIMIT] [count]
    val k = color::BLUE; // [color]
    std::println(\"{} {}\", n, util::twice(n)); // [twice]
}
";

/// the lines a response's locations start on, sorted
fn start_lines(r: &str) -> Vec<usize> {
    let key = "\"start\":{\"line\":";
    let mut out: Vec<usize> = r.match_indices(key).map(|(i, _)| r[i + key.len()..].split(|c: char| !c.is_ascii_digit()).next().unwrap().parse().unwrap()).collect();
    out.sort();
    out
}

#[test]
fn generic_bodies_nothing_instantiates() {
    // a generic fn's body is checked per instance: the uses in one nothing instantiates are indexed
    // from its syntax, so references, rename and go to definition reach them
    let mut s = Server::start();
    s.request("initialize", &format!("{{\"processId\":null,\"rootUri\":\"file://{}\",\"capabilities\":{{}}}}", s.dir.display()));
    s.notify("initialized", "{}");
    let uri = format!("file://{}/generics.volt", s.dir.display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(GENERICS)));
    let d = s.diagnostics_for(&uri);
    assert!(!d.contains("\"severity\":1"), "{d}");
    let lines: Vec<&str> = GENERICS.lines().collect();
    let pos = |pat: &str, name: &str| {
        let l = lines.iter().position(|l| l.contains(pat)).unwrap_or_else(|| panic!("no {pat}"));
        format!("{{\"textDocument\":{{\"uri\":\"{uri}\"}},\"position\":{{\"line\":{l},\"character\":{}}}", lines[l].find(name).unwrap())
    };
    for (pat, name) in [("val LIMIT: i32", "LIMIT"), ("var count", "count"), ("fn helper(", "helper"), ("struct cell", "cell"), ("enum color", "color"), ("    RED,", "RED"), ("fn twice(", "twice")] {
        let marker = format!("[{name}]");
        let want: Vec<usize> = lines.iter().enumerate().flat_map(|(i, l)| std::iter::repeat_n(i, l.matches(marker.as_str()).count())).collect();
        let r = s.request("textDocument/references", &format!("{},\"context\":{{\"includeDeclaration\":false}}}}", pos(pat, name)));
        assert_eq!(start_lines(&r), want, "references of {name}: {r}");
    }
    // go to definition from a use in a body nothing instantiates
    let r = s.request("textDocument/definition", &format!("{}}}", pos("return helper(util", "helper")));
    let helper_line = lines.iter().position(|l| l.contains("fn helper(")).unwrap();
    assert!(r.contains(&format!("\"start\":{{\"line\":{helper_line},\"character\":3}}")), "definition of helper: {r}");
    // rename: the declaration and each use, once (the instantiated body's too)
    let r = s.request("textDocument/rename", &format!("{},\"newName\":\"assist\"}}", pos("fn helper(", "helper")));
    let mut want: Vec<usize> = lines.iter().enumerate().filter(|(_, l)| l.contains("[helper]")).map(|(i, _)| i).collect();
    want.push(helper_line);
    want.sort();
    assert_eq!(start_lines(&r), want, "rename helper: {r}");
    assert!(!s.skipped.iter().any(|m| m.contains("window/showMessage")), "rename helper warns: {:?}", s.skipped);
    // a field named as a member in such a body (c.v, cell.v) where the receiver's type is written:
    // rename edits those uses too, and doesn't warn (generic_body_members has the rest)
    let r = s.request("textDocument/rename", &format!("{},\"newName\":\"w\"}}", pos("    v: i32;", "v")));
    let edits = start_lines(&r);
    for pat in ["return helper(util::twice(c.v))", "return cell.v + other.v;"] {
        let l = lines.iter().position(|l| l.contains(pat)).unwrap();
        assert!(edits.contains(&l), "rename v misses {pat}: {r}");
    }
    assert!(!s.skipped.iter().any(|m| m.contains("window/showMessage")), "rename v warns: {:?}", s.skipped);
    // a one-name variant pattern (circle(c)) is the scrutinee enum's variant, not the struct circle
    let r = s.request("textDocument/rename", &format!("{},\"newName\":\"ring\"}}", pos("struct circle", "circle")));
    let edits = start_lines(&r);
    let decl = lines.iter().position(|l| l.contains("struct circle")).unwrap();
    let arm = lines.iter().position(|l| l.contains("circle(c) =>")).unwrap();
    assert!(edits.contains(&decl) && !edits.contains(&arm), "rename circle: {r}");

    // from std's own file: a helper used only in generic bodies std doesn't instantiate itself
    let map = Path::new(ROOT).join("std/map.volt");
    let muri = format!("file://{}", map.display());
    let text = std::fs::read_to_string(&map).unwrap();
    let started = std::time::Instant::now();
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{muri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(&text)));
    let _ = s.diagnostics_for(&muri);
    eprintln!("checking std/map.volt: {:?}", started.elapsed());
    let mlines: Vec<&str> = text.lines().collect();
    let decl = mlines.iter().position(|l| l.contains("fn map_tag(")).expect("std/map.volt no longer has map_tag");
    let want: Vec<usize> = mlines.iter().enumerate().filter(|(_, l)| l.contains("std::map_tag(")).map(|(i, _)| i).collect();
    assert!(!want.is_empty(), "std/map.volt no longer calls map_tag");
    let at = format!("{{\"textDocument\":{{\"uri\":\"{muri}\"}},\"position\":{{\"line\":{decl},\"character\":5}}");
    let started = std::time::Instant::now();
    let r = s.request("textDocument/references", &format!("{at},\"context\":{{\"includeDeclaration\":false}}}}"));
    eprintln!("references of std::map_tag from std/map.volt: {:?}", started.elapsed());
    assert_eq!(start_lines(&r), want, "references of map_tag in std: {r}");
    let r = s.request("textDocument/definition", &format!("{{\"textDocument\":{{\"uri\":\"{muri}\"}},\"position\":{{\"line\":{},\"character\":{}}}}}", want[0], mlines[want[0]].find("map_tag").unwrap()));
    assert!(r.contains(&format!("\"start\":{{\"line\":{decl},")), "definition of map_tag from its use: {r}");
    let _ = std::fs::remove_dir_all(&s.dir);
}

/// the program of generic_body_members: in generic bodies nothing instantiates, a line's `[name]`
/// marks a member use the index should have, its receiver's type known from what's written (a
/// param's or annotated local's type, `this` in an attach block, a struct literal's annotation, an
/// enum compared or matched, a T with one bound naming the fn); the uses in `unsure` aren't certain
/// (an inferred local, a T with two bounds both naming area), so they're left out
const MEMBERS: &str = "use std::io;

struct point {
    x: i32;
    y: i32;
}

attach fn norm(this: point&) -> i32 {
    return this.x * 2; // [x]
}

attach fn origin(static this: point) -> point {
    return { x: 0, y: 0 }; // [x] [y]
}

<T: type>
struct pair {
    a: T;
    b: i32;
}

<T: type>
attach fn first(this: pair<T>&) -> T {
    return this.a; // [a]
}

enum shade {
    LIGHT,
    DARK,
}

trait shape {
    fn area(this) -> i32;
}

trait solid {
    fn area(this) -> i32; // solid's
}

<T: type>
attach shape -> pair<T> {
    fn area(this) -> i32 {
        return this.b; // [b]
    }
}

fn pick(x: i32) -> i32 {
    return x;
}

fn pick(x: str) -> i32 {
    return 0;
}

<T: shape>
fn members(p: point, q: pair<T>, s: shade, t: T) -> i32 {
    val r: point = { x: 1, y: 2 }; // [x] [y]
    val o = point::origin(); // [origin]
    var n = p.x + q.b + r.norm(); // [x] [b] [norm]
    val f = q.a; // [a]
    if (s == .LIGHT) { // [LIGHT]
        n += pick(3); // [pick]
    }
    match (s) {
        .DARK => { n += 1; }, // [DARK]
        default => {},
    }
    return n + t.area(); // [area]
}

<T: shape + solid>
fn unsure(t: T, u: point) -> i32 {
    val v = u;
    return t.area() + v.y;
}

fn main() -> void {
    val p: point = { x: 3, y: 4 }; // [x] [y]
    std::println(\"{}\", p.norm()); // [norm]
}
";

#[test]
fn generic_body_members() {
    let mut s = Server::start();
    s.request("initialize", &format!("{{\"processId\":null,\"rootUri\":\"file://{}\",\"capabilities\":{{}}}}", s.dir.display()));
    s.notify("initialized", "{}");
    let uri = format!("file://{}/members.volt", s.dir.display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(MEMBERS)));
    let d = s.diagnostics_for(&uri);
    assert!(!d.contains("\"severity\":1"), "{d}");
    let lines: Vec<&str> = MEMBERS.lines().collect();
    let pos = |pat: &str, name: &str| {
        let l = lines.iter().position(|l| l.contains(pat)).unwrap_or_else(|| panic!("no {pat}"));
        format!("{{\"textDocument\":{{\"uri\":\"{uri}\"}},\"position\":{{\"line\":{l},\"character\":{}}}", lines[l].find(name).unwrap())
    };
    for (pat, name) in [("    x: i32;", "x"), ("    y: i32;", "y"), ("    a: T;", "a"), ("    b: i32;", "b"), ("fn norm(", "norm"), ("fn origin(", "origin"), ("    LIGHT,", "LIGHT"), ("    DARK,", "DARK"), ("fn pick(x: i32)", "pick"), ("    fn area(this) -> i32;", "area")] {
        let marker = format!("[{name}]");
        let want: Vec<usize> = lines.iter().enumerate().flat_map(|(i, l)| std::iter::repeat_n(i, l.matches(marker.as_str()).count())).collect();
        let r = s.request("textDocument/references", &format!("{},\"context\":{{\"includeDeclaration\":false}}}}", pos(pat, name)));
        assert_eq!(start_lines(&r), want, "references of {name}: {r}");
    }
    // definition from a member use in a body nothing instantiates
    let r = s.request("textDocument/definition", &format!("{}}}", pos("var n = p.x + q.b", "b;")));
    let b_line = lines.iter().position(|l| l.contains("    b: i32;")).unwrap();
    assert!(r.contains(&format!("\"start\":{{\"line\":{b_line},")), "definition of q.b: {r}");
    // every use of x is certain: rename edits them all and doesn't warn
    let r = s.request("textDocument/rename", &format!("{},\"newName\":\"left\"}}", pos("    x: i32;", "x")));
    let mut want: Vec<usize> = lines.iter().enumerate().filter(|(_, l)| l.contains("[x]")).map(|(i, _)| i).collect();
    want.push(lines.iter().position(|l| l.contains("    x: i32;")).unwrap());
    want.sort();
    let mut got = start_lines(&r);
    got.dedup();
    assert_eq!(got, want, "rename x: {r}");
    assert!(!s.skipped.iter().any(|m| m.contains("window/showMessage")), "rename x warns: {:?}", s.skipped);
    // v.y in unsure isn't certain, nor is t.area() there: renaming y or shape's area still warns
    for (pat, name) in [("    y: i32;", "y"), ("return n + t.area()", "area")] {
        let _ = s.request("textDocument/rename", &format!("{},\"newName\":\"other\"}}", pos(pat, name)));
        assert!(s.skipped.iter().any(|m| m.contains("window/showMessage") && m.contains(&format!("'{name}' is also used as a member"))), "rename {name} doesn't warn: {:?}", s.skipped);
    }
    let _ = std::fs::remove_dir_all(&s.dir);
}
